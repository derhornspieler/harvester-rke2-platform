#!/usr/bin/env bash
# =============================================================================
# setup-gitlab-services.sh — Break Monorepo into GitLab Projects
# =============================================================================
# Splits each service from services/ into its own GitLab project under a
# "Platform Services" group, structured for MinimalCD with ArgoCD and multi-cluster
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
      echo "  2  Create Platform Services group"
      echo "  3  GitLab <-> ArgoCD connection (SSH key, known hosts)"
      echo "  4  Create projects & push manifests (Kustomize base/overlay)"
      echo "  5  Generate ArgoCD Application manifests"
      echo "  6  Sample GitLab CI templates"
      echo "  7  Validation summary"
      echo "  8  Deploy GitLab runners (shared + group)"
      echo "  9  Example pipeline apps (hello-nginx, echo-go, static-site)"
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
GITLAB_HTTP_CODE=""
REPO_PREFIX="svc-${KC_REALM}"
CLUSTER_NAME=$(get_cluster_name)

# Load GitLab API token (env var → .env → file → prompt in Phase 1)
if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
  local_token_file="${SCRIPTS_DIR}/.gitlab-api-token"
  if [[ -f "$local_token_file" ]]; then
    GITLAB_API_TOKEN=$(cat "$local_token_file")
  fi
fi

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
# PHASE 2: CREATE "PLATFORM SERVICES" GROUP
# =============================================================================
phase_2_create_group() {
  start_phase "PHASE 2: CREATE PLATFORM SERVICES GROUP"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create/find GitLab group 'platform_services'"
    GROUP_ID="dry-run-group-id"
    end_phase "PHASE 2: CREATE GROUP"
    return 0
  fi

  # Check if group already exists (exact path match)
  log_step "Checking for existing 'platform_services' group..."
  local groups_response
  groups_response=$(gitlab_get "/groups?search=platform_services")

  GROUP_ID=$(echo "$groups_response" | jq -r '.[] | select(.path == "platform_services") | .id' 2>/dev/null | head -1)

  if [[ -n "$GROUP_ID" && "$GROUP_ID" != "null" ]]; then
    log_ok "Platform Services group already exists (ID: ${GROUP_ID})"
  else
    log_step "Creating 'Platform Services' group..."
    local create_response
    create_response=$(gitlab_post "/groups" \
      '{"name":"Platform Services","path":"platform_services","visibility":"private"}')

    GROUP_ID=$(echo "$create_response" | jq -r '.id // empty' 2>/dev/null)
    if [[ -z "$GROUP_ID" || "$GROUP_ID" == "null" ]]; then
      die "Failed to create Platform Services group: $(echo "$create_response" | jq -r '.message // .' 2>/dev/null)"
    fi
    log_ok "Platform Services group created (ID: ${GROUP_ID})"
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
    log_info "[DRY RUN] Would create ArgoCD repo credential template for git@gitlab.${DOMAIN}:platform_services"
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
  url: git@gitlab.${DOMAIN}:platform_services
  sshPrivateKey: |
$(echo "$private_key" | sed 's/^/    /')
EOF
    log_ok "ArgoCD credential template created (matches git@gitlab.${DOMAIN}:platform_services/*)"
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
  local repo_url="git@gitlab.${DOMAIN}:platform_services/${repo_name}.git"

  # All log output goes to stderr so stdout is clean for the URL
  {
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[DRY RUN] Would create project: platform_services/${repo_name}"
      log_info "[DRY RUN] Would push kustomize base/overlay from: $2"
    else
      # 4a. Create GitLab project under Services group
      local existing_project
      existing_project=$(gitlab_get "/projects?search=${repo_name}" | \
        jq -r ".[] | select(.path == \"${repo_name}\" and .namespace.path == \"platform_services\") | .id" 2>/dev/null | head -1)

      if [[ -n "$existing_project" && "$existing_project" != "null" ]]; then
        log_info "Project already exists: platform_services/${repo_name} (ID: ${existing_project})"
      else
        local create_response
        create_response=$(gitlab_post "/projects" \
          "{\"name\":\"${repo_name}\",\"path\":\"${repo_name}\",\"namespace_id\":${GROUP_ID},\"visibility\":\"private\",\"initialize_with_readme\":false}")

        local project_id
        project_id=$(echo "$create_response" | jq -r '.id // empty' 2>/dev/null)
        if [[ -z "$project_id" || "$project_id" == "null" ]]; then
          log_error "Failed to create project ${repo_name}"
          log_error "$(echo "$create_response" | jq -r '.message // .' 2>/dev/null)"
          echo "$repo_url"
          return 1
        fi
        log_ok "Created project: platform_services/${repo_name} (ID: ${project_id})"

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
      log_ok "Pushed kustomize base/overlay to platform_services/${repo_name}"
    fi
  } >&2

  echo "${repo_url}"
}

phase_4_create_projects() {
  start_phase "PHASE 4: CREATE PROJECTS & PUSH MANIFESTS"

  # If resuming, we need the group ID
  if [[ -z "$GROUP_ID" || "$GROUP_ID" == "dry-run-group-id" ]] && [[ "$DRY_RUN" == "false" ]]; then
    log_step "Looking up Platform Services group ID..."
    local groups_response
    groups_response=$(gitlab_get "/groups?search=platform_services")
    GROUP_ID=$(echo "$groups_response" | jq -r '.[] | select(.path == "platform_services") | .id' 2>/dev/null | head -1)
    if [[ -z "$GROUP_ID" || "$GROUP_ID" == "null" ]]; then
      die "Platform Services group not found. Run Phase 2 first."
    fi
    log_ok "Platform Services group ID: ${GROUP_ID}"
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
    local repo_url="git@gitlab.${DOMAIN}:platform_services/${repo_name}.git"

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
  KUSTOMIZE_URL: "CHANGEME_BINARY_URL_KUSTOMIZE"
  KUBECONFORM_URL: "CHANGEME_BINARY_URL_KUBECONFORM"
  CRD_SCHEMA_BASE: "CHANGEME_CRD_SCHEMA_BASE_URL"

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
    - curl -sLo /tmp/kustomize.tar.gz "${KUSTOMIZE_URL}"
    - tar xzf /tmp/kustomize.tar.gz -C /usr/local/bin/
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
    - curl -sLo /tmp/kubeconform.tar.gz "${KUBECONFORM_URL}"
    - tar xzf /tmp/kubeconform.tar.gz -C /usr/local/bin/
    - chmod +x /usr/local/bin/kubeconform
    - curl -sLo /tmp/kustomize.tar.gz "${KUSTOMIZE_URL}"
    - tar xzf /tmp/kustomize.tar.gz -C /usr/local/bin/
    - chmod +x /usr/local/bin/kustomize
  script:
    - |
      kustomize build base/ | kubeconform \
        -strict \
        -summary \
        -output json \
        -schema-location default \
        -schema-location '${CRD_SCHEMA_BASE}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
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

  # Substitute binary URL placeholders with actual values from .env
  sed -i \
    -e "s|CHANGEME_BINARY_URL_KUSTOMIZE|${BINARY_URL_KUSTOMIZE}|g" \
    -e "s|CHANGEME_BINARY_URL_KUBECONFORM|${BINARY_URL_KUBECONFORM}|g" \
    -e "s|CHANGEME_CRD_SCHEMA_BASE_URL|${CRD_SCHEMA_BASE_URL}|g" \
    "${samples_dir}/sample-gitlab-ci.yml"

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
      groups_response=$(gitlab_get "/groups?search=platform_services")
      GROUP_ID=$(echo "$groups_response" | jq -r '.[] | select(.path == "platform_services") | .id' 2>/dev/null | head -1)
    fi

    if [[ -n "$GROUP_ID" && "$GROUP_ID" != "null" ]]; then
      log_step "GitLab projects in Platform Services group:"
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
  echo "  Group:        ${GITLAB_URL}/platform_services"
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
    echo "    ${svc_name}  (${sync_label})  ->  platform_services/${REPO_PREFIX}-${svc_name}"
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
# PHASE 8: DEPLOY GITLAB RUNNERS (SHARED + GROUP)
# =============================================================================
phase_8_runners() {
  start_phase "PHASE 8: DEPLOY GITLAB RUNNERS"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would deploy shared + group GitLab runners"
    end_phase "PHASE 8: RUNNERS"
    return 0
  fi

  # 8.1 Create namespace and distribute Root CA
  log_step "Creating gitlab-runners namespace..."
  ensure_namespace "gitlab-runners"
  distribute_root_ca

  # 8.2 Apply RBAC manifests
  log_step "Applying RBAC manifests..."
  kube_apply_k "${SERVICES_DIR}/gitlab-runners"

  # 8.3 Create gitlab-runner-certs secret (Root CA for GitLab TLS trust)
  log_step "Creating gitlab-runner-certs secret..."
  local root_ca
  root_ca=$(extract_root_ca)
  if [[ -n "$root_ca" ]]; then
    kubectl create secret generic gitlab-runner-certs \
      --from-literal=ca.crt="$root_ca" \
      -n gitlab-runners --dry-run=client -o yaml | kubectl apply -f -
    log_ok "gitlab-runner-certs secret created"
  else
    log_warn "Could not extract Root CA — runners may fail TLS verification to GitLab"
  fi

  # 8.4 Look up group ID for group runner
  if [[ -z "$GROUP_ID" || "$GROUP_ID" == "null" ]]; then
    local groups_response
    groups_response=$(gitlab_get "/groups?search=platform_services")
    GROUP_ID=$(echo "$groups_response" | jq -r '.[] | select(.path == "platform_services") | .id' 2>/dev/null | head -1)
  fi

  # 8.5 Create shared (instance) runner via GitLab API (new auth token flow — GitLab 16+)
  # Note: gitlab_post inside $() runs in a subshell, so GITLAB_HTTP_CODE is lost.
  # We check for .token in the response body instead.
  log_step "Creating shared runner via GitLab API..."
  if [[ -n "${GITLAB_RUNNER_SHARED_TOKEN}" ]]; then
    log_info "GITLAB_RUNNER_SHARED_TOKEN already set — skipping API creation"
  else
    local shared_response
    shared_response=$(gitlab_post "/user/runners" \
      '{"runner_type":"instance_type","description":"shared-k8s-runner","tag_list":"shared,kubernetes,compute","run_untagged":true}')

    GITLAB_RUNNER_SHARED_TOKEN=$(echo "$shared_response" | jq -r '.token // empty' 2>/dev/null)
    if [[ -n "$GITLAB_RUNNER_SHARED_TOKEN" ]]; then
      log_ok "Shared runner created (token: ${GITLAB_RUNNER_SHARED_TOKEN:0:8}...)"
    else
      log_warn "Failed to create shared runner. Create manually in GitLab Admin > CI/CD > Runners."
      log_warn "Response: $(echo "$shared_response" | jq -r '.message // .' 2>/dev/null)"
    fi
  fi

  # 8.6 Create group runner for platform_services
  log_step "Creating group runner via GitLab API..."
  if [[ -n "${GITLAB_RUNNER_GROUP_TOKEN}" ]]; then
    log_info "GITLAB_RUNNER_GROUP_TOKEN already set — skipping API creation"
  else
    if [[ -n "$GROUP_ID" && "$GROUP_ID" != "null" ]]; then
      local group_response
      group_response=$(gitlab_post "/user/runners" \
        "{\"runner_type\":\"group_type\",\"group_id\":${GROUP_ID},\"description\":\"platform-services-k8s-runner\",\"tag_list\":\"group,kubernetes,platform-services\",\"run_untagged\":true}")

      GITLAB_RUNNER_GROUP_TOKEN=$(echo "$group_response" | jq -r '.token // empty' 2>/dev/null)
      if [[ -n "$GITLAB_RUNNER_GROUP_TOKEN" ]]; then
        log_ok "Group runner created (token: ${GITLAB_RUNNER_GROUP_TOKEN:0:8}...)"
      else
        log_warn "Failed to create group runner. Create manually in GitLab group > Build > Runners."
        log_warn "Response: $(echo "$group_response" | jq -r '.message // .' 2>/dev/null)"
      fi
    else
      log_warn "Platform Services group ID not found — skipping group runner creation"
    fi
  fi

  # 8.7 Add Helm repo + resolve chart
  log_step "Installing GitLab runner Helm charts..."
  helm_repo_add gitlab https://charts.gitlab.io
  if [[ "${AIRGAPPED:-false}" != "true" ]]; then
    helm repo update gitlab 2>/dev/null || true
  fi
  local runner_chart
  runner_chart=$(resolve_helm_chart "gitlab/gitlab-runner" "HELM_OCI_GITLAB_RUNNER")

  # 8.8 Install shared runner
  if [[ -n "${GITLAB_RUNNER_SHARED_TOKEN}" ]]; then
    log_step "Installing shared runner Helm release..."
    helm_install_if_needed gitlab-runner-shared "$runner_chart" gitlab-runners \
      -f "${SERVICES_DIR}/gitlab-runners/shared-runner-values.yaml" \
      --set runnerToken="${GITLAB_RUNNER_SHARED_TOKEN}" \
      --set gitlabUrl="https://gitlab.${DOMAIN}"
  else
    log_warn "No shared runner token — skipping Helm install for shared runner"
  fi

  # 8.9 Install group runner
  if [[ -n "${GITLAB_RUNNER_GROUP_TOKEN}" ]]; then
    log_step "Installing group runner Helm release..."
    helm_install_if_needed gitlab-runner-group "$runner_chart" gitlab-runners \
      -f "${SERVICES_DIR}/gitlab-runners/group-runner-values.yaml" \
      --set runnerToken="${GITLAB_RUNNER_GROUP_TOKEN}" \
      --set gitlabUrl="https://gitlab.${DOMAIN}"
  else
    log_warn "No group runner token — skipping Helm install for group runner"
  fi

  # 8.10 Save tokens back to .env (append/update without re-sourcing to avoid clobbering GITLAB_API_TOKEN)
  log_step "Saving runner tokens to .env..."
  if grep -q '^GITLAB_RUNNER_SHARED_TOKEN=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^GITLAB_RUNNER_SHARED_TOKEN=.*|GITLAB_RUNNER_SHARED_TOKEN=\"${GITLAB_RUNNER_SHARED_TOKEN}\"|" "$ENV_FILE"
    sed -i "s|^GITLAB_RUNNER_GROUP_TOKEN=.*|GITLAB_RUNNER_GROUP_TOKEN=\"${GITLAB_RUNNER_GROUP_TOKEN}\"|" "$ENV_FILE"
  else
    cat >> "$ENV_FILE" <<RUNNEREOF

# GitLab Runner tokens (populated by setup-gitlab-services.sh Phase 8)
GITLAB_RUNNER_SHARED_TOKEN="${GITLAB_RUNNER_SHARED_TOKEN}"
GITLAB_RUNNER_GROUP_TOKEN="${GITLAB_RUNNER_GROUP_TOKEN}"
RUNNEREOF
  fi
  log_ok "Runner tokens saved to ${ENV_FILE}"

  # 8.11 Verify runner pods
  log_step "Verifying runner pods..."
  sleep 10
  kubectl -n gitlab-runners get pods 2>/dev/null || log_warn "Could not list runner pods"

  end_phase "PHASE 8: RUNNERS"
}

# =============================================================================
# PHASE 9: EXAMPLE PIPELINE APPS
# =============================================================================
phase_9_example_apps() {
  start_phase "PHASE 9: EXAMPLE PIPELINE APPS"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create demo-apps namespace and push example apps"
    end_phase "PHASE 9: EXAMPLE APPS"
    return 0
  fi

  local examples_dir="${SCRIPTS_DIR}/samples/example-apps"
  if [[ ! -d "$examples_dir" ]]; then
    log_warn "Example apps directory not found at ${examples_dir} — skipping"
    end_phase "PHASE 9: EXAMPLE APPS"
    return 0
  fi

  # 9.1 Create demo-apps namespace
  log_step "Creating demo-apps namespace..."
  ensure_namespace "demo-apps"

  # 9.2 Create Harbor 'dev' project for CI builds
  log_step "Creating Harbor 'dev' project..."
  create_harbor_project "dev" "false"

  # 9.3 Look up group ID
  if [[ -z "$GROUP_ID" || "$GROUP_ID" == "null" ]]; then
    local groups_response
    groups_response=$(gitlab_get "/groups?search=platform_services")
    GROUP_ID=$(echo "$groups_response" | jq -r '.[] | select(.path == "platform_services") | .id' 2>/dev/null | head -1)
  fi

  if [[ -z "$GROUP_ID" || "$GROUP_ID" == "null" ]]; then
    log_warn "Platform Services group not found — skipping example app creation"
    end_phase "PHASE 9: EXAMPLE APPS"
    return 0
  fi

  # 9.4 Set CI/CD variables at group level
  log_step "Setting CI/CD variables on platform_services group..."
  for var_pair in \
    "HARBOR_REGISTRY=harbor.${DOMAIN}" \
    "HARBOR_CI_USER=admin" \
    "HARBOR_CI_PASSWORD=${HARBOR_ADMIN_PASSWORD}"; do
    local var_key="${var_pair%%=*}"
    local var_value="${var_pair#*=}"
    local masked="false"
    [[ "$var_key" == "HARBOR_CI_PASSWORD" ]] && masked="true"

    gitlab_api POST "/groups/${GROUP_ID}/variables" \
      -H "Content-Type: application/json" \
      -d "{\"key\":\"${var_key}\",\"value\":\"${var_value}\",\"protected\":false,\"masked\":${masked}}" \
      2>/dev/null || \
    gitlab_api PUT "/groups/${GROUP_ID}/variables/${var_key}" \
      -H "Content-Type: application/json" \
      -d "{\"value\":\"${var_value}\",\"protected\":false,\"masked\":${masked}}" \
      2>/dev/null || true
    log_ok "  Set ${var_key} on platform_services group"
  done

  # 9.5 Create GitLab projects and push example apps
  log_step "Creating example app projects..."

  # Use HTTPS push with API token (SSH may not be externally accessible)
  export GIT_SSL_NO_VERIFY=true

  for app_dir in "${examples_dir}"/*/; do
    local app_name
    app_name=$(basename "$app_dir")
    local project_name="${app_name}"
    local repo_url="https://oauth2:${GITLAB_API_TOKEN}@gitlab.${DOMAIN}/platform_services/${project_name}.git"

    log_info "--- ${app_name} ---"

    # Create project
    local existing_project
    existing_project=$(gitlab_get "/projects?search=${project_name}" | \
      jq -r ".[] | select(.path == \"${project_name}\" and .namespace.path == \"platform_services\") | .id" 2>/dev/null | head -1)

    local project_id=""
    if [[ -n "$existing_project" && "$existing_project" != "null" ]]; then
      log_info "Project already exists: platform_services/${project_name} (ID: ${existing_project})"
      project_id="$existing_project"
    else
      local create_response
      create_response=$(gitlab_post "/projects" \
        "{\"name\":\"${project_name}\",\"path\":\"${project_name}\",\"namespace_id\":${GROUP_ID},\"visibility\":\"private\",\"initialize_with_readme\":false}")

      project_id=$(echo "$create_response" | jq -r '.id // empty' 2>/dev/null)
      if [[ -n "$project_id" && "$project_id" != "null" ]]; then
        log_ok "Created project: platform_services/${project_name} (ID: ${project_id})"

        # Add deploy key (read-only)
        if [[ -f "$DEPLOY_KEY_PUBLIC" ]]; then
          local pub_key
          pub_key=$(cat "$DEPLOY_KEY_PUBLIC")
          gitlab_post "/projects/${project_id}/deploy_keys" \
            "{\"title\":\"ArgoCD Deploy Key\",\"key\":\"${pub_key}\",\"can_push\":false}" >/dev/null 2>&1 || true
        fi
        sleep 1
      else
        log_warn "Failed to create project ${project_name}"
        log_warn "Response: $(echo "$create_response" | jq -r '.message // .' 2>/dev/null)"
        continue
      fi
    fi

    # Clone or init, push code
    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/example-${app_name}-XXXXXX")

    if ! git clone "${repo_url}" "${tmp_dir}/repo" 2>/dev/null; then
      mkdir -p "${tmp_dir}/repo"
      git -C "${tmp_dir}/repo" init -b main
      git -C "${tmp_dir}/repo" remote add origin "${repo_url}"
    fi

    local work_dir="${tmp_dir}/repo"
    find "${work_dir}" -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +

    # Copy example app files and substitute CHANGEME tokens
    cp -a "${app_dir}"/. "${work_dir}/"
    find "${work_dir}" \( -name '*.yaml' -o -name '*.yml' \) -not -path '*/.git/*' \
      | while read -r f; do
          _subst_changeme < "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
        done

    git -C "${work_dir}" config user.name "${GIT_AUTHOR_NAME}"
    git -C "${work_dir}" config user.email "${GIT_AUTHOR_EMAIL}"
    git -C "${work_dir}" add -A

    if git -C "${work_dir}" diff --cached --quiet 2>/dev/null; then
      log_info "No changes to commit for ${project_name}"
    else
      git -C "${work_dir}" commit -m "Initial commit: ${app_name} example app"
    fi

    if ! git -C "${work_dir}" push -u origin main 2>/dev/null; then
      git -C "${work_dir}" branch -M main
      git -C "${work_dir}" push -u origin main
    fi

    rm -rf "${tmp_dir}"
    log_ok "Pushed ${app_name} to platform_services/${project_name}"
  done

  # 9.6 Verify pipelines
  log_step "Waiting for pipelines to trigger..."
  sleep 10
  for app_dir in "${examples_dir}"/*/; do
    local app_name
    app_name=$(basename "$app_dir")
    local project_path="platform_services%2F${app_name}"
    local pipelines
    pipelines=$(gitlab_get "/projects/${project_path}/pipelines?per_page=1" 2>/dev/null || echo "[]")
    local pipeline_status
    pipeline_status=$(echo "$pipelines" | jq -r '.[0].status // "none"' 2>/dev/null || echo "unknown")
    log_info "  ${app_name}: pipeline status = ${pipeline_status}"
  done

  end_phase "PHASE 9: EXAMPLE APPS"
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
  [[ $FROM_PHASE -le 8 ]] && phase_8_runners
  [[ $FROM_PHASE -le 9 ]] && phase_9_example_apps
}

main "$@"
