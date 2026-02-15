#!/usr/bin/env bash
# =============================================================================
# setup-cicd.sh — GitHub + ArgoCD + Argo Rollouts CI/CD Integration
# =============================================================================
# Run AFTER deploy-cluster.sh and setup-keycloak.sh complete.
#
# This script:
#   1. Connects ArgoCD to GitHub via SSH key + credential template
#   2. Creates private GitHub repos for each service (svc-{realm}-{name})
#   3. Pushes substituted manifests (secrets/domain tokens replaced)
#   4. Generates declarative ArgoCD Application manifests (app-of-apps)
#   5. Creates Harbor robot accounts for CI
#   6. Creates Argo Rollouts AnalysisTemplates with Prometheus queries
#   7. Generates sample GitHub Actions workflows and Rollout CRDs
#
# Prerequisites:
#   - All services running (deploy-cluster.sh completed)
#   - gh CLI installed and authenticated (gh auth login)
#   - Git repo pushed to GitHub
#   - KUBECONFIG set to RKE2 cluster
#
# Usage:
#   export KUBECONFIG=/path/to/kubeconfig-rke2.yaml
#   ./scripts/setup-cicd.sh
#   ./scripts/setup-cicd.sh --from 3         # Resume from phase 3
#   ./scripts/setup-cicd.sh --dry-run        # Print actions without executing
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# Load domain configuration from .env (if available)
generate_or_load_env

# -----------------------------------------------------------------------------
# CLI Arguments
# -----------------------------------------------------------------------------
FROM_PHASE=0
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)    FROM_PHASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--from PHASE_NUMBER] [--dry-run]"
      echo ""
      echo "Phases:"
      echo "  1  GitHub <-> ArgoCD connection (SSH key, credential template)"
      echo "  2  App-of-apps bootstrap (create service repos, generate manifests)"
      echo "  3  Harbor CI robot accounts"
      echo "  4  Argo Rollouts AnalysisTemplates"
      echo "  5  Sample CI/CD templates"
      echo "  6  Validation summary"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# -----------------------------------------------------------------------------
# Configuration (derived from git remote + .env)
# -----------------------------------------------------------------------------
GIT_OWNER=$(git -C "${REPO_ROOT}" remote get-url origin \
  | sed -n 's|.*[:/]\([^/]*\)/[^/]*\.git$|\1|p')
[[ -n "$GIT_OWNER" ]] || die "Could not derive GIT_OWNER from git remote origin"

REPO_PREFIX="svc-${KC_REALM}"
INFRA_REPO_URL=$(git -C "${REPO_ROOT}" remote get-url origin)
# shellcheck disable=SC2034  # used by sourced scripts
HARBOR_URL="https://harbor.${DOMAIN}"

# Deploy key paths
DEPLOY_KEY_DIR="${SCRIPTS_DIR}/.deploy-keys"
DEPLOY_KEY_PRIVATE="${DEPLOY_KEY_DIR}/argocd-deploy-key"
DEPLOY_KEY_PUBLIC="${DEPLOY_KEY_DIR}/argocd-deploy-key.pub"

# Bootstrap apps directory (generated Application manifests live here)
BOOTSTRAP_APPS_DIR="${SERVICES_DIR}/argo/bootstrap/apps"

# Git author for service repo commits
GIT_AUTHOR_NAME="rke2-cluster-bootstrap"
GIT_AUTHOR_EMAIL="noreply@${DOMAIN}"

# -----------------------------------------------------------------------------
# Service Inventory
# Format: "name|source_dir|namespace|sync_policy"
#   sync_policy: auto | manual
#   namespace: empty string for cluster-scoped resources (rbac)
# -----------------------------------------------------------------------------
SERVICES=(
  "argocd|services/argo/argocd|argocd|auto"
  "argo-rollouts|services/argo/argo-rollouts|argo-rollouts|auto"
  "cert-manager|services/cert-manager|cert-manager|auto"
  "monitoring-stack|services/monitoring-stack|monitoring|auto"
  "vault|services/vault|vault|manual"
  "harbor|services/harbor|harbor|manual"
  "keycloak|services/keycloak|keycloak|auto"
  "mattermost|services/mattermost|mattermost|auto"
  "kasm|services/kasm|kasm|auto"
  "oauth2-proxy|services/oauth2-proxy|oauth2-proxy|auto"
  "rbac|services/rbac||auto"
  "node-labeler|services/node-labeler|node-labeler|auto"
  "storage-autoscaler|services/storage-autoscaler|storage-autoscaler|auto"
)

# Optional services (conditional on .env flags)
[[ "${DEPLOY_UPTIME_KUMA}" == "true" ]] && SERVICES+=("uptime-kuma|services/uptime-kuma|uptime-kuma|auto")
[[ "${DEPLOY_LIBRENMS}" == "true" ]] && SERVICES+=("librenms|services/librenms|librenms|auto")

# -----------------------------------------------------------------------------
# Helper: Ensure gh CLI is installed and authenticated
# -----------------------------------------------------------------------------
ensure_gh_cli() {
  if ! command -v gh &>/dev/null; then
    log_info "Installing gh CLI..."
    sudo dnf install -y 'dnf-command(config-manager)' 2>/dev/null || true
    sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
    sudo dnf install -y gh
    log_ok "gh CLI installed"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Skipping gh auth check"
    return 0
  fi

  if ! gh auth status &>/dev/null; then
    die "gh CLI not authenticated. Run: gh auth login"
  fi
  log_ok "gh CLI authenticated as $(gh api user -q .login 2>/dev/null || echo 'unknown')"
}

# -----------------------------------------------------------------------------
# Helper: Create a private GitHub repo for a service and push substituted
# manifests. Echoes the repo SSH URL on stdout (all log output goes to stderr).
# Usage: repo_url=$(create_service_repo <service_name> <source_dir_relative>)
# -----------------------------------------------------------------------------
create_service_repo() {
  local service_name="$1"
  local source_dir="${REPO_ROOT}/$2"
  local repo_name="${REPO_PREFIX}-${service_name}"
  local repo_url="git@github.com:${GIT_OWNER}/${repo_name}.git"

  # All log output goes to stderr so stdout is clean for the URL
  {
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[DRY RUN] Would create repo: ${GIT_OWNER}/${repo_name}"
      log_info "[DRY RUN] Would push substituted manifests from: $2"
    else
      # 1. Create private GitHub repo (skip if exists)
      if ! gh repo view "${GIT_OWNER}/${repo_name}" &>/dev/null 2>&1; then
        gh repo create "${GIT_OWNER}/${repo_name}" --private \
          --description "K8s manifests for ${service_name} (managed by rke2-cluster bootstrap)"
        log_ok "Created repo: ${GIT_OWNER}/${repo_name}"
        sleep 2  # Allow GitHub to initialize the repo
      else
        log_info "Repo already exists: ${GIT_OWNER}/${repo_name}"
      fi

      # 2. Clone or init temp working copy
      local tmp_dir
      tmp_dir=$(mktemp -d "/tmp/svc-${service_name}-XXXXXX")

      if ! git clone "${repo_url}" "${tmp_dir}/repo" 2>/dev/null; then
        # Empty repo — init fresh
        mkdir -p "${tmp_dir}/repo"
        git -C "${tmp_dir}/repo" init -b main
        git -C "${tmp_dir}/repo" remote add origin "${repo_url}"
      fi

      local work_dir="${tmp_dir}/repo"

      # 3. Copy service manifests (replace all content except .git)
      if [[ -d "$source_dir" ]]; then
        find "${work_dir}" -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +
        cp -a "${source_dir}/." "${work_dir}/"
      else
        log_warn "Source directory not found: ${source_dir}"
      fi

      # 4. Substitute CHANGEME tokens and domain references
      find "${work_dir}" \( -name '*.yaml' -o -name '*.yml' \) -not -path '*/.git/*' \
        | while read -r f; do
            _subst_changeme < "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
          done

      # 5. Commit and push
      git -C "${work_dir}" config user.name "${GIT_AUTHOR_NAME}"
      git -C "${work_dir}" config user.email "${GIT_AUTHOR_EMAIL}"
      git -C "${work_dir}" add -A

      if git -C "${work_dir}" diff --cached --quiet 2>/dev/null; then
        log_info "No changes to commit for ${repo_name}"
      else
        git -C "${work_dir}" commit -m "Update service manifests from rke2-cluster bootstrap"
      fi

      # Push (handle empty repo with no branch yet)
      if ! git -C "${work_dir}" push -u origin main 2>/dev/null; then
        git -C "${work_dir}" branch -M main
        git -C "${work_dir}" push -u origin main
      fi

      rm -rf "${tmp_dir}"
      log_ok "Pushed substituted manifests to ${GIT_OWNER}/${repo_name}"
    fi
  } >&2

  echo "${repo_url}"
}

# -----------------------------------------------------------------------------
# Helper: Generate an ArgoCD Application manifest for a service.
# Usage: generate_app_manifest <name> <repo_url> <namespace> <sync_policy>
# Writes YAML to ${BOOTSTRAP_APPS_DIR}/<name>.yaml
# -----------------------------------------------------------------------------
generate_app_manifest() {
  local name="$1"
  local repo_url="$2"
  local namespace="$3"
  local sync_policy="$4"
  local output_file="${BOOTSTRAP_APPS_DIR}/${name}.yaml"

  mkdir -p "${BOOTSTRAP_APPS_DIR}"

  # Build destination block (omit namespace for cluster-scoped resources)
  local destination
  if [[ -n "$namespace" ]]; then
    destination="    server: https://kubernetes.default.svc
    namespace: ${namespace}"
  else
    destination="    server: https://kubernetes.default.svc"
  fi

  # Build syncPolicy block
  local sync_block
  if [[ "$sync_policy" == "auto" ]]; then
    sync_block="  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true"
  else
    sync_block="  syncPolicy:
    syncOptions:
      - CreateNamespace=true"
  fi

  cat > "${output_file}" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${name}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${repo_url}
    targetRevision: main
    path: .
  destination:
${destination}
${sync_block}
EOF

  log_ok "Generated: ${output_file#${REPO_ROOT}/}"
}

# =============================================================================
# PHASE 1: GITHUB <-> ARGOCD CONNECTION
# =============================================================================
phase_1_github_argocd() {
  start_phase "PHASE 1: GITHUB <-> ARGOCD CONNECTION"

  ensure_gh_cli

  # 1.1 Generate SSH deploy key
  log_step "Generating SSH deploy key pair..."
  mkdir -p "$DEPLOY_KEY_DIR"
  chmod 700 "$DEPLOY_KEY_DIR"

  if [[ -f "$DEPLOY_KEY_PRIVATE" ]]; then
    log_info "Deploy key already exists at ${DEPLOY_KEY_PRIVATE}"
  else
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[DRY RUN] Would generate SSH key at ${DEPLOY_KEY_PRIVATE}"
    else
      ssh-keygen -t ed25519 -f "$DEPLOY_KEY_PRIVATE" -N "" -C "argocd@${DOMAIN}"
      log_ok "Deploy key generated"
    fi
  fi

  # 1.2 Add SSH key to GitHub user account
  # Deploy keys are per-repo (can't share one key across repos), so we
  # register the key at the user level instead. This gives ArgoCD access
  # to all repos under this GitHub user.
  if [[ "$DRY_RUN" == "false" && -f "$DEPLOY_KEY_PUBLIC" ]]; then
    log_step "Adding SSH key to GitHub account..."
    local key_title="ArgoCD Deploy Key (${KC_REALM})"
    if gh ssh-key add "$DEPLOY_KEY_PUBLIC" --title "$key_title" 2>/dev/null; then
      log_ok "SSH key added to GitHub account"
    else
      log_info "SSH key may already be registered on GitHub (this is fine)"
    fi
  fi

  # 1.3 Add github.com SSH host key to ArgoCD known hosts
  log_step "Updating ArgoCD SSH known hosts for github.com..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would add github.com to ArgoCD known hosts"
  else
    local known_hosts
    known_hosts=$(ssh-keyscan -T 5 github.com 2>/dev/null || echo "")

    if [[ -z "$known_hosts" ]]; then
      log_warn "Could not reach github.com via SSH. Add host key manually later."
    else
      local current_known_hosts
      current_known_hosts=$(kubectl -n argocd get configmap argocd-ssh-known-hosts-cm \
        -o jsonpath='{.data.ssh_known_hosts}' 2>/dev/null || echo "")

      if echo "$current_known_hosts" | grep -q "github.com"; then
        log_info "github.com already in ArgoCD known hosts"
      else
        local updated_hosts="${current_known_hosts}"$'\n'"${known_hosts}"
        kubectl -n argocd patch configmap argocd-ssh-known-hosts-cm --type merge \
          -p "$(jq -n --arg hosts "$updated_hosts" '{"data": {"ssh_known_hosts": $hosts}}')" 2>/dev/null || \
          log_warn "Could not update argocd-ssh-known-hosts-cm (add github.com manually)"
        log_ok "github.com host key added to ArgoCD known hosts"
      fi
    fi
  fi

  # 1.4 Create ArgoCD credential template for all repos under GIT_OWNER
  # This single Secret allows ArgoCD to clone any repo matching the URL prefix.
  log_step "Creating ArgoCD credential template for GitHub repos..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create ArgoCD repo credential template"
  else
    local private_key
    private_key=$(cat "$DEPLOY_KEY_PRIVATE")

    kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
type: Opaque
stringData:
  type: git
  url: git@github.com:${GIT_OWNER}
  sshPrivateKey: |
$(echo "$private_key" | sed 's/^/    /')
EOF
    log_ok "ArgoCD credential template created (matches all repos under ${GIT_OWNER})"
  fi

  # 1.5 Also register the infra repo explicitly (for app-of-apps)
  log_step "Registering infra repo in ArgoCD..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would register infra repo: ${INFRA_REPO_URL}"
  else
    local private_key
    private_key=$(cat "$DEPLOY_KEY_PRIVATE")

    kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-rke2-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: "${INFRA_REPO_URL}"
  sshPrivateKey: |
$(echo "$private_key" | sed 's/^/    /')
  insecure: "false"
  enableLfs: "false"
EOF
    log_ok "Infra repo registered in ArgoCD"
  fi

  # 1.6 Verify connection
  if [[ "$DRY_RUN" == "false" ]]; then
    log_step "Waiting for ArgoCD to recognize credentials..."
    sleep 10

    local argocd_server
    argocd_server=$(kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-server \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$argocd_server" ]]; then
      local repo_list
      repo_list=$(kubectl exec -n argocd "$argocd_server" -- \
        argocd repo list --server localhost:8080 --plaintext --insecure 2>/dev/null || echo "")
      if echo "$repo_list" | grep -q "github.com"; then
        log_ok "ArgoCD repository connection verified"
      else
        log_warn "ArgoCD repo not yet visible (may need a few more seconds)"
      fi
    fi
  fi

  end_phase "PHASE 1: GITHUB <-> ARGOCD"
}

# =============================================================================
# PHASE 2: APP-OF-APPS BOOTSTRAP
# =============================================================================
phase_2_bootstrap() {
  start_phase "PHASE 2: APP-OF-APPS BOOTSTRAP"

  # 2.1 Create service repos and generate Application manifests
  log_step "Creating service repos and generating Application manifests..."
  mkdir -p "${BOOTSTRAP_APPS_DIR}"

  local service_count=0
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r svc_name svc_source svc_namespace svc_sync <<< "$entry"
    echo ""
    log_info "--- ${svc_name} ---"

    # Create GitHub repo and push substituted manifests
    local repo_url
    repo_url=$(create_service_repo "$svc_name" "$svc_source")

    # Generate ArgoCD Application manifest
    generate_app_manifest "$svc_name" "$repo_url" "$svc_namespace" "$svc_sync"

    service_count=$((service_count + 1))
  done

  log_ok "Processed ${service_count} services"

  # 2.2 Commit generated Application manifests to infra repo and push
  if [[ "$DRY_RUN" == "false" ]]; then
    log_step "Committing Application manifests to infra repo..."
    git -C "${REPO_ROOT}" add "${BOOTSTRAP_APPS_DIR}/"
    if ! git -C "${REPO_ROOT}" diff --cached --quiet 2>/dev/null; then
      git -C "${REPO_ROOT}" \
        -c user.name="${GIT_AUTHOR_NAME}" \
        -c user.email="${GIT_AUTHOR_EMAIL}" \
        commit -m "Add ArgoCD Application manifests for ${service_count} services"
      git -C "${REPO_ROOT}" push origin main
      log_ok "Application manifests committed and pushed to infra repo"
    else
      log_info "No new Application manifests to commit"
    fi
  else
    log_info "[DRY RUN] Would commit ${service_count} Application manifests to infra repo"
  fi

  # 2.3 Apply app-of-apps root Application
  # This Application watches services/argo/bootstrap/apps/ in the infra repo
  # and creates/manages all child Applications.
  log_step "Applying app-of-apps root Application..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would apply app-of-apps.yaml (points to infra repo)"
  else
    kube_apply_subst "${SERVICES_DIR}/argo/bootstrap/app-of-apps.yaml"
    log_ok "App-of-apps root Application applied"
  fi

  # 2.4 Wait and verify child Applications appear
  if [[ "$DRY_RUN" == "false" ]]; then
    log_step "Waiting for ArgoCD to sync applications..."
    sleep 15

    log_step "Verifying child applications..."
    for entry in "${SERVICES[@]}"; do
      IFS='|' read -r svc_name _ _ _ <<< "$entry"
      local status
      status=$(kubectl -n argocd get application "$svc_name" \
        -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "NotFound")
      if [[ "$status" == "NotFound" ]]; then
        log_warn "  Application '${svc_name}' not found yet (sync may be in progress)"
      else
        log_ok "  Application '${svc_name}': ${status}"
      fi
    done
  fi

  end_phase "PHASE 2: APP-OF-APPS BOOTSTRAP"
}

# =============================================================================
# PHASE 3: HARBOR CI INTEGRATION
# =============================================================================
phase_3_harbor_ci() {
  start_phase "PHASE 3: HARBOR CI INTEGRATION"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create Harbor CI robot accounts and imagePullSecret"
    end_phase "PHASE 3: HARBOR CI"
    return 0
  fi

  local harbor_admin_pass
  harbor_admin_pass=$(grep 'harborAdminPassword' "${SERVICES_DIR}/harbor/harbor-values.yaml" | awk -F'"' '{print $2}')
  local harbor_api="http://harbor-core.harbor.svc.cluster.local/api/v2.0"
  local auth="admin:${harbor_admin_pass}"

  local harbor_core_pod
  harbor_core_pod=$(kubectl -n harbor get pod -l component=core -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$harbor_core_pod" ]]; then
    log_warn "Harbor core pod not found, skipping robot account creation"
    log_info "Create robot accounts manually via Harbor UI"
    end_phase "PHASE 3: HARBOR CI"
    return 0
  fi

  # 3.1 Create CI push robot (access to library, charts, dev projects)
  log_step "Creating Harbor CI robot account (push access)..."
  local ci_robot_response
  ci_robot_response=$(kubectl exec -n harbor "$harbor_core_pod" -- \
    curl -sf -u "$auth" -X POST "${harbor_api}/robots" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "ci-push",
      "description": "CI push access for library, charts, dev projects",
      "duration": -1,
      "level": "system",
      "permissions": [
        {
          "namespace": "library",
          "kind": "project",
          "access": [
            {"resource": "repository", "action": "push"},
            {"resource": "repository", "action": "pull"},
            {"resource": "artifact", "action": "delete"},
            {"resource": "tag", "action": "create"},
            {"resource": "tag", "action": "delete"},
            {"resource": "helm-chart", "action": "read"},
            {"resource": "helm-chart-version", "action": "create"},
            {"resource": "helm-chart-version", "action": "delete"}
          ]
        },
        {
          "namespace": "charts",
          "kind": "project",
          "access": [
            {"resource": "repository", "action": "push"},
            {"resource": "repository", "action": "pull"},
            {"resource": "helm-chart", "action": "read"},
            {"resource": "helm-chart-version", "action": "create"},
            {"resource": "helm-chart-version", "action": "delete"}
          ]
        },
        {
          "namespace": "dev",
          "kind": "project",
          "access": [
            {"resource": "repository", "action": "push"},
            {"resource": "repository", "action": "pull"},
            {"resource": "artifact", "action": "delete"},
            {"resource": "tag", "action": "create"},
            {"resource": "tag", "action": "delete"}
          ]
        }
      ]
    }' 2>/dev/null || echo '{"error": "failed"}')

  local ci_robot_secret
  ci_robot_secret=$(echo "$ci_robot_response" | jq -r '.secret // empty')
  local ci_robot_name
  ci_robot_name=$(echo "$ci_robot_response" | jq -r '.name // "robot$ci-push"')

  if [[ -n "$ci_robot_secret" ]]; then
    log_ok "CI robot created: ${ci_robot_name}"
  else
    log_warn "CI robot creation failed (may already exist). Create manually in Harbor UI."
    ci_robot_name="robot\$ci-push"
    ci_robot_secret="<create-manually>"
  fi

  # 3.2 Create cluster pull robot (pull from all projects)
  log_step "Creating Harbor cluster pull robot account..."
  local pull_robot_response
  pull_robot_response=$(kubectl exec -n harbor "$harbor_core_pod" -- \
    curl -sf -u "$auth" -X POST "${harbor_api}/robots" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "cluster-pull",
      "description": "Cluster-wide pull access for all projects",
      "duration": -1,
      "level": "system",
      "permissions": [
        {
          "namespace": "*",
          "kind": "project",
          "access": [
            {"resource": "repository", "action": "pull"}
          ]
        }
      ]
    }' 2>/dev/null || echo '{"error": "failed"}')

  local pull_robot_secret
  pull_robot_secret=$(echo "$pull_robot_response" | jq -r '.secret // empty')
  local pull_robot_name
  pull_robot_name=$(echo "$pull_robot_response" | jq -r '.name // "robot$cluster-pull"')

  if [[ -n "$pull_robot_secret" ]]; then
    log_ok "Cluster pull robot created: ${pull_robot_name}"
  else
    log_warn "Cluster pull robot creation failed (may already exist)"
    pull_robot_name="robot\$cluster-pull"
    pull_robot_secret="<create-manually>"
  fi

  # 3.3 Create imagePullSecret for the cluster
  if [[ "$pull_robot_secret" != "<create-manually>" ]]; then
    log_step "Creating imagePullSecret in default namespace..."
    kubectl create secret docker-registry harbor-pull \
      --docker-server="harbor.${DOMAIN}" \
      --docker-username="$pull_robot_name" \
      --docker-password="$pull_robot_secret" \
      -n default --dry-run=client -o yaml | kubectl apply -f -
    log_ok "imagePullSecret 'harbor-pull' created"
  fi

  # Save robot credentials
  local robot_creds_file="${SCRIPTS_DIR}/harbor-robot-credentials.json"
  jq -n \
    --arg ci_name "$ci_robot_name" \
    --arg ci_secret "$ci_robot_secret" \
    --arg pull_name "$pull_robot_name" \
    --arg pull_secret "$pull_robot_secret" \
    '{
      ci_push: { name: $ci_name, secret: $ci_secret },
      cluster_pull: { name: $pull_name, secret: $pull_secret }
    }' > "$robot_creds_file"
  log_ok "Robot credentials saved to: ${robot_creds_file}"

  # Print CI/CD variable instructions (GitHub Actions Secrets)
  echo ""
  log_info "Set these as GitHub Actions Secrets in your app repositories:"
  echo "  HARBOR_REGISTRY    = harbor.${DOMAIN}"
  echo "  HARBOR_CI_USER     = ${ci_robot_name}"
  echo "  HARBOR_CI_PASSWORD = ${ci_robot_secret}  (masked)"
  echo "  ARGOCD_SERVER      = argo.${DOMAIN}"
  echo ""

  end_phase "PHASE 3: HARBOR CI INTEGRATION"
}

# =============================================================================
# PHASE 4: ARGO ROLLOUTS ANALYSIS TEMPLATES
# =============================================================================
phase_4_analysis_templates() {
  start_phase "PHASE 4: ARGO ROLLOUTS ANALYSIS TEMPLATES"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create ClusterAnalysisTemplates: success-rate, latency-p99, error-rate, pod-restarts"
    end_phase "PHASE 4: ANALYSIS TEMPLATES"
    return 0
  fi

  # 4.1 Success rate template
  log_step "Creating AnalysisTemplate: success-rate..."
  kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: success-rate
spec:
  args:
    - name: service-name
    - name: namespace
  metrics:
    - name: success-rate
      interval: 30s
      count: 10
      failureLimit: 2
      successCondition: result[0] > 0.99
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(
              http_requests_total{
                status!~"5..",
                namespace="{{args.namespace}}",
                service="{{args.service-name}}"
              }[5m]
            )) /
            sum(rate(
              http_requests_total{
                namespace="{{args.namespace}}",
                service="{{args.service-name}}"
              }[5m]
            ))
EOF
  log_ok "ClusterAnalysisTemplate 'success-rate' created"

  # 4.2 Latency P99 template
  log_step "Creating AnalysisTemplate: latency-p99..."
  kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: latency-p99
spec:
  args:
    - name: service-name
    - name: namespace
    - name: threshold-ms
      value: "500"
  metrics:
    - name: latency-p99
      interval: 30s
      count: 10
      failureLimit: 2
      successCondition: result[0] < {{args.threshold-ms}}
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc.cluster.local:9090
          query: |
            histogram_quantile(0.99,
              sum(rate(
                http_request_duration_seconds_bucket{
                  namespace="{{args.namespace}}",
                  service="{{args.service-name}}"
                }[5m]
              )) by (le)
            ) * 1000
EOF
  log_ok "ClusterAnalysisTemplate 'latency-p99' created"

  # 4.3 Error rate template
  log_step "Creating AnalysisTemplate: error-rate..."
  kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: error-rate
spec:
  args:
    - name: service-name
    - name: namespace
    - name: threshold
      value: "0.01"
  metrics:
    - name: error-rate
      interval: 30s
      count: 10
      failureLimit: 1
      successCondition: result[0] < {{args.threshold}}
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(
              http_requests_total{
                status=~"5..",
                namespace="{{args.namespace}}",
                service="{{args.service-name}}"
              }[5m]
            )) /
            sum(rate(
              http_requests_total{
                namespace="{{args.namespace}}",
                service="{{args.service-name}}"
              }[5m]
            ))
EOF
  log_ok "ClusterAnalysisTemplate 'error-rate' created"

  # 4.4 Pod restart template (catches CrashLoopBackOff)
  log_step "Creating AnalysisTemplate: pod-restarts..."
  kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: pod-restarts
spec:
  args:
    - name: namespace
    - name: rollout-name
  metrics:
    - name: pod-restarts
      interval: 30s
      count: 5
      failureLimit: 1
      successCondition: result[0] == 0
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc.cluster.local:9090
          query: |
            sum(increase(
              kube_pod_container_status_restarts_total{
                namespace="{{args.namespace}}",
                pod=~"{{args.rollout-name}}-.*"
              }[2m]
            ))
EOF
  log_ok "ClusterAnalysisTemplate 'pod-restarts' created"

  end_phase "PHASE 4: ANALYSIS TEMPLATES"
}

# =============================================================================
# PHASE 5: SAMPLE ROLLOUT + CI TEMPLATE
# =============================================================================
phase_5_samples() {
  start_phase "PHASE 5: SAMPLE ROLLOUT + CI TEMPLATES"

  local samples_dir="${SCRIPTS_DIR}/samples"
  mkdir -p "$samples_dir"

  # 5.1 Sample Blue/Green Rollout
  log_step "Generating sample blue/green Rollout CRD..."
  _subst_changeme > "${samples_dir}/sample-rollout-bluegreen.yaml" <<'EOF'
# =============================================================================
# Sample Blue/Green Rollout with Gateway API + Prometheus Analysis
# =============================================================================
# Modify this template for your application.
# The Argo Rollouts controller will:
#   1. Create a preview ReplicaSet
#   2. Run pre-promotion analysis (success-rate + latency-p99)
#   3. If analysis passes, switch traffic from active -> preview
#   4. Run post-promotion analysis (error-rate + pod-restarts)
#   5. Scale down old ReplicaSet after delay
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: sample-app
  namespace: sample-app
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: sample-app
  template:
    metadata:
      labels:
        app: sample-app
    spec:
      nodeSelector:
        workload-type: general
      containers:
        - name: app
          image: harbor.example.com/library/sample-app:latest
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
  strategy:
    blueGreen:
      activeService: sample-app-active
      previewService: sample-app-preview
      autoPromotionEnabled: false
      scaleDownDelaySeconds: 30
      prePromotionAnalysis:
        templates:
          - clusterTemplateRef:
              name: success-rate
          - clusterTemplateRef:
              name: latency-p99
        args:
          - name: service-name
            value: sample-app-preview
          - name: namespace
            value: sample-app
      postPromotionAnalysis:
        templates:
          - clusterTemplateRef:
              name: error-rate
          - clusterTemplateRef:
              name: pod-restarts
        args:
          - name: service-name
            value: sample-app-active
          - name: namespace
            value: sample-app
          - name: rollout-name
            value: sample-app
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: sample-app-route
            namespace: sample-app
---
apiVersion: v1
kind: Service
metadata:
  name: sample-app-active
  namespace: sample-app
spec:
  selector:
    app: sample-app
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: sample-app-preview
  namespace: sample-app
spec:
  selector:
    app: sample-app
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: sample-app
  namespace: sample-app
  annotations:
    cert-manager.io/cluster-issuer: vault-issuer
spec:
  gatewayClassName: traefik
  listeners:
    - name: http
      protocol: HTTP
      port: 8000
    - name: https
      protocol: HTTPS
      port: 8443
      hostname: "sample-app.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: sample-app-example-com-tls
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: sample-app-route
  namespace: sample-app
spec:
  parentRefs:
    - name: sample-app
      sectionName: https
  hostnames:
    - "sample-app.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: sample-app-active
          port: 80
        - name: sample-app-preview
          port: 80
EOF
  log_ok "Sample blue/green Rollout saved to: ${samples_dir}/sample-rollout-bluegreen.yaml"

  # 5.2 Sample Canary Rollout
  log_step "Generating sample canary Rollout CRD..."
  _subst_changeme > "${samples_dir}/sample-rollout-canary.yaml" <<'EOF'
# =============================================================================
# Sample Canary Rollout with Gateway API + Prometheus Analysis
# =============================================================================
# Traffic is shifted incrementally: 10% -> 30% -> 60% -> 100%
# Analysis runs at each pause step.
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: sample-app-canary
  namespace: sample-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: sample-app-canary
  template:
    metadata:
      labels:
        app: sample-app-canary
    spec:
      nodeSelector:
        workload-type: general
      containers:
        - name: app
          image: harbor.example.com/library/sample-app:latest
          ports:
            - containerPort: 8080
  strategy:
    canary:
      canaryService: sample-app-canary-preview
      stableService: sample-app-canary-stable
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: sample-app-canary-route
            namespace: sample-app
      steps:
        - setWeight: 10
        - pause: { duration: 60s }
        - analysis:
            templates:
              - clusterTemplateRef:
                  name: success-rate
              - clusterTemplateRef:
                  name: pod-restarts
            args:
              - name: service-name
                value: sample-app-canary-preview
              - name: namespace
                value: sample-app
              - name: rollout-name
                value: sample-app-canary
        - setWeight: 30
        - pause: { duration: 60s }
        - analysis:
            templates:
              - clusterTemplateRef:
                  name: success-rate
              - clusterTemplateRef:
                  name: latency-p99
            args:
              - name: service-name
                value: sample-app-canary-preview
              - name: namespace
                value: sample-app
              - name: threshold-ms
                value: "500"
        - setWeight: 60
        - pause: { duration: 60s }
        - analysis:
            templates:
              - clusterTemplateRef:
                  name: success-rate
              - clusterTemplateRef:
                  name: error-rate
            args:
              - name: service-name
                value: sample-app-canary-preview
              - name: namespace
                value: sample-app
        - setWeight: 100
EOF
  log_ok "Sample canary Rollout saved to: ${samples_dir}/sample-rollout-canary.yaml"

  # 5.3 Sample GitHub Actions workflow
  log_step "Generating sample GitHub Actions workflow..."
  _subst_changeme > "${samples_dir}/sample-github-actions.yml" <<'CIEOF'
# =============================================================================
# Sample GitHub Actions CI/CD Pipeline for ArgoCD + Harbor + Argo Rollouts
# =============================================================================
# Required GitHub Actions Secrets (Settings > Secrets and variables > Actions):
#   HARBOR_REGISTRY     - harbor.example.com
#   HARBOR_CI_USER      - robot$ci-push
#   HARBOR_CI_PASSWORD  - robot token
#   ARGOCD_SERVER       - argo.example.com
#   ARGOCD_AUTH_TOKEN   - ArgoCD API token
# =============================================================================

name: CI/CD Pipeline

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  IMAGE_NAME: ${{ secrets.HARBOR_REGISTRY }}/library/${{ github.event.repository.name }}

jobs:
  # ---------------------------------------------------------------------------
  # Lint
  # ---------------------------------------------------------------------------
  lint-yaml:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Lint YAML
        uses: ibiqlik/action-yamllint@v3
        with:
          config_data: "extends: relaxed"

  lint-helm:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - uses: actions/checkout@v4
      - name: Set up Helm
        uses: azure/setup-helm@v4
      - name: Lint Helm chart
        run: helm lint charts/${{ github.event.repository.name }}/

  # ---------------------------------------------------------------------------
  # Build & Push to Harbor
  # ---------------------------------------------------------------------------
  build:
    runs-on: ubuntu-latest
    needs: [lint-yaml]
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to Harbor
        uses: docker/login-action@v3
        with:
          registry: ${{ secrets.HARBOR_REGISTRY }}
          username: ${{ secrets.HARBOR_CI_USER }}
          password: ${{ secrets.HARBOR_CI_PASSWORD }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          push: true
          tags: |
            ${{ env.IMAGE_NAME }}:${{ github.sha }}
            ${{ env.IMAGE_NAME }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  # ---------------------------------------------------------------------------
  # Test
  # ---------------------------------------------------------------------------
  test:
    runs-on: ubuntu-latest
    needs: [build]
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - name: Run integration tests
        run: echo "Add your integration tests here"

  # ---------------------------------------------------------------------------
  # Deploy Staging (automatic)
  # ---------------------------------------------------------------------------
  deploy-staging:
    runs-on: ubuntu-latest
    needs: [test]
    if: github.ref == 'refs/heads/main'
    environment: staging
    steps:
      - name: Install ArgoCD CLI
        run: |
          curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
          chmod +x argocd
          sudo mv argocd /usr/local/bin/

      - name: Deploy to staging
        run: |
          argocd login ${{ secrets.ARGOCD_SERVER }} \
            --auth-token ${{ secrets.ARGOCD_AUTH_TOKEN }} \
            --grpc-web --insecure
          argocd app set ${{ github.event.repository.name }}-staging \
            --kustomize-image ${{ env.IMAGE_NAME }}:${{ github.sha }}
          argocd app sync ${{ github.event.repository.name }}-staging --prune --force
          argocd app wait ${{ github.event.repository.name }}-staging --health --timeout 300

  # ---------------------------------------------------------------------------
  # Deploy Production (manual approval via GitHub environment)
  # ---------------------------------------------------------------------------
  deploy-production:
    runs-on: ubuntu-latest
    needs: [deploy-staging]
    if: github.ref == 'refs/heads/main'
    environment:
      name: production
    steps:
      - name: Install ArgoCD CLI
        run: |
          curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
          chmod +x argocd
          sudo mv argocd /usr/local/bin/

      - name: Deploy to production
        run: |
          argocd login ${{ secrets.ARGOCD_SERVER }} \
            --auth-token ${{ secrets.ARGOCD_AUTH_TOKEN }} \
            --grpc-web --insecure
          argocd app set ${{ github.event.repository.name }}-production \
            --kustomize-image ${{ env.IMAGE_NAME }}:${{ github.sha }}
          argocd app sync ${{ github.event.repository.name }}-production --prune --force
          # Argo Rollouts handles the blue/green or canary strategy
          # ArgoCD will show "Progressing" until Rollouts completes analysis
          argocd app wait ${{ github.event.repository.name }}-production --health --timeout 600
CIEOF
  log_ok "Sample GitHub Actions workflow saved to: ${samples_dir}/sample-github-actions.yml"

  # 5.4 Sample ArgoCD Application for an app using Rollouts
  log_step "Generating sample ArgoCD Application for Rollout-managed app..."
  cat > "${samples_dir}/sample-argocd-app.yaml" <<EOF
# =============================================================================
# Sample ArgoCD Application that manages a Rollout-based deployment
# =============================================================================
# This Application watches a Git repo path and syncs Rollout + Services.
# Argo Rollouts takes over the actual deployment strategy (blue/green or canary).
# ArgoCD health checks understand Rollout CRDs natively when Argo Rollouts is installed.
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sample-app-production
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:${GIT_OWNER}/sample-app.git
    targetRevision: main
    path: deploy/production
  destination:
    server: https://kubernetes.default.svc
    namespace: sample-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - RespectIgnoreDifferences=true
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  ignoreDifferences:
    # Argo Rollouts manages replica count during progressive delivery
    - group: argoproj.io
      kind: Rollout
      jsonPointers:
        - /spec/replicas
EOF
  log_ok "Sample ArgoCD Application saved to: ${samples_dir}/sample-argocd-app.yaml"

  echo ""
  log_info "All sample files saved to: ${samples_dir}/"
  echo "  - sample-rollout-bluegreen.yaml   (Blue/Green with Prometheus analysis)"
  echo "  - sample-rollout-canary.yaml       (Canary with stepped traffic shifting)"
  echo "  - sample-github-actions.yml        (GitHub Actions: lint -> build -> test -> deploy)"
  echo "  - sample-argocd-app.yaml           (ArgoCD Application for Rollout-managed app)"
  echo ""

  end_phase "PHASE 5: SAMPLES"
}

# =============================================================================
# PHASE 6: VALIDATION
# =============================================================================
phase_6_validation() {
  start_phase "PHASE 6: CICD VALIDATION"

  # Build service repo list for display
  local repo_list=""
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r svc_name _ _ svc_sync <<< "$entry"
    local sync_label="auto-sync"
    [[ "$svc_sync" == "manual" ]] && sync_label="manual-sync"
    repo_list+="      ${svc_name}  (${sync_label})  ->  ${GIT_OWNER}/${REPO_PREFIX}-${svc_name}\n"
  done

  echo ""
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}  CICD SETUP SUMMARY${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo ""
  echo "  GitHub Owner: ${GIT_OWNER}"
  echo "  Infra Repo:   ${INFRA_REPO_URL}"
  echo "  Repo Prefix:  ${REPO_PREFIX}-*"
  echo ""
  echo "  ArgoCD:"
  echo "    URL:        https://argo.${DOMAIN}"
  echo "    Root App:   app-of-apps (watches infra repo -> services/argo/bootstrap/apps/)"
  echo "    Services:   ${#SERVICES[@]} applications"
  echo ""
  echo -e "  Service Repos:"
  echo -e "${repo_list}"
  echo "  Argo Rollouts:"
  echo "    Dashboard:  https://rollouts.${DOMAIN}"
  echo "    Templates:  success-rate, latency-p99, error-rate, pod-restarts"
  echo ""
  echo "  Harbor:"
  echo "    Registry:   https://harbor.${DOMAIN}"
  echo "    CI Robot:   (see ${SCRIPTS_DIR}/harbor-robot-credentials.json)"
  echo ""
  echo "  Pipeline Flow:"
  echo "    GitHub Actions -> Build image -> Push to Harbor -> Update Git manifest"
  echo "    ArgoCD detects change -> Syncs -> Argo Rollouts deploys"
  echo "    Rollouts runs AnalysisRun -> Queries Prometheus -> Promote/Rollback"
  echo ""
  echo "  Sample Files:"
  echo "    ${SCRIPTS_DIR}/samples/"
  echo ""
  echo -e "${YELLOW}  Remaining manual steps:${NC}"
  echo "    1. Set GitHub Actions Secrets (HARBOR_*, ARGOCD_*) in app repos"
  echo "    2. Create ArgoCD API token for CI (Settings > Accounts > admin > Generate)"
  echo "    3. Adapt sample GitHub Actions workflow for your application"
  echo "    4. Adapt sample Rollout CRD for your application"
  echo ""

  # Check ArgoCD apps status
  log_step "ArgoCD Application status:"
  if [[ "$DRY_RUN" == "false" ]]; then
    kubectl -n argocd get applications \
      -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status \
      2>/dev/null || log_warn "Could not list ArgoCD applications"
  else
    log_info "[DRY RUN] Would check ArgoCD application status"
  fi

  # Check ClusterAnalysisTemplates
  log_step "ClusterAnalysisTemplates:"
  if [[ "$DRY_RUN" == "false" ]]; then
    kubectl get clusteranalysistemplates 2>/dev/null || log_warn "No ClusterAnalysisTemplates found"
  else
    log_info "[DRY RUN] Would check ClusterAnalysisTemplates"
  fi

  # Verify service repos exist
  if [[ "$DRY_RUN" == "false" ]]; then
    log_step "Verifying GitHub service repos..."
    local repo_count
    repo_count=$(gh repo list "${GIT_OWNER}" --limit 100 --json name \
      -q "[.[] | select(.name | startswith(\"${REPO_PREFIX}-\"))] | length" 2>/dev/null || echo "0")
    log_ok "Found ${repo_count} service repos matching ${REPO_PREFIX}-*"
  fi

  print_total_time
  end_phase "PHASE 6: VALIDATION"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo -e "${BOLD}${BLUE}"
  echo "  CICD Setup — GitHub + ArgoCD + Argo Rollouts"
  echo -e "${NC}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}  *** DRY RUN MODE — no changes will be made ***${NC}"
    echo ""
  fi

  DEPLOY_START_TIME=$(date +%s)
  export DEPLOY_START_TIME

  check_prerequisites

  [[ $FROM_PHASE -le 1 ]] && phase_1_github_argocd
  [[ $FROM_PHASE -le 2 ]] && phase_2_bootstrap
  [[ $FROM_PHASE -le 3 ]] && phase_3_harbor_ci
  [[ $FROM_PHASE -le 4 ]] && phase_4_analysis_templates
  [[ $FROM_PHASE -le 5 ]] && phase_5_samples
  [[ $FROM_PHASE -le 6 ]] && phase_6_validation
}

main "$@"
