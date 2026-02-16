#!/usr/bin/env bash
# =============================================================================
# setup-gitlab-services.sh — Break Monorepo into GitLab Projects
# =============================================================================
# Splits each service from services/ into its own GitLab project under a
# "Services" group, structured for MinimalCD with ArgoCD and multi-cluster
# readiness (Kustomize base/overlay layout).
#
# This replaces the GitHub-based setup-cicd.sh flow — ArgoCD Application
# manifests in services/argo/bootstrap/apps/ will be overwritten to point
# to GitLab repos.
#
# Prerequisites:
#   - GitLab running at https://gitlab.${DOMAIN}
#   - GitLab API token with 'api' scope (env var, file, or interactive prompt)
#   - All services deployed (deploy-cluster.sh completed)
#   - KUBECONFIG set to RKE2 cluster
#   - Commands: curl, jq, git, ssh-keygen, kubectl
#
# Usage:
#   ./scripts/setup-gitlab-services.sh              # Full run
#   ./scripts/setup-gitlab-services.sh --from 3     # Resume from phase 3
#   ./scripts/setup-gitlab-services.sh --dry-run    # Print actions only
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# Load domain configuration from .env
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
      echo "Usage: $0 [--from PHASE] [--dry-run]"
      echo ""
      echo "Phases:"
      echo "  1  Prerequisites & GitLab authentication"
      echo "  2  Create Services group"
      echo "  3  GitLab <-> ArgoCD connection (SSH key, known hosts)"
      echo "  4  Create projects & push manifests (Kustomize base/overlay)"
      echo "  5  Generate ArgoCD Application manifests"
      echo "  6  Sample GitLab CI templates"
      echo "  7  Validation summary"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
GITLAB_URL="https://gitlab.${DOMAIN}"
GITLAB_API="${GITLAB_URL}/api/v4"
REPO_PREFIX="svc-${KC_REALM}"
CLUSTER_NAME=$(get_cluster_name)

# Deploy key paths (separate from GitHub key)
DEPLOY_KEY_DIR="${SCRIPTS_DIR}/.deploy-keys"
DEPLOY_KEY_PRIVATE="${DEPLOY_KEY_DIR}/argocd-gitlab-deploy-key"
DEPLOY_KEY_PUBLIC="${DEPLOY_KEY_DIR}/argocd-gitlab-deploy-key.pub"

# Bootstrap apps directory
BOOTSTRAP_APPS_DIR="${SERVICES_DIR}/argo/bootstrap/apps"

# Git author for service repo commits
GIT_AUTHOR_NAME="rke2-cluster-bootstrap"
GIT_AUTHOR_EMAIL="noreply@${DOMAIN}"

# Group ID (populated in Phase 2)
GROUP_ID=""

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
  "gitlab|services/gitlab|gitlab|auto"
  "rbac|services/rbac||auto"
  "node-labeler|services/node-labeler|node-labeler|auto"
  "storage-autoscaler|services/storage-autoscaler|storage-autoscaler|auto"
)

# Optional services (conditional on .env flags)
[[ "${DEPLOY_UPTIME_KUMA}" == "true" ]] && SERVICES+=("uptime-kuma|services/uptime-kuma|uptime-kuma|auto")
[[ "${DEPLOY_LIBRENMS}" == "true" ]] && SERVICES+=("librenms|services/librenms|librenms|auto")

# -----------------------------------------------------------------------------
# GitLab API Helpers
# -----------------------------------------------------------------------------

# Authenticated GitLab API call. Sets GITLAB_HTTP_CODE and returns body on stdout.
gitlab_api() {
  local method="$1"
  local endpoint="$2"
  shift 2
  local response
  response=$(curl -sk -w "\n%{http_code}" -X "$method" \
    "${GITLAB_API}${endpoint}" \
    -H "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
    "$@")
  GITLAB_HTTP_CODE=$(echo "$response" | tail -1)
  echo "$response" | sed '$d'
}

# GET with JSON response
gitlab_get() {
  gitlab_api GET "$1"
}

# POST with JSON body
gitlab_post() {
  local endpoint="$1"
  local data="$2"
  gitlab_api POST "$endpoint" -H "Content-Type: application/json" -d "$data"
}

# =============================================================================
# PHASE 1: PREREQUISITES & GITLAB AUTHENTICATION
# =============================================================================
phase_1_prerequisites() {
  start_phase "PHASE 1: PREREQUISITES & GITLAB AUTHENTICATION"

  # 1.1 Check required commands
  log_step "Checking prerequisites..."
  for cmd in curl jq git ssh-keygen kubectl; do
    require_cmd "$cmd"
  done
  log_ok "All required commands available"

  # 1.2 Check GitLab reachable
  log_step "Checking GitLab reachability at ${GITLAB_URL}..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would check GitLab at ${GITLAB_URL}"
  else
    local version_response
    version_response=$(curl -sk --max-time 10 "${GITLAB_API}/version" 2>/dev/null || echo "")
    if [[ -z "$version_response" ]]; then
      die "GitLab not reachable at ${GITLAB_URL}. Ensure GitLab is running."
    fi
    # Unauthenticated /version may return 401 — that's fine, just means it's reachable
    log_ok "GitLab is reachable at ${GITLAB_URL}"
  fi

  # 1.3 Authenticate
  log_step "Authenticating with GitLab API..."

  # Priority: env var → file → interactive prompt
  if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
    local token_file="${SCRIPTS_DIR}/.gitlab-api-token"
    if [[ -f "$token_file" ]]; then
      GITLAB_API_TOKEN=$(cat "$token_file")
      log_info "Loaded GitLab API token from ${token_file}"
    fi
  fi

  if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[DRY RUN] Would prompt for GitLab API token"
      GITLAB_API_TOKEN="dry-run-token"
    else
      echo ""
      echo -e "${YELLOW}GitLab API token not found in GITLAB_API_TOKEN env var or ${SCRIPTS_DIR}/.gitlab-api-token${NC}"
      echo ""
      echo "Create a Personal Access Token at:"
      echo "  ${GITLAB_URL}/-/user/personal_access_tokens"
      echo ""
      echo "Required scope: api"
      echo ""
      read -rsp "Paste your GitLab API token: " GITLAB_API_TOKEN
      echo ""

      if [[ -z "$GITLAB_API_TOKEN" ]]; then
        die "No token provided."
      fi

      # Save for future runs
      echo "$GITLAB_API_TOKEN" > "${SCRIPTS_DIR}/.gitlab-api-token"
      chmod 600 "${SCRIPTS_DIR}/.gitlab-api-token"
      log_ok "Token saved to ${SCRIPTS_DIR}/.gitlab-api-token"
    fi
  fi

  export GITLAB_API_TOKEN

  # 1.4 Validate token
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would validate GitLab API token"
  else
    local user_response
    user_response=$(gitlab_get "/user")
    if [[ "$GITLAB_HTTP_CODE" -ne 200 ]]; then
      die "GitLab API token is invalid (HTTP ${GITLAB_HTTP_CODE}). Check your token."
    fi
    local username
    username=$(echo "$user_response" | jq -r '.username // "unknown"')
    log_ok "Authenticated as: ${username}"
  fi

  end_phase "PHASE 1: PREREQUISITES"
}

# =============================================================================
# PHASE 2: CREATE "SERVICES" GROUP
# =============================================================================
phase_2_create_group() {
  start_phase "PHASE 2: CREATE SERVICES GROUP"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create/find GitLab group 'services'"
    GROUP_ID="dry-run-group-id"
    end_phase "PHASE 2: CREATE GROUP"
    return 0
  fi

  # Check if group already exists (exact path match)
  log_step "Checking for existing 'services' group..."
  local groups_response
  groups_response=$(gitlab_get "/groups?search=services")

  GROUP_ID=$(echo "$groups_response" | jq -r '.[] | select(.path == "services") | .id' 2>/dev/null | head -1)

  if [[ -n "$GROUP_ID" && "$GROUP_ID" != "null" ]]; then
    log_ok "Services group already exists (ID: ${GROUP_ID})"
  else
    log_step "Creating 'Services' group..."
    local create_response
    create_response=$(gitlab_post "/groups" \
      '{"name":"Services","path":"services","visibility":"private"}')

    if [[ "$GITLAB_HTTP_CODE" -lt 200 || "$GITLAB_HTTP_CODE" -ge 300 ]]; then
      die "Failed to create Services group (HTTP ${GITLAB_HTTP_CODE}): $(echo "$create_response" | jq -r '.message // .' 2>/dev/null)"
    fi

    GROUP_ID=$(echo "$create_response" | jq -r '.id')
    log_ok "Services group created (ID: ${GROUP_ID})"
  fi

  end_phase "PHASE 2: CREATE GROUP"
}

# =============================================================================
# PHASE 3: GITLAB <-> ARGOCD CONNECTION
# =============================================================================
phase_3_argocd_connection() {
  start_phase "PHASE 3: GITLAB <-> ARGOCD CONNECTION"

  # 3.1 Generate SSH deploy key
  log_step "Generating SSH deploy key pair for GitLab..."
  mkdir -p "$DEPLOY_KEY_DIR"
  chmod 700 "$DEPLOY_KEY_DIR"

  if [[ -f "$DEPLOY_KEY_PRIVATE" ]]; then
    log_info "Deploy key already exists at ${DEPLOY_KEY_PRIVATE}"
  else
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[DRY RUN] Would generate SSH key at ${DEPLOY_KEY_PRIVATE}"
    else
      ssh-keygen -t ed25519 -f "$DEPLOY_KEY_PRIVATE" -N "" -C "argocd-gitlab@${DOMAIN}"
      log_ok "Deploy key generated"
    fi
  fi

  # 3.2 Add GitLab SSH host key to ArgoCD known hosts
  log_step "Updating ArgoCD SSH known hosts for gitlab.${DOMAIN}..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would add gitlab.${DOMAIN} to ArgoCD known hosts"
  else
    local known_hosts
    known_hosts=$(ssh-keyscan -T 5 "gitlab.${DOMAIN}" 2>/dev/null || echo "")

    if [[ -z "$known_hosts" ]]; then
      log_warn "Could not reach gitlab.${DOMAIN} via SSH. Add host key manually later."
    else
      local current_known_hosts
      current_known_hosts=$(kubectl -n argocd get configmap argocd-ssh-known-hosts-cm \
        -o jsonpath='{.data.ssh_known_hosts}' 2>/dev/null || echo "")

      if echo "$current_known_hosts" | grep -q "gitlab.${DOMAIN}"; then
        log_info "gitlab.${DOMAIN} already in ArgoCD known hosts"
      else
        local updated_hosts="${current_known_hosts}"$'\n'"${known_hosts}"
        kubectl -n argocd patch configmap argocd-ssh-known-hosts-cm --type merge \
          -p "$(jq -n --arg hosts "$updated_hosts" '{"data": {"ssh_known_hosts": $hosts}}')" 2>/dev/null || \
          log_warn "Could not update argocd-ssh-known-hosts-cm (add gitlab.${DOMAIN} manually)"
        log_ok "gitlab.${DOMAIN} host key added to ArgoCD known hosts"
      fi
    fi
  fi

  # 3.3 Create ArgoCD credential template Secret for GitLab repos
  log_step "Creating ArgoCD credential template for GitLab repos..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create ArgoCD repo credential template for git@gitlab.${DOMAIN}:services"
  else
    local private_key
    private_key=$(cat "$DEPLOY_KEY_PRIVATE")

    kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
type: Opaque
stringData:
  type: git
  url: git@gitlab.${DOMAIN}:services
  sshPrivateKey: |
$(echo "$private_key" | sed 's/^/    /')
EOF
    log_ok "ArgoCD credential template created (matches git@gitlab.${DOMAIN}:services/*)"
  fi

  # 3.4 Verify ArgoCD sees the credentials
  if [[ "$DRY_RUN" == "false" ]]; then
    log_step "Verifying ArgoCD credential template..."
    sleep 5
    if kubectl -n argocd get secret gitlab-repo-creds &>/dev/null; then
      log_ok "ArgoCD credential template secret exists"
    else
      log_warn "Credential template secret not found — check argocd namespace"
    fi
  fi

  end_phase "PHASE 3: ARGOCD CONNECTION"
}

# =============================================================================
# PHASE 4: CREATE PROJECTS & PUSH MANIFESTS (KUSTOMIZE BASE/OVERLAY)
# =============================================================================

# Helper: Create a GitLab project, restructure into base/overlay, and push.
# Usage: create_gitlab_service_repo <service_name> <source_dir_relative>
create_gitlab_service_repo() {
  local service_name="$1"
  local source_dir="${REPO_ROOT}/$2"
  local repo_name="${REPO_PREFIX}-${service_name}"
  local repo_url="git@gitlab.${DOMAIN}:services/${repo_name}.git"

  # All log output goes to stderr so stdout is clean for the URL
  {
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[DRY RUN] Would create project: services/${repo_name}"
      log_info "[DRY RUN] Would push kustomize base/overlay from: $2"
    else
      # 4a. Create GitLab project under Services group
      local existing_project
      existing_project=$(gitlab_get "/projects?search=${repo_name}" | \
        jq -r ".[] | select(.path == \"${repo_name}\" and .namespace.path == \"services\") | .id" 2>/dev/null | head -1)

      if [[ -n "$existing_project" && "$existing_project" != "null" ]]; then
        log_info "Project already exists: services/${repo_name} (ID: ${existing_project})"
      else
        local create_response
        create_response=$(gitlab_post "/projects" \
          "{\"name\":\"${repo_name}\",\"path\":\"${repo_name}\",\"namespace_id\":${GROUP_ID},\"visibility\":\"private\",\"initialize_with_readme\":false}")

        if [[ "$GITLAB_HTTP_CODE" -lt 200 || "$GITLAB_HTTP_CODE" -ge 300 ]]; then
          log_error "Failed to create project ${repo_name} (HTTP ${GITLAB_HTTP_CODE})"
          log_error "$(echo "$create_response" | jq -r '.message // .' 2>/dev/null)"
          echo "$repo_url"
          return 1
        fi

        local project_id
        project_id=$(echo "$create_response" | jq -r '.id')
        log_ok "Created project: services/${repo_name} (ID: ${project_id})"

        # Add deploy key to project (read-only)
        if [[ -f "$DEPLOY_KEY_PUBLIC" ]]; then
          local pub_key
          pub_key=$(cat "$DEPLOY_KEY_PUBLIC")
          gitlab_post "/projects/${project_id}/deploy_keys" \
            "{\"title\":\"ArgoCD Deploy Key\",\"key\":\"${pub_key}\",\"can_push\":false}" >/dev/null 2>&1 || \
            log_warn "Could not add deploy key to ${repo_name} (may already exist)"
        fi

        sleep 1
      fi

      # 4b. Clone or init temp working copy
      local tmp_dir
      tmp_dir=$(mktemp -d "/tmp/svc-${service_name}-XXXXXX")

      # Set GIT_SSH_COMMAND to use our deploy key
      export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY_PRIVATE} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

      if ! git clone "${repo_url}" "${tmp_dir}/repo" 2>/dev/null; then
        mkdir -p "${tmp_dir}/repo"
        git -C "${tmp_dir}/repo" init -b main
        git -C "${tmp_dir}/repo" remote add origin "${repo_url}"
      fi

      local work_dir="${tmp_dir}/repo"

      # Clean existing content (preserve .git)
      find "${work_dir}" -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +

      # 4b. Restructure into Kustomize base/overlay layout
      local base_dir="${work_dir}/base"
      local overlay_dir="${work_dir}/overlays/${CLUSTER_NAME}"
      mkdir -p "$base_dir" "$overlay_dir"

      if [[ -d "$source_dir" ]]; then
        # Copy all files from source into base/ (skip .git dirs)
        find "$source_dir" -maxdepth 1 -not -name '.git' -not -path "$source_dir" | while read -r item; do
          cp -a "$item" "$base_dir/"
        done

        # If kustomization.yaml exists in base, keep it (paths remain valid)
        # If not, generate one listing all .yaml files
        if [[ ! -f "${base_dir}/kustomization.yaml" ]]; then
          log_info "Generating kustomization.yaml for ${service_name}..."
          local yaml_files
          yaml_files=$(find "$base_dir" -maxdepth 1 -name '*.yaml' -o -name '*.yml' | sort)

          {
            echo "apiVersion: kustomize.config.k8s.io/v1beta1"
            echo "kind: Kustomization"
            echo ""
            echo "resources:"
            for f in $yaml_files; do
              local basename
              basename=$(basename "$f")
              # Exclude Helm values files — ArgoCD manages K8s resources, not Helm values
              case "$basename" in
                *-values.yaml|*-values.yml|values-*.yaml|values-*.yml|values.yaml|values.yml)
                  continue ;;
              esac
              echo "  - ${basename}"
            done
          } > "${base_dir}/kustomization.yaml"
        fi

        # Create overlay kustomization.yaml referencing base
        cat > "${overlay_dir}/kustomization.yaml" <<OVERLAY_EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base
OVERLAY_EOF
      else
        log_warn "Source directory not found: ${source_dir}"
      fi

      # 4c. Substitute CHANGEME tokens in all YAML files
      find "${work_dir}" \( -name '*.yaml' -o -name '*.yml' \) -not -path '*/.git/*' \
        | while read -r f; do
            _subst_changeme < "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
          done

      # 4d. Commit and push
      git -C "${work_dir}" config user.name "${GIT_AUTHOR_NAME}"
      git -C "${work_dir}" config user.email "${GIT_AUTHOR_EMAIL}"
      git -C "${work_dir}" add -A

      if git -C "${work_dir}" diff --cached --quiet 2>/dev/null; then
        log_info "No changes to commit for ${repo_name}"
      else
        git -C "${work_dir}" commit -m "Restructure into Kustomize base/overlay layout"
      fi

      if ! git -C "${work_dir}" push -u origin main 2>/dev/null; then
        git -C "${work_dir}" branch -M main
        git -C "${work_dir}" push -u origin main
      fi

      rm -rf "${tmp_dir}"
      log_ok "Pushed kustomize base/overlay to services/${repo_name}"
    fi
  } >&2

  echo "${repo_url}"
}

phase_4_create_projects() {
  start_phase "PHASE 4: CREATE PROJECTS & PUSH MANIFESTS"

  # If resuming, we need the group ID
  if [[ -z "$GROUP_ID" || "$GROUP_ID" == "dry-run-group-id" ]] && [[ "$DRY_RUN" == "false" ]]; then
    log_step "Looking up Services group ID..."
    local groups_response
    groups_response=$(gitlab_get "/groups?search=services")
    GROUP_ID=$(echo "$groups_response" | jq -r '.[] | select(.path == "services") | .id' 2>/dev/null | head -1)
    if [[ -z "$GROUP_ID" || "$GROUP_ID" == "null" ]]; then
      die "Services group not found. Run Phase 2 first."
    fi
    log_ok "Services group ID: ${GROUP_ID}"
  fi

  log_step "Creating GitLab projects and pushing kustomize-structured manifests..."

  local service_count=0
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r svc_name svc_source svc_namespace svc_sync <<< "$entry"
    echo ""
    log_info "--- ${svc_name} ---"

    create_gitlab_service_repo "$svc_name" "$svc_source"
    service_count=$((service_count + 1))
  done

  log_ok "Processed ${service_count} services"

  end_phase "PHASE 4: CREATE PROJECTS"
}

# =============================================================================
# PHASE 5: GENERATE ARGOCD APPLICATION MANIFESTS
# =============================================================================

# Helper: Generate an ArgoCD Application manifest for a service.
# Usage: generate_gitlab_app_manifest <name> <repo_url> <namespace> <sync_policy>
generate_gitlab_app_manifest() {
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
    path: overlays/${CLUSTER_NAME}
  destination:
${destination}
${sync_block}
EOF

  log_ok "Generated: ${output_file#${REPO_ROOT}/}"
}

phase_5_argocd_manifests() {
  start_phase "PHASE 5: GENERATE ARGOCD APPLICATION MANIFESTS"

  # 5.1 Overwrite app manifests with GitLab-targeted versions
  log_step "Generating ArgoCD Application manifests (GitLab)..."
  mkdir -p "${BOOTSTRAP_APPS_DIR}"

  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r svc_name svc_source svc_namespace svc_sync <<< "$entry"
    local repo_name="${REPO_PREFIX}-${svc_name}"
    local repo_url="git@gitlab.${DOMAIN}:services/${repo_name}.git"

    generate_gitlab_app_manifest "$svc_name" "$repo_url" "$svc_namespace" "$svc_sync"
  done

  # 5.2 Update app-of-apps.yaml repoURL to use GitLab infra repo (if exists)
  # The app-of-apps still points to the infra repo (not individual service repos),
  # so we keep it pointing to the current git remote (GitHub or GitLab).
  # Only the child Application manifests change to point to GitLab service repos.
  log_info "app-of-apps.yaml continues to point to infra repo: ${GIT_REPO_URL}"

  # 5.3 Commit updated manifests to infra repo and push
  if [[ "$DRY_RUN" == "false" ]]; then
    log_step "Committing updated Application manifests to infra repo..."
    git -C "${REPO_ROOT}" add "${BOOTSTRAP_APPS_DIR}/"
    if ! git -C "${REPO_ROOT}" diff --cached --quiet 2>/dev/null; then
      git -C "${REPO_ROOT}" \
        -c user.name="${GIT_AUTHOR_NAME}" \
        -c user.email="${GIT_AUTHOR_EMAIL}" \
        commit -m "Update ArgoCD Application manifests to point to GitLab repos"
      git -C "${REPO_ROOT}" push origin main
      log_ok "Application manifests committed and pushed to infra repo"
    else
      log_info "No new Application manifest changes to commit"
    fi
  else
    log_info "[DRY RUN] Would commit updated Application manifests to infra repo"
  fi

  # 5.4 Apply app-of-apps to ArgoCD
  log_step "Applying app-of-apps root Application..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would apply app-of-apps.yaml"
  else
    kube_apply_subst "${SERVICES_DIR}/argo/bootstrap/app-of-apps.yaml"
    log_ok "App-of-apps root Application applied"
  fi

  # 5.5 Verify child Applications appear
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

  end_phase "PHASE 5: ARGOCD MANIFESTS"
}

# =============================================================================
# PHASE 6: SAMPLE GITLAB CI TEMPLATES
# =============================================================================
phase_6_samples() {
  start_phase "PHASE 6: SAMPLE GITLAB CI TEMPLATES"

  local samples_dir="${SCRIPTS_DIR}/samples"
  mkdir -p "$samples_dir"

  log_step "Generating sample .gitlab-ci.yml (MinimalCD validation pipeline)..."
  cat > "${samples_dir}/sample-gitlab-ci.yml" <<'CIEOF'
# =============================================================================
# MinimalCD Validation Pipeline for GitLab CI
# =============================================================================
# This pipeline validates Kubernetes manifests but does NOT deploy.
# ArgoCD handles deployment by watching this repo.
#
# Stages:
#   1. yaml-lint      — Lint all YAML files
#   2. kustomize-validate — Build kustomize base + overlays
#   3. schema-validate — Validate against K8s schemas (allow_failure)
#   4. build-image    — Build & push Docker image to Harbor (only if Dockerfile exists)
# =============================================================================

stages:
  - lint
  - validate
  - build

variables:
  KUSTOMIZE_VERSION: "5.6.0"
  KUBECONFORM_VERSION: "0.6.7"

# ---------------------------------------------------------------------------
# Stage 1: YAML Lint
# ---------------------------------------------------------------------------
yaml-lint:
  stage: lint
  image: cytopia/yamllint:latest
  script:
    - yamllint -c "{extends: relaxed, rules: {line-length: {max: 250}}}" .
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

# ---------------------------------------------------------------------------
# Stage 2: Kustomize Validate
# ---------------------------------------------------------------------------
kustomize-validate:
  stage: validate
  image: alpine:3.21
  before_script:
    - apk add --no-cache curl
    - curl -sLo /usr/local/bin/kustomize
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
        | tar xz -C /usr/local/bin/
    - chmod +x /usr/local/bin/kustomize
  script:
    - echo "=== Validating base/ ==="
    - kustomize build base/
    - |
      for overlay in overlays/*/; do
        if [ -d "$overlay" ]; then
          echo "=== Validating ${overlay} ==="
          kustomize build "$overlay"
        fi
      done
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

# ---------------------------------------------------------------------------
# Stage 3: Schema Validate (kubeconform — best-effort)
# ---------------------------------------------------------------------------
schema-validate:
  stage: validate
  image: alpine:3.21
  allow_failure: true
  before_script:
    - apk add --no-cache curl
    - curl -sLo /tmp/kubeconform.tar.gz
        "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz"
    - tar xzf /tmp/kubeconform.tar.gz -C /usr/local/bin/
    - chmod +x /usr/local/bin/kubeconform
    - curl -sLo /usr/local/bin/kustomize
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
        | tar xz -C /usr/local/bin/
    - chmod +x /usr/local/bin/kustomize
  script:
    - |
      kustomize build base/ | kubeconform \
        -strict \
        -summary \
        -output json \
        -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
        || true
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

# ---------------------------------------------------------------------------
# Stage 4: Build & Push Docker Image (only if Dockerfile exists)
# ---------------------------------------------------------------------------
build-image:
  stage: build
  image:
    name: gcr.io/kaniko-project/executor:debug
    entrypoint: [""]
  script:
    - mkdir -p /kaniko/.docker
    - echo "{\"auths\":{\"${HARBOR_REGISTRY}\":{\"auth\":\"$(echo -n ${HARBOR_CI_USER}:${HARBOR_CI_PASSWORD} | base64)\"}}}" > /kaniko/.docker/config.json
    - /kaniko/executor
        --context "${CI_PROJECT_DIR}"
        --dockerfile "${CI_PROJECT_DIR}/Dockerfile"
        --destination "${HARBOR_REGISTRY}/library/${CI_PROJECT_NAME}:${CI_COMMIT_SHORT_SHA}"
        --destination "${HARBOR_REGISTRY}/library/${CI_PROJECT_NAME}:latest"
        --cache=true
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      exists:
        - Dockerfile
  variables:
    HARBOR_REGISTRY: ""     # Set in GitLab CI/CD Settings > Variables
    HARBOR_CI_USER: ""      # Set in GitLab CI/CD Settings > Variables
    HARBOR_CI_PASSWORD: ""  # Set in GitLab CI/CD Settings > Variables (masked)
CIEOF

  log_ok "Sample GitLab CI saved to: ${samples_dir}/sample-gitlab-ci.yml"

  echo ""
  log_info "Sample files in: ${samples_dir}/"
  echo "  - sample-gitlab-ci.yml  (MinimalCD: lint -> kustomize-validate -> schema-validate -> build)"
  echo ""
  log_info "To use in a service repo, copy to the repo root as .gitlab-ci.yml"
  echo ""

  end_phase "PHASE 6: SAMPLES"
}

# =============================================================================
# PHASE 7: VALIDATION SUMMARY
# =============================================================================
phase_7_validation() {
  start_phase "PHASE 7: VALIDATION SUMMARY"

  # 7.1 List all created GitLab projects
  if [[ "$DRY_RUN" == "false" ]]; then
    # Look up group ID if not set (when resuming with --from 7)
    if [[ -z "$GROUP_ID" || "$GROUP_ID" == "null" ]]; then
      local groups_response
      groups_response=$(gitlab_get "/groups?search=services")
      GROUP_ID=$(echo "$groups_response" | jq -r '.[] | select(.path == "services") | .id' 2>/dev/null | head -1)
    fi

    if [[ -n "$GROUP_ID" && "$GROUP_ID" != "null" ]]; then
      log_step "GitLab projects in Services group:"
      local projects_response
      projects_response=$(gitlab_get "/groups/${GROUP_ID}/projects?per_page=100")
      echo "$projects_response" | jq -r '.[] | "  \(.path_with_namespace)  (\(.web_url))"' 2>/dev/null || \
        log_warn "Could not list projects"
    fi
  fi

  # 7.2 Check ArgoCD Application sync status
  if [[ "$DRY_RUN" == "false" ]]; then
    log_step "ArgoCD Application status:"
    kubectl -n argocd get applications \
      -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status \
      2>/dev/null || log_warn "Could not list ArgoCD applications"
  else
    log_info "[DRY RUN] Would check ArgoCD application status"
  fi

  # 7.3 Print summary
  echo ""
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}  GITLAB SERVICES SETUP SUMMARY${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo ""
  echo "  GitLab:       ${GITLAB_URL}"
  echo "  Group:        ${GITLAB_URL}/services"
  echo "  Repo Prefix:  ${REPO_PREFIX}-*"
  echo "  Cluster:      ${CLUSTER_NAME}"
  echo ""
  echo "  Structure (per service repo):"
  echo "    base/                           # All K8s manifests"
  echo "    base/kustomization.yaml         # Existing or auto-generated"
  echo "    overlays/${CLUSTER_NAME}/       # Current cluster overlay"
  echo "    overlays/${CLUSTER_NAME}/kustomization.yaml  # references ../../base"
  echo ""
  echo "  ArgoCD:"
  echo "    URL:        https://argo.${DOMAIN}"
  echo "    Root App:   app-of-apps (watches infra repo)"
  echo "    Services:   ${#SERVICES[@]} applications"
  echo "    Source:      path: overlays/${CLUSTER_NAME}"
  echo ""
  echo -e "  Service Repos:"
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r svc_name _ _ svc_sync <<< "$entry"
    local sync_label="auto-sync"
    [[ "$svc_sync" == "manual" ]] && sync_label="manual-sync"
    echo "    ${svc_name}  (${sync_label})  ->  services/${REPO_PREFIX}-${svc_name}"
  done
  echo ""
  echo "  Multi-Cluster:"
  echo "    To add a cluster, create overlays/<cluster-name>/kustomization.yaml"
  echo "    and a new ArgoCD Application pointing to that overlay path."
  echo ""
  echo "  Sample Files:"
  echo "    ${SCRIPTS_DIR}/samples/sample-gitlab-ci.yml"
  echo ""
  echo -e "${YELLOW}  Remaining manual steps:${NC}"
  echo "    1. Verify ArgoCD apps sync: kubectl -n argocd get applications"
  echo "    2. Copy sample-gitlab-ci.yml to service repos as .gitlab-ci.yml"
  echo "    3. Set Harbor CI variables in GitLab CI/CD Settings (HARBOR_REGISTRY, etc.)"
  echo "    4. For multi-cluster: add overlay dirs + ArgoCD Applications"
  echo ""

  print_total_time
  end_phase "PHASE 7: VALIDATION"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo -e "${BOLD}${BLUE}"
  echo "  GitLab Services Setup — Break Monorepo into GitLab Projects"
  echo -e "${NC}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}  *** DRY RUN MODE — no changes will be made ***${NC}"
    echo ""
  fi

  DEPLOY_START_TIME=$(date +%s)
  export DEPLOY_START_TIME

  [[ $FROM_PHASE -le 1 ]] && phase_1_prerequisites
  [[ $FROM_PHASE -le 2 ]] && phase_2_create_group
  [[ $FROM_PHASE -le 3 ]] && phase_3_argocd_connection
  [[ $FROM_PHASE -le 4 ]] && phase_4_create_projects
  [[ $FROM_PHASE -le 5 ]] && phase_5_argocd_manifests
  [[ $FROM_PHASE -le 6 ]] && phase_6_samples
  [[ $FROM_PHASE -le 7 ]] && phase_7_validation
}

main "$@"
