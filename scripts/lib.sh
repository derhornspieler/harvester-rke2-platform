#!/usr/bin/env bash
# =============================================================================
# lib.sh — Shared functions for RKE2 cluster deployment scripts
# =============================================================================
# Source this file from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib.sh"
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_DIR="${REPO_ROOT}/cluster"
SERVICES_DIR="${REPO_ROOT}/services"
SCRIPTS_DIR="${REPO_ROOT}/scripts"

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Timer
# -----------------------------------------------------------------------------
DEPLOY_START_TIME="${DEPLOY_START_TIME:-$(date +%s)}"
PHASE_START_TIME=""

start_phase() {
  PHASE_START_TIME=$(date +%s)
  local phase_name="$1"
  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BOLD}${BLUE}  ${phase_name}${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo ""
}

end_phase() {
  local phase_name="$1"
  local elapsed=$(( $(date +%s) - PHASE_START_TIME ))
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))
  echo ""
  echo -e "${GREEN}--- ${phase_name} completed in ${mins}m ${secs}s ---${NC}"
}

print_total_time() {
  local elapsed=$(( $(date +%s) - DEPLOY_START_TIME ))
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))
  echo ""
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo -e "${BOLD}${GREEN}  Total elapsed time: ${mins}m ${secs}s${NC}"
  echo -e "${BOLD}${GREEN}============================================================${NC}"
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

die() {
  log_error "$@"
  exit 1
}

# -----------------------------------------------------------------------------
# Prerequisite Checks
# -----------------------------------------------------------------------------
require_cmd() {
  local cmd="$1"
  command -v "$cmd" &>/dev/null || die "Required command not found: ${cmd}"
}

check_prerequisites() {
  log_info "Checking prerequisites..."
  local cmds=(terraform kubectl helm jq openssl curl)
  for cmd in "${cmds[@]}"; do
    require_cmd "$cmd"
  done
  log_ok "All required commands available"
}

validate_airgapped_prereqs() {
  log_info "Validating airgapped prerequisites..."
  local errors=0

  if [[ -z "${BOOTSTRAP_REGISTRY:-}" ]]; then
    log_error "AIRGAPPED=true but BOOTSTRAP_REGISTRY is not set"
    log_error "  A pre-existing registry is required for cluster bootstrap (Phases 0-3)"
    log_error "  Set BOOTSTRAP_REGISTRY to the hostname[:port] of your bootstrap registry"
    errors=$((errors + 1))
  fi

  if [[ -z "${UPSTREAM_PROXY_REGISTRY:-}" ]]; then
    log_error "AIRGAPPED=true but UPSTREAM_PROXY_REGISTRY is not set"
    log_info "  Tip: In most airgapped deployments, UPSTREAM_PROXY_REGISTRY == BOOTSTRAP_REGISTRY"
    errors=$((errors + 1))
  fi

  # Check Terraform provider filesystem mirror
  if [[ -f "$HOME/.terraformrc" ]] && grep -q "filesystem_mirror" "$HOME/.terraformrc" 2>/dev/null; then
    log_ok "Terraform provider filesystem mirror configured"
  else
    log_error "Terraform provider filesystem mirror not configured"
    log_error "  Create ~/.terraformrc with a filesystem_mirror block pointing to your local providers"
    errors=$((errors + 1))
  fi

  # Check all required HELM_OCI_* vars
  local required_oci_vars=(
    HELM_OCI_CERT_MANAGER HELM_OCI_CNPG HELM_OCI_CLUSTER_AUTOSCALER
    HELM_OCI_REDIS_OPERATOR HELM_OCI_VAULT HELM_OCI_HARBOR
    HELM_OCI_ARGOCD HELM_OCI_ARGO_ROLLOUTS HELM_OCI_ARGO_WORKFLOWS HELM_OCI_ARGO_EVENTS
    HELM_OCI_KASM HELM_OCI_KPS
  )
  if [[ "${DEPLOY_LIBRENMS:-false}" == "true" ]]; then
    required_oci_vars+=(HELM_OCI_MARIADB_OPERATOR)
  fi
  for var in "${required_oci_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      log_error "AIRGAPPED=true but ${var} is not set"
      errors=$((errors + 1))
    fi
  done

  if [[ -z "${GIT_BASE_URL:-}" ]]; then
    log_error "AIRGAPPED=true but GIT_BASE_URL is not set"
    errors=$((errors + 1))
  fi

  if [[ "${ARGO_ROLLOUTS_PLUGIN_URL:-}" == *"github.com"* ]]; then
    log_error "AIRGAPPED=true but ARGO_ROLLOUTS_PLUGIN_URL still points to github.com"
    errors=$((errors + 1))
  fi

  if [[ ! -f "${REPO_ROOT}/crds/gateway-api-v1.3.0-standard-install.yaml" ]]; then
    if [[ "${GATEWAY_API_CRD_URL:-}" == *"github.com"* ]]; then
      log_error "AIRGAPPED=true but crds/gateway-api-v1.3.0-standard-install.yaml not found and GATEWAY_API_CRD_URL still points to github.com"
      errors=$((errors + 1))
    fi
  fi

  # Check binary URL overrides point away from github.com
  local binary_vars=(BINARY_URL_ARGOCD_CLI BINARY_URL_KUSTOMIZE BINARY_URL_KUBECONFORM)
  for var in "${binary_vars[@]}"; do
    if [[ "${!var:-}" == *"github.com"* ]]; then
      log_error "AIRGAPPED=true but ${var} still points to github.com"
      errors=$((errors + 1))
    fi
  done
  if [[ "${CRD_SCHEMA_BASE_URL:-}" == *"githubusercontent.com"* ]]; then
    log_error "AIRGAPPED=true but CRD_SCHEMA_BASE_URL still points to githubusercontent.com"
    errors=$((errors + 1))
  fi

  # Soft warnings for CI proxy configuration (not blocking errors)
  if [[ -z "${CI_GOPROXY:-}" ]]; then
    log_warn "CI_GOPROXY not set — Go CI builds will require vendor/ directories"
  fi
  if [[ -z "${CI_NPM_REGISTRY:-}" ]]; then
    log_warn "CI_NPM_REGISTRY not set — npm CI will need pre-populated cache"
  fi
  if [[ -z "${CI_PIP_INDEX_URL:-}" ]]; then
    log_warn "CI_PIP_INDEX_URL not set — pip CI will need pre-cached packages"
  fi

  if [[ $errors -gt 0 ]]; then
    echo ""
    log_info "Required Helm charts for airgapped deployment:"
    echo "  HELM_OCI_CERT_MANAGER        — cert-manager v1.19.3 (upstream: https://charts.jetstack.io)"
    echo "  HELM_OCI_CNPG                — cloudnative-pg 0.27.1 (upstream: https://cloudnative-pg.github.io/charts)"
    echo "  HELM_OCI_CLUSTER_AUTOSCALER  — cluster-autoscaler (upstream: https://kubernetes.github.io/autoscaler)"
    echo "  HELM_OCI_REDIS_OPERATOR      — redis-operator (upstream: https://ot-container-kit.github.io/helm-charts/)"
    echo "  HELM_OCI_VAULT               — vault 0.32.0 (upstream: https://helm.releases.hashicorp.com)"
    echo "  HELM_OCI_HARBOR              — harbor 1.18.2 (upstream: https://helm.goharbor.io)"
    echo "  HELM_OCI_ARGOCD              — argo-cd (upstream: oci://ghcr.io/argoproj/argo-helm/argo-cd)"
    echo "  HELM_OCI_ARGO_ROLLOUTS       — argo-rollouts (upstream: oci://ghcr.io/argoproj/argo-helm/argo-rollouts)"
    echo "  HELM_OCI_ARGO_WORKFLOWS      — argo-workflows (upstream: oci://ghcr.io/argoproj/argo-helm/argo-workflows)"
    echo "  HELM_OCI_ARGO_EVENTS         — argo-events (upstream: oci://ghcr.io/argoproj/argo-helm/argo-events)"
    echo "  HELM_OCI_KASM                — kasm 1.1181.0 (upstream: https://helm.kasmweb.com/)"
    echo "  HELM_OCI_KPS                 — kube-prometheus-stack (upstream: https://prometheus-community.github.io/helm-charts)"
    if [[ "${DEPLOY_LIBRENMS:-false}" == "true" ]]; then
      echo "  HELM_OCI_MARIADB_OPERATOR    — mariadb-operator (upstream: https://mariadb-operator.github.io/mariadb-operator)"
    fi
    echo ""
    echo "  Set each to an OCI URL, e.g.: HELM_OCI_CERT_MANAGER=oci://harbor.${DOMAIN:-example.com}/charts.jetstack.io/cert-manager"
    echo "  See docs/airgapped-mode.md for full instructions."
    die "Airgapped validation failed with ${errors} error(s). Fix the above issues."
  fi
  log_ok "Airgapped prerequisites validated"
}

# -----------------------------------------------------------------------------
# CHANGEME Validation
# -----------------------------------------------------------------------------
check_changeme_placeholders() {
  log_info "Scanning for unreplaced CHANGEME placeholders in services/..."
  local found
  found=$(grep -rl "CHANGEME" "${SERVICES_DIR}" --include="*.yaml" --include="*.yml" 2>/dev/null || true)

  # Exclude README files and comments-only matches
  local real_issues=()
  for f in $found; do
    # Skip README/doc files
    [[ "$f" == *README* ]] && continue
    # Check if CHANGEME appears outside of comments
    if grep -v '^\s*#' "$f" | grep -q "CHANGEME"; then
      real_issues+=("$f")
    fi
  done

  if [[ ${#real_issues[@]} -gt 0 ]]; then
    log_error "Found unreplaced CHANGEME placeholders in:"
    for f in "${real_issues[@]}"; do
      echo "  - ${f#${REPO_ROOT}/}"
    done
    die "Replace all CHANGEME values before deploying. See Pre-Deployment checklist."
  fi
  log_ok "No unreplaced CHANGEME placeholders found"
}

# -----------------------------------------------------------------------------
# Terraform Helpers
# -----------------------------------------------------------------------------
check_tfvars() {
  log_info "Checking terraform.tfvars..."
  local tfvars="${CLUSTER_DIR}/terraform.tfvars"
  [[ -f "$tfvars" ]] || die "terraform.tfvars not found at ${tfvars}"

  # Check for required variables that have no defaults
  local required_vars=(rancher_url rancher_token harvester_kubeconfig_path
    harvester_cluster_id vm_namespace harvester_network_name
    harvester_network_namespace harvester_cloud_credential_name
    harvester_cloud_provider_kubeconfig_path cluster_name domain
    keycloak_realm ssh_authorized_keys)

  for var in "${required_vars[@]}"; do
    if ! grep -q "^${var}\s*=" "$tfvars"; then
      die "Required variable '${var}' not set in terraform.tfvars"
    fi
  done

  # Check for example/placeholder values
  if grep -q "example\.com\|xxxxx\|AAAA\.\.\." "$tfvars"; then
    die "terraform.tfvars contains example/placeholder values. Update before deploying."
  fi
  log_ok "terraform.tfvars looks valid"
}

ensure_harvester_kubeconfig() {
  local harvester_kc="${CLUSTER_DIR}/kubeconfig-harvester.yaml"

  # If file exists, validate it can reach the cluster
  if [[ -f "$harvester_kc" ]]; then
    if kubectl --kubeconfig="$harvester_kc" get nodes --no-headers &>/dev/null 2>&1; then
      log_ok "Harvester kubeconfig is valid: ${harvester_kc}"
      return 0
    fi
    log_warn "Existing Harvester kubeconfig is stale, regenerating..."
    rm -f "$harvester_kc"
  fi

  # Method 1: Generate via Rancher API (preferred — creates fresh token)
  local rancher_url rancher_token harvester_cluster_id
  rancher_url=$(get_rancher_url)
  rancher_token=$(get_rancher_token)
  harvester_cluster_id=$(get_harvester_cluster_id)

  log_info "Generating Harvester kubeconfig via Rancher API..."
  local response
  response=$(curl -sk -X POST \
    "${rancher_url}/v3/clusters/${harvester_cluster_id}?action=generateKubeconfig" \
    -H "Authorization: Bearer ${rancher_token}" 2>/dev/null || echo "")

  local config
  config=$(echo "$response" | jq -r '.config // empty' 2>/dev/null || echo "")

  if [[ -n "$config" ]]; then
    echo "$config" > "$harvester_kc"
    chmod 600 "$harvester_kc"
    log_ok "Harvester kubeconfig generated via Rancher API"
    return 0
  fi

  # Method 2: Fallback to ~/.kube/config extraction
  log_warn "Rancher API generation failed, falling back to ~/.kube/config..."
  if ! kubectl config view --minify --context="${HARVESTER_CONTEXT}" --raw > "$harvester_kc" 2>/dev/null; then
    rm -f "$harvester_kc"
    die "Failed to get Harvester kubeconfig. Ensure either:\n  1. Rancher API token has access to Harvester cluster (ID: ${harvester_cluster_id})\n  2. Context '${HARVESTER_CONTEXT}' exists in ~/.kube/config"
  fi

  if [[ ! -s "$harvester_kc" ]]; then
    rm -f "$harvester_kc"
    die "Extracted Harvester kubeconfig is empty."
  fi

  chmod 600 "$harvester_kc"
  log_ok "Harvester kubeconfig extracted from ~/.kube/config"
}

ensure_cloud_credential_kubeconfig() {
  local cloud_cred_kc="${CLUSTER_DIR}/kubeconfig-harvester-cloud-cred.yaml"
  local harvester_kc="${CLUSTER_DIR}/kubeconfig-harvester.yaml"
  local harvester_kubectl="kubectl --kubeconfig=${harvester_kc}"
  local cluster_name
  cluster_name=$(get_cluster_name)
  local sa_name="${cluster_name}-cloud-cred"

  # The cloud credential kubeconfig goes through the Rancher proxy URL
  # (e.g. https://rancher.example.com/k8s/clusters/c-xxxxx), so it must use:
  #   - The Rancher CA (not the internal RKE2 CA from SA token secrets)
  #   - A Rancher token (not a raw K8s SA JWT which Rancher won't recognize)
  # Both of these come from the harvester kubeconfig, which already authenticates
  # through the Rancher proxy correctly.

  # Extract server, CA, and token from the harvester kubeconfig
  local server ca_data token
  server=$($harvester_kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null \
    || grep 'server:' "$harvester_kc" | head -1 | awk '{print $2}' | tr -d '"')
  ca_data=$($harvester_kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)
  token=$($harvester_kubectl config view --minify --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null || true)

  if [[ -z "$server" || -z "$token" ]]; then
    die "Failed to extract server/token from harvester kubeconfig: ${harvester_kc}"
  fi

  # Check if existing cloud cred kubeconfig matches the current harvester kubeconfig
  if [[ -f "$cloud_cred_kc" && -s "$cloud_cred_kc" ]]; then
    local existing_server existing_token
    existing_server=$(kubectl --kubeconfig="$cloud_cred_kc" config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
    existing_token=$(kubectl --kubeconfig="$cloud_cred_kc" config view --minify --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null || true)
    if [[ "$existing_server" == "$server" && "$existing_token" == "$token" ]]; then
      log_ok "Cloud credential kubeconfig already exists and is current: ${cloud_cred_kc}"
      return 0
    fi
    log_warn "Cloud credential kubeconfig is stale (server/token mismatch), regenerating..."
    rm -f "$cloud_cred_kc"
  fi

  log_info "Generating cloud credential kubeconfig from harvester kubeconfig..."
  cat > "$cloud_cred_kc" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: harvester
  cluster:
    certificate-authority-data: ${ca_data}
    server: ${server}
contexts:
- name: harvester
  context:
    cluster: harvester
    user: ${sa_name}
current-context: harvester
users:
- name: ${sa_name}
  user:
    token: ${token}
EOF
  chmod 600 "$cloud_cred_kc"
  log_ok "Cloud credential kubeconfig generated: ${cloud_cred_kc}"

  # Push to Harvester secrets for future use
  log_info "Storing cloud credential kubeconfig in Harvester secrets..."
  $harvester_kubectl create secret generic kubeconfig-harvester-cloud-cred \
    --from-file="kubeconfig-harvester-cloud-cred.yaml=${cloud_cred_kc}" \
    --namespace=terraform-state \
    --dry-run=client -o yaml | $harvester_kubectl apply -f - 2>/dev/null || \
    log_warn "Could not store cloud credential kubeconfig in Harvester secrets (non-fatal)"
}

ensure_cloud_provider_kubeconfig() {
  local cloud_provider_kc="${CLUSTER_DIR}/harvester-cloud-provider-kubeconfig"
  if [[ -f "$cloud_provider_kc" && -s "$cloud_provider_kc" ]]; then
    # Validate it has the right format
    if grep -q 'apiVersion' "$cloud_provider_kc"; then
      log_ok "Cloud provider kubeconfig already exists: ${cloud_provider_kc}"
      return 0
    fi
    log_warn "Existing cloud provider kubeconfig is invalid, regenerating..."
    rm -f "$cloud_provider_kc"
  fi

  local harvester_kc="${CLUSTER_DIR}/kubeconfig-harvester.yaml"
  local harvester_kubectl="kubectl --kubeconfig=${harvester_kc}"

  # Try pulling from Harvester secrets first
  log_info "Checking Harvester secrets for cloud provider kubeconfig..."
  if $harvester_kubectl get secret harvester-cloud-provider-kubeconfig \
    -n terraform-state &>/dev/null 2>&1; then
    $harvester_kubectl get secret harvester-cloud-provider-kubeconfig \
      -n terraform-state -o json \
      | jq -r '.data["harvester-cloud-provider-kubeconfig"]' \
      | base64 -d > "$cloud_provider_kc"
    if [[ -s "$cloud_provider_kc" ]]; then
      chmod 600 "$cloud_provider_kc"
      log_ok "Cloud provider kubeconfig pulled from Harvester secrets"
      return 0
    fi
    rm -f "$cloud_provider_kc"
  fi

  # Generate via Rancher API
  log_info "Generating cloud provider kubeconfig via Rancher API..."
  local rancher_url rancher_token harvester_cluster_id vm_namespace cluster_name
  rancher_url=$(get_rancher_url)
  rancher_token=$(get_rancher_token)
  harvester_cluster_id=$(get_harvester_cluster_id)
  vm_namespace=$(get_vm_namespace)
  cluster_name=$(get_cluster_name)

  local response
  response=$(curl -sk -X POST \
    "${rancher_url}/k8s/clusters/${harvester_cluster_id}/v1/harvester/kubeconfig" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${rancher_token}" \
    -d "{\"clusterRoleName\":\"harvesterhci.io:cloudprovider\",\"namespace\":\"${vm_namespace}\",\"serviceAccountName\":\"${cluster_name}\"}" 2>/dev/null)

  # Response is a JSON-escaped string — unescape it to raw YAML
  local config
  config=$(echo "$response" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()))" 2>/dev/null || echo "$response")

  if ! echo "$config" | grep -q 'apiVersion'; then
    die "Failed to generate cloud provider kubeconfig via Rancher API. Response: ${response}"
  fi

  echo "$config" > "$cloud_provider_kc"
  chmod 600 "$cloud_provider_kc"
  log_ok "Cloud provider kubeconfig generated via Rancher API"

  # Push to Harvester secrets for future use
  log_info "Storing cloud provider kubeconfig in Harvester secrets..."
  $harvester_kubectl create secret generic harvester-cloud-provider-kubeconfig \
    --from-file="harvester-cloud-provider-kubeconfig=${cloud_provider_kc}" \
    --namespace=terraform-state \
    --dry-run=client -o yaml | $harvester_kubectl apply -f - 2>/dev/null || \
    log_warn "Could not store cloud provider kubeconfig in Harvester secrets (non-fatal)"
}

ensure_harvester_vm_namespace() {
  local vm_ns
  vm_ns=$(get_vm_namespace)
  local harvester_kc="${CLUSTER_DIR}/kubeconfig-harvester.yaml"
  local harvester_kubectl="kubectl --kubeconfig=${harvester_kc}"

  if $harvester_kubectl get namespace "$vm_ns" &>/dev/null 2>&1; then
    log_ok "Harvester VM namespace '${vm_ns}' exists"
    return 0
  fi

  log_info "Creating Harvester VM namespace '${vm_ns}'..."
  $harvester_kubectl create namespace "$vm_ns"
  log_ok "Harvester VM namespace '${vm_ns}' created"
}

ensure_external_files() {
  log_info "Ensuring required external files..."
  ensure_harvester_kubeconfig
  ensure_harvester_vm_namespace
  ensure_cloud_credential_kubeconfig
  ensure_cloud_provider_kubeconfig
  log_ok "External files ready"
}

# -----------------------------------------------------------------------------
# Golden Image Auto-Build
# -----------------------------------------------------------------------------
# If use_golden_image = true in tfvars but the image doesn't exist on Harvester,
# prompt to build it via golden-image/build.sh, then update tfvars with the name.
ensure_golden_image() {
  local tfvars="${CLUSTER_DIR}/terraform.tfvars"

  # Check if golden image is enabled (boolean, not quoted)
  local use_golden
  use_golden=$(grep '^use_golden_image' "$tfvars" 2>/dev/null | grep -o 'true' || echo "false")
  if [[ "$use_golden" != "true" ]]; then
    return 0
  fi

  log_info "Golden image mode is enabled — checking image availability..."

  local vm_ns
  vm_ns=$(get_vm_namespace)

  # Read current golden_image_name from tfvars (quoted string)
  local image_name
  image_name=$(_get_tfvar golden_image_name)

  # If no name is set, generate today's default
  local default_prefix="rke2-rocky9-golden"
  local today_name="${default_prefix}-$(date +%Y%m%d)"
  if [[ -z "$image_name" ]]; then
    log_info "golden_image_name not set in tfvars — will use: ${today_name}"
    image_name="$today_name"
  fi

  # Query Harvester for the image
  local harvester_kc="${CLUSTER_DIR}/kubeconfig-harvester.yaml"
  if [[ ! -f "$harvester_kc" ]]; then
    log_warn "No Harvester kubeconfig — cannot verify golden image existence (will rely on Terraform)"
    return 0
  fi

  local hkctl="kubectl --kubeconfig=${harvester_kc}"
  if $hkctl get virtualmachineimages.harvesterhci.io "${image_name}" -n "${vm_ns}" &>/dev/null; then
    log_ok "Golden image '${image_name}' exists in namespace '${vm_ns}'"
    return 0
  fi

  # Image doesn't exist — prompt to build
  echo ""
  log_warn "Golden image '${image_name}' not found in Harvester namespace '${vm_ns}'"
  echo ""
  echo -e "  The golden image build takes ~5-10 minutes and creates a pre-baked"
  echo -e "  Rocky 9 VM image with all packages pre-installed."
  echo ""
  echo -en "  ${BOLD}Build golden image now? [y/N]${NC} "
  read -r answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    die "Cannot continue with use_golden_image=true when image does not exist.\n  Either build it manually: cd golden-image && ./build.sh build\n  Or set use_golden_image = false in ${tfvars}"
  fi

  # Run the golden image build
  log_step "Building golden image..."
  "${REPO_ROOT}/golden-image/build.sh" build

  # The build produces an image named ${prefix}-${YYYYMMDD}
  # Re-read what it actually created (always today's date)
  local built_name="${default_prefix}-$(date +%Y%m%d)"

  # Verify the image now exists
  if ! $hkctl get virtualmachineimages.harvesterhci.io "${built_name}" -n "${vm_ns}" &>/dev/null; then
    die "Golden image build completed but '${built_name}' not found in Harvester. Check build output above."
  fi
  log_ok "Golden image '${built_name}' verified in Harvester"

  # Update tfvars if the name changed (stale date or was empty)
  if [[ "$built_name" != "$image_name" ]]; then
    log_info "Updating golden_image_name in tfvars: ${image_name} -> ${built_name}"
    if grep -q '^golden_image_name' "$tfvars"; then
      sed -i "s|^golden_image_name.*|golden_image_name = \"${built_name}\"|" "$tfvars"
    else
      # Append after use_golden_image line
      sed -i "/^use_golden_image/a golden_image_name = \"${built_name}\"" "$tfvars"
    fi
    log_ok "terraform.tfvars updated with golden_image_name = \"${built_name}\""
  elif ! grep -q '^golden_image_name' "$tfvars"; then
    # Name matches but isn't in tfvars yet — add it
    sed -i "/^use_golden_image/a golden_image_name = \"${built_name}\"" "$tfvars"
    log_ok "Added golden_image_name = \"${built_name}\" to terraform.tfvars"
  fi
}

# Extract a quoted tfvars value by variable name (BSD/GNU awk compatible)
_get_tfvar() {
  awk -F'"' "/^${1}[[:space:]]/ {print \$2}" "${CLUSTER_DIR}/terraform.tfvars"
}

get_cluster_name()        { _get_tfvar cluster_name; }
get_rancher_url()         { _get_tfvar rancher_url; }
get_rancher_token()       { _get_tfvar rancher_token; }
get_harvester_cluster_id(){ _get_tfvar harvester_cluster_id; }
get_vm_namespace()        { _get_tfvar vm_namespace; }

# -----------------------------------------------------------------------------
# Kubernetes Wait Helpers
# -----------------------------------------------------------------------------

# Wait for a deployment to be available
wait_for_deployment() {
  local namespace="$1"
  local name="$2"
  local timeout="${3:-300s}"
  log_info "Waiting for deployment/${name} in ${namespace} (timeout: ${timeout})..."
  kubectl -n "$namespace" wait --for=condition=available \
    "deployment/${name}" --timeout="$timeout" 2>/dev/null || {
    log_error "Deployment ${name} in ${namespace} did not become available"
    kubectl -n "$namespace" get pods -l "app.kubernetes.io/name=${name}" 2>/dev/null || true
    return 1
  }
  log_ok "deployment/${name} is available"
}

# Wait for pods matching a label to be Ready
wait_for_pods_ready() {
  local namespace="$1"
  local label="$2"
  local timeout="${3:-300}"
  local interval=5
  local elapsed=0

  log_info "Waiting for pods (${label}) in ${namespace} to be Ready (timeout: ${timeout}s)..."
  while [[ $elapsed -lt $timeout ]]; do
    local total ready
    total=$(kubectl -n "$namespace" get pods -l "$label" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ready=$(kubectl -n "$namespace" get pods -l "$label" --no-headers 2>/dev/null | grep -c "Running" || true)

    if [[ "$total" -gt 0 && "$total" -eq "$ready" ]]; then
      log_ok "All ${total} pod(s) with label ${label} are Running"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_error "Timeout waiting for pods (${label}) in ${namespace}"
  kubectl -n "$namespace" get pods -l "$label" 2>/dev/null || true
  return 1
}

# Wait for pods to exist (even if not Ready — used for sealed Vault)
wait_for_pods_running() {
  local namespace="$1"
  local count="$2"
  local timeout="${3:-300}"
  local interval=5
  local elapsed=0

  log_info "Waiting for ${count} pod(s) in ${namespace} to be Running..."
  while [[ $elapsed -lt $timeout ]]; do
    local running
    running=$(kubectl -n "$namespace" get pods --no-headers 2>/dev/null | grep -c "Running" || true)
    if [[ "$running" -ge "$count" ]]; then
      log_ok "${running} pod(s) Running in ${namespace}"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_error "Timeout: only ${running:-0}/${count} pods Running in ${namespace}"
  kubectl -n "$namespace" get pods 2>/dev/null || true
  return 1
}

# Wait for a ClusterIssuer to be Ready
wait_for_clusterissuer() {
  local name="$1"
  local timeout="${2:-120}"
  local interval=5
  local elapsed=0

  log_info "Waiting for ClusterIssuer/${name} to be Ready..."
  while [[ $elapsed -lt $timeout ]]; do
    local ready
    ready=$(kubectl get clusterissuer "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$ready" == "True" ]]; then
      log_ok "ClusterIssuer/${name} is Ready"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_error "ClusterIssuer/${name} did not become Ready"
  kubectl get clusterissuer "$name" -o yaml 2>/dev/null | tail -20
  return 1
}

# Wait for CNPG cluster primary to be Ready
wait_for_cnpg_primary() {
  local namespace="$1"
  local cluster_name="$2"
  local timeout="${3:-300}"
  local interval=10
  local elapsed=0

  log_info "Waiting for CNPG cluster ${cluster_name} primary in ${namespace}..."
  while [[ $elapsed -lt $timeout ]]; do
    local phase
    phase=$(kubectl -n "$namespace" get cluster "$cluster_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$phase" == "Cluster in healthy state" ]]; then
      log_ok "CNPG cluster ${cluster_name} is healthy"
      return 0
    fi
    # Also check if primary pod is Ready
    local primary_ready
    primary_ready=$(kubectl -n "$namespace" get pods \
      -l "cnpg.io/cluster=${cluster_name},cnpg.io/instanceRole=primary" \
      --no-headers 2>/dev/null | grep -c "Running" || true)
    if [[ "$primary_ready" -ge 1 ]]; then
      log_ok "CNPG cluster ${cluster_name} primary is Running (phase: ${phase})"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_error "CNPG cluster ${cluster_name} primary not ready"
  kubectl -n "$namespace" get cluster "$cluster_name" 2>/dev/null || true
  kubectl -n "$namespace" get pods -l "cnpg.io/cluster=${cluster_name}" 2>/dev/null || true
  return 1
}

# Wait for a Helm release to be deployed
wait_for_helm_release() {
  local namespace="$1"
  local release="$2"
  local timeout="${3:-120}"
  local interval=5
  local elapsed=0

  log_info "Waiting for Helm release ${release} in ${namespace}..."
  while [[ $elapsed -lt $timeout ]]; do
    local status
    status=$(helm status "$release" -n "$namespace" -o json 2>/dev/null | jq -r '.info.status' || echo "")
    if [[ "$status" == "deployed" ]]; then
      log_ok "Helm release ${release} is deployed"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_error "Helm release ${release} did not reach 'deployed' status"
  return 1
}

# Wait for TLS secret to be created by cert-manager
wait_for_tls_secret() {
  local namespace="$1"
  local secret_name="$2"
  local timeout="${3:-120}"
  local interval=5
  local elapsed=0

  log_info "Waiting for TLS secret ${secret_name} in ${namespace}..."
  while [[ $elapsed -lt $timeout ]]; do
    if kubectl -n "$namespace" get secret "$secret_name" &>/dev/null; then
      log_ok "TLS secret ${secret_name} exists"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_warn "TLS secret ${secret_name} not found after ${timeout}s (cert-manager may still be issuing)"
  return 0  # Non-fatal — cert may take time
}

# -----------------------------------------------------------------------------
# Node Labeling (autoscaler-created nodes miss workload-type labels)
# -----------------------------------------------------------------------------
# Label unlabeled worker nodes based on hostname pattern (general/compute/database)
# Rancher cluster-autoscaler creates nodes without custom labels from machine pool config
label_unlabeled_nodes() {
  local nodes node pool_type
  nodes=$(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null) || return 0
  for node in $nodes; do
    # Determine pool type from node hostname pattern: rke2-prod-{general|compute|database}-xxxxx-xxxxx
    pool_type=""
    case "$node" in
      *-general-*)  pool_type="general" ;;
      *-compute-*)  pool_type="compute" ;;
      *-database-*) pool_type="database" ;;
      *) continue ;;  # CP nodes or unknown — skip
    esac

    # Apply workload-type label (idempotent — safety net for autoscaler-created nodes)
    kubectl label node "$node" "workload-type=${pool_type}" --overwrite 2>/dev/null || true
    # Apply node-role label (NodeRestriction prevents kubelet from setting these via --node-labels)
    kubectl label node "$node" "node-role.kubernetes.io/${pool_type}=" --overwrite 2>/dev/null || true
  done
}

# -----------------------------------------------------------------------------
# Helm Helpers
# -----------------------------------------------------------------------------
helm_repo_add() {
  local name="$1"
  local url="$2"
  # In airgapped mode, skip repo add (charts come from OCI overrides)
  if [[ "${AIRGAPPED:-false}" == "true" ]]; then
    log_info "Airgapped: skipping helm repo add '${name}'"
    return 0
  fi
  if helm repo list 2>/dev/null | grep -q "^${name}"; then
    log_info "Helm repo '${name}' already exists, updating..."
  else
    log_info "Adding Helm repo '${name}' → ${url}"
    helm repo add "$name" "$url"
  fi
}

# Resolve a Helm chart reference: returns OCI URL in airgapped mode, online chart ref otherwise
# Usage: chart=$(resolve_helm_chart "jetstack/cert-manager" "HELM_OCI_CERT_MANAGER")
resolve_helm_chart() {
  local online_chart="$1" oci_var_name="$2"
  if [[ "${AIRGAPPED:-false}" == "true" ]]; then
    local oci_url="${!oci_var_name:-}"
    [[ -z "$oci_url" ]] && die "Airgapped: ${oci_var_name} not set for ${online_chart}"
    echo "$oci_url"
  else
    echo "$online_chart"
  fi
}

helm_install_if_needed() {
  local release="$1"
  local chart="$2"
  local namespace="$3"
  shift 3
  # remaining args are passed to helm install

  if helm status "$release" -n "$namespace" &>/dev/null; then
    log_info "Helm release '${release}' already exists in ${namespace}, upgrading..."
    helm upgrade "$release" "$chart" -n "$namespace" "$@"
  else
    log_info "Installing Helm release '${release}' from ${chart} into ${namespace}..."
    helm install "$release" "$chart" -n "$namespace" --create-namespace "$@"
  fi
}

# -----------------------------------------------------------------------------
# Rancher API Helpers
# -----------------------------------------------------------------------------

# Get cluster ID from Rancher by name
get_rancher_cluster_id() {
  local cluster_name="$1"
  local rancher_url
  local rancher_token
  rancher_url=$(get_rancher_url)
  rancher_token=$(get_rancher_token)

  curl -sk "${rancher_url}/v1/provisioning.cattle.io.clusters" \
    -H "Authorization: Bearer ${rancher_token}" | \
    jq -r ".data[] | select(.metadata.name==\"${cluster_name}\") | .status.clusterName"
}

# Wait for cluster to be Active in Rancher
wait_for_cluster_active() {
  local cluster_name="$1"
  local timeout="${2:-1800}"
  local interval=30
  local elapsed=0
  local rancher_url
  local rancher_token
  rancher_url=$(get_rancher_url)
  rancher_token=$(get_rancher_token)

  log_info "Waiting for cluster '${cluster_name}' to become Active in Rancher (timeout: ${timeout}s)..."
  while [[ $elapsed -lt $timeout ]]; do
    local state
    state=$(curl -sk "${rancher_url}/v1/provisioning.cattle.io.clusters" \
      -H "Authorization: Bearer ${rancher_token}" | \
      jq -r ".data[] | select(.metadata.name==\"${cluster_name}\") | .status.ready" 2>/dev/null || echo "false")

    if [[ "$state" == "true" ]]; then
      log_ok "Cluster '${cluster_name}' is Active"
      return 0
    fi
    log_info "  Cluster status: not ready yet (${elapsed}s elapsed)..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  die "Cluster '${cluster_name}' did not become Active within ${timeout}s"
}

# Generate kubeconfig via Rancher API
generate_kubeconfig() {
  local cluster_name="$1"
  local output_path="$2"
  local rancher_url
  local rancher_token
  rancher_url=$(get_rancher_url)
  rancher_token=$(get_rancher_token)

  log_info "Generating kubeconfig for cluster '${cluster_name}'..."

  # Get the v3 cluster ID (c-xxxxx format)
  local cluster_id
  cluster_id=$(get_rancher_cluster_id "$cluster_name")
  [[ -n "$cluster_id" ]] || die "Could not find cluster ID for '${cluster_name}'"

  curl -sk -X POST \
    "${rancher_url}/v3/clusters/${cluster_id}?action=generateKubeconfig" \
    -H "Authorization: Bearer ${rancher_token}" | \
    jq -r '.config' > "$output_path"

  [[ -s "$output_path" ]] || die "Generated kubeconfig is empty"
  log_ok "Kubeconfig saved to ${output_path}"
}

# -----------------------------------------------------------------------------
# Vault Helpers
# -----------------------------------------------------------------------------

# Initialize Vault and capture keys
vault_init() {
  local output_file="$1"
  log_info "Initializing Vault (5 shares, threshold 3)..."
  kubectl exec -n vault vault-0 -- \
    vault operator init -key-shares=5 -key-threshold=3 -format=json > "$output_file"

  # Validate output — Vault 1.19+ uses unseal_keys_hex, older used keys
  local key_count
  key_count=$(jq '(.unseal_keys_hex // .keys) | length' "$output_file")
  [[ "$key_count" -eq 5 ]] || die "Expected 5 unseal keys, got ${key_count}"
  log_ok "Vault initialized — ${key_count} unseal keys captured"
}

# Unseal a single Vault replica
vault_unseal_replica() {
  local replica="$1"
  local init_file="$2"

  log_info "Unsealing vault-${replica}..."
  for k in 0 1 2; do
    local key
    key=$(jq -r "(.unseal_keys_hex // .keys)[${k}]" "$init_file")
    kubectl exec -n vault "vault-${replica}" -- vault operator unseal "$key" >/dev/null
  done
}

# Unseal all Vault replicas
vault_unseal_all() {
  local init_file="$1"
  for i in 0 1 2; do
    vault_unseal_replica "$i" "$init_file"
  done
  log_ok "All 3 Vault replicas unsealed"
}

# Execute a vault command on vault-0
vault_exec() {
  local root_token="$1"
  shift
  kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 \
    VAULT_TOKEN="$root_token" \
    vault "$@"
}

# Execute a vault command that needs stdin (for policies)
vault_exec_stdin() {
  local root_token="$1"
  shift
  kubectl exec -i -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 \
    VAULT_TOKEN="$root_token" \
    vault "$@"
}

# -----------------------------------------------------------------------------
# Idempotent kubectl apply
# -----------------------------------------------------------------------------
kube_apply() {
  log_info "Applying: $*"
  kubectl apply "$@"
}

kube_apply_k() {
  local dir="$1"
  log_info "Applying kustomization: ${dir#${REPO_ROOT}/}"
  kubectl apply -k "$dir"
}

# -----------------------------------------------------------------------------
# Namespace creation (idempotent)
# -----------------------------------------------------------------------------
ensure_namespace() {
  local ns="$1"
  if kubectl get namespace "$ns" &>/dev/null; then
    log_info "Namespace '${ns}' already exists"
  else
    log_info "Creating namespace '${ns}'"
    kubectl create namespace "$ns"
  fi
}

# -----------------------------------------------------------------------------
# Credential Management (.env)
# -----------------------------------------------------------------------------
ENV_FILE="${SCRIPTS_DIR}/.env"

# Generate a random alphanumeric password
gen_password() {
  local len="${1:-32}"
  openssl rand -base64 "$len" | tr -d '/+=' | head -c "$len"
}

# Generate or load all credentials from .env
generate_or_load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    log_info "Loading credentials from ${ENV_FILE}"
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  else
    log_info "No .env found — generating fresh credentials..."
  fi

  # Feature flags
  : "${DEPLOY_UPTIME_KUMA:=true}"
  : "${DEPLOY_LIBRENMS:=false}"

  # Airgapped mode
  : "${AIRGAPPED:=false}"
  : "${UPSTREAM_PROXY_REGISTRY:=}"
  : "${BOOTSTRAP_REGISTRY:=}"
  : "${BOOTSTRAP_REGISTRY_CA_PEM:=}"
  : "${BOOTSTRAP_REGISTRY_USERNAME:=}"
  : "${BOOTSTRAP_REGISTRY_PASSWORD:=}"

  # Git base URL for ArgoCD service repos (airgapped: internal Gitea/GitLab)
  : "${GIT_BASE_URL:=}"
  # Argo Rollouts Gateway API plugin URL
  : "${ARGO_ROLLOUTS_PLUGIN_URL:=https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.5.0/gateway-api-plugin-linux-amd64}"

  # Binary/CRD download URL overrides (point to self-hosted GitLab/mirror for airgapped)
  : "${BINARY_URL_ARGOCD_CLI:=https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64}"
  : "${BINARY_URL_KUSTOMIZE:=https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v5.6.0/kustomize_v5.6.0_linux_amd64.tar.gz}"
  : "${BINARY_URL_KUBECONFORM:=https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz}"
  : "${CRD_SCHEMA_BASE_URL:=https://raw.githubusercontent.com/datreeio/CRDs-catalog/main}"
  : "${GATEWAY_API_CRD_URL:=https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml}"

  # Per-chart OCI URL overrides (required when AIRGAPPED=true)
  : "${HELM_OCI_CERT_MANAGER:=}"
  : "${HELM_OCI_CNPG:=}"
  : "${HELM_OCI_CLUSTER_AUTOSCALER:=}"
  : "${HELM_OCI_REDIS_OPERATOR:=}"
  : "${HELM_OCI_MARIADB_OPERATOR:=}"
  : "${HELM_OCI_VAULT:=}"
  : "${HELM_OCI_HARBOR:=}"
  : "${HELM_OCI_ARGOCD:=}"
  : "${HELM_OCI_ARGO_ROLLOUTS:=}"
  : "${HELM_OCI_KASM:=}"
  : "${HELM_OCI_KPS:=}"
  : "${HELM_OCI_GITLAB_RUNNER:=}"
  # kube-prometheus-stack chart version
  : "${KPS_CHART_VERSION:=72.6.2}"

  # CI dependency proxy URLs (used by airgapped CI templates)
  : "${CI_GOPROXY:=}"
  : "${CI_GONOSUMDB:=}"
  : "${CI_NPM_REGISTRY:=}"
  : "${CI_PIP_INDEX_URL:=}"
  : "${CI_PIP_TRUSTED_HOST:=}"

  # Generate any missing values
  : "${KEYCLOAK_BOOTSTRAP_CLIENT_SECRET:=$(gen_password 32)}"
  : "${KEYCLOAK_DB_PASSWORD:=$(gen_password 32)}"
  : "${MATTERMOST_DB_PASSWORD:=$(gen_password 32)}"
  : "${MATTERMOST_MINIO_ROOT_USER:=mattermost-minio-admin}"
  : "${MATTERMOST_MINIO_ROOT_PASSWORD:=$(gen_password 32)}"
  : "${HARBOR_REDIS_PASSWORD:=$(gen_password 32)}"
  : "${HARBOR_ADMIN_PASSWORD:=$(gen_password 32)}"
  : "${HARBOR_MINIO_SECRET_KEY:=$(gen_password 32)}"
  : "${HARBOR_DB_PASSWORD:=$(gen_password 32)}"
  : "${KASM_PG_SUPERUSER_PASSWORD:=$(gen_password 32)}"
  : "${KASM_PG_APP_PASSWORD:=$(gen_password 30)}"
  : "${KC_ADMIN_PASSWORD:=$(gen_password 24)}"
  : "${GRAFANA_ADMIN_PASSWORD:=$(gen_password 24)}"

  # LibreNMS credentials (generate even if disabled — no harm, available if enabled later)
  : "${LIBRENMS_DB_PASSWORD:=$(gen_password 32)}"
  : "${LIBRENMS_VALKEY_PASSWORD:=$(gen_password 32)}"

  # GitLab credentials
  : "${GITLAB_ROOT_PASSWORD:=$(gen_password 32)}"
  : "${GITLAB_PRAEFECT_DB_PASSWORD:=$(gen_password 32)}"
  : "${GITLAB_REDIS_PASSWORD:=$(gen_password 32)}"
  : "${GITLAB_GITALY_TOKEN:=$(gen_password 32)}"
  : "${GITLAB_PRAEFECT_TOKEN:=$(gen_password 32)}"
  : "${GITLAB_CHART_PATH:=/home/rocky/data/gitlab}"

  # GitLab API token (api scope) — leave empty to be prompted at runtime
  : "${GITLAB_API_TOKEN:=}"

  # GitLab Runner tokens (populated at runtime by setup-gitlab-services.sh Phase 8)
  : "${GITLAB_RUNNER_SHARED_TOKEN:=}"
  : "${GITLAB_RUNNER_GROUP_TOKEN:=}"

  # Identity Portal OIDC client secret
  : "${IDENTITY_PORTAL_OIDC_SECRET:=$(gen_password 32)}"

  # oauth2-proxy Redis session store password
  : "${OAUTH2_PROXY_REDIS_PASSWORD:=$(gen_password 32)}"

  # DEPRECATED: basic-auth replaced by oauth2-proxy ForwardAuth
  # Kept for rollback compatibility
  : "${BASIC_AUTH_PASSWORD:=$(gen_password 24)}"

  # Generate htpasswd hash if not already set
  if [[ -z "${BASIC_AUTH_HTPASSWD:-}" ]]; then
    require_cmd htpasswd
    BASIC_AUTH_HTPASSWD=$(htpasswd -nbB admin "$BASIC_AUTH_PASSWORD")
  fi

  # Traefik LB IP (from terraform.tfvars or default)
  : "${TRAEFIK_LB_IP:=$(_get_tfvar traefik_lb_ip 2>/dev/null || echo "198.51.100.2")}"

  # Domain configuration (used by scripts and manifest substitution)
  : "${DOMAIN:=example.com}"

  # Warn if DOMAIN is still the default
  if [[ "${DOMAIN}" == "example.com" ]]; then
    log_warn "DOMAIN is 'example.com' (default). Set DOMAIN in .env if this is not your domain."
    log_warn "All FQDNs, PKI certs, and Keycloak realm will use this domain."
  fi

  DOMAIN_DASHED=$(echo "$DOMAIN" | tr '.' '-')
  DOMAIN_DOT=$(echo "$DOMAIN" | sed 's/\./-dot-/g')

  # Rancher FQDN — used for Kubernetes API server URL in kubeconfig generation
  : "${RANCHER_FQDN:=rancher.${DOMAIN}}"

  # Organization name — derive from domain if not set
  # "example.com" → "Example Org", "tiger.net" → "Tiger"
  if [[ -z "${ORG_NAME:-}" ]]; then
    local _domain_base="${DOMAIN%%.*}"
    ORG_NAME=$(echo "$_domain_base" | sed -E 's/([a-z])([A-Z])/\1 \2/g; s/[-_]/ /g' \
      | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
  fi

  : "${KC_REALM:=${DOMAIN%%.*}}"
  : "${GIT_REPO_URL:=$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || echo "git@github.com:OWNER/rke2-cluster.git")}"

  # Derive GIT_BASE_URL from GIT_REPO_URL if not set (strip "/reponame.git")
  if [[ -z "${GIT_BASE_URL:-}" && -n "${GIT_REPO_URL:-}" ]]; then
    GIT_BASE_URL="${GIT_REPO_URL%/*}"
  fi

  # Harvester context name in ~/.kube/config (for auto-extracting kubeconfig)
  : "${HARVESTER_CONTEXT:=harvester}"

  # Cloud-init override (optional — paths to custom cloud-init YAML files)
  : "${USER_DATA_CP_FILE:=}"
  : "${USER_DATA_WORKER_FILE:=}"

  # Export for subshells
  export DEPLOY_UPTIME_KUMA DEPLOY_LIBRENMS
  export AIRGAPPED UPSTREAM_PROXY_REGISTRY BOOTSTRAP_REGISTRY
  export BOOTSTRAP_REGISTRY_CA_PEM BOOTSTRAP_REGISTRY_USERNAME BOOTSTRAP_REGISTRY_PASSWORD
  export KEYCLOAK_BOOTSTRAP_CLIENT_SECRET KEYCLOAK_DB_PASSWORD
  export MATTERMOST_DB_PASSWORD MATTERMOST_MINIO_ROOT_USER MATTERMOST_MINIO_ROOT_PASSWORD
  export HARBOR_REDIS_PASSWORD HARBOR_ADMIN_PASSWORD HARBOR_MINIO_SECRET_KEY HARBOR_DB_PASSWORD
  export KASM_PG_SUPERUSER_PASSWORD KASM_PG_APP_PASSWORD KC_ADMIN_PASSWORD
  export LIBRENMS_DB_PASSWORD LIBRENMS_VALKEY_PASSWORD
  export GITLAB_ROOT_PASSWORD GITLAB_PRAEFECT_DB_PASSWORD GITLAB_REDIS_PASSWORD
  export GITLAB_GITALY_TOKEN GITLAB_PRAEFECT_TOKEN GITLAB_CHART_PATH
  export GITLAB_API_TOKEN
  export GITLAB_RUNNER_SHARED_TOKEN GITLAB_RUNNER_GROUP_TOKEN
  export IDENTITY_PORTAL_OIDC_SECRET
  export OAUTH2_PROXY_REDIS_PASSWORD
  export GRAFANA_ADMIN_PASSWORD BASIC_AUTH_PASSWORD BASIC_AUTH_HTPASSWD
  export DOMAIN DOMAIN_DASHED DOMAIN_DOT TRAEFIK_LB_IP RANCHER_FQDN
  export ORG_NAME KC_REALM GIT_REPO_URL
  export HARVESTER_CONTEXT
  export USER_DATA_CP_FILE USER_DATA_WORKER_FILE
  export GIT_BASE_URL ARGO_ROLLOUTS_PLUGIN_URL
  export BINARY_URL_ARGOCD_CLI BINARY_URL_KUSTOMIZE BINARY_URL_KUBECONFORM
  export CRD_SCHEMA_BASE_URL GATEWAY_API_CRD_URL
  export HELM_OCI_CERT_MANAGER HELM_OCI_CNPG HELM_OCI_CLUSTER_AUTOSCALER
  export HELM_OCI_REDIS_OPERATOR HELM_OCI_MARIADB_OPERATOR HELM_OCI_VAULT
  export HELM_OCI_HARBOR HELM_OCI_ARGOCD HELM_OCI_ARGO_ROLLOUTS HELM_OCI_KASM
  export HELM_OCI_KPS KPS_CHART_VERSION
  export HELM_OCI_GITLAB_RUNNER
  export CI_GOPROXY CI_GONOSUMDB CI_NPM_REGISTRY CI_PIP_INDEX_URL CI_PIP_TRUSTED_HOST

  # Bridge cloud-init overrides to Terraform via TF_VAR_ env vars
  [[ -n "$USER_DATA_CP_FILE" ]] && export TF_VAR_user_data_cp_file="$USER_DATA_CP_FILE"
  [[ -n "$USER_DATA_WORKER_FILE" ]] && export TF_VAR_user_data_worker_file="$USER_DATA_WORKER_FILE"

  # Bridge airgapped vars to Terraform
  if [[ "${AIRGAPPED}" == "true" ]]; then
    export TF_VAR_airgapped=true
    [[ -n "${BOOTSTRAP_REGISTRY:-}" ]]         && export TF_VAR_bootstrap_registry="$BOOTSTRAP_REGISTRY"
    [[ -n "${BOOTSTRAP_REGISTRY_CA_PEM:-}" ]]  && export TF_VAR_bootstrap_registry_ca_pem="$BOOTSTRAP_REGISTRY_CA_PEM"
    [[ -n "${BOOTSTRAP_REGISTRY_USERNAME:-}" ]] && export TF_VAR_bootstrap_registry_username="$BOOTSTRAP_REGISTRY_USERNAME"
    [[ -n "${BOOTSTRAP_REGISTRY_PASSWORD:-}" ]] && export TF_VAR_bootstrap_registry_password="$BOOTSTRAP_REGISTRY_PASSWORD"
    [[ -n "${PRIVATE_ROCKY_REPO_URL:-}" ]]     && export TF_VAR_private_rocky_repo_url="$PRIVATE_ROCKY_REPO_URL"
    [[ -n "${PRIVATE_RKE2_REPO_URL:-}" ]]      && export TF_VAR_private_rke2_repo_url="$PRIVATE_RKE2_REPO_URL"
  fi

  # Save to .env (only if newly generated or updated)
  cat > "$ENV_FILE" <<ENVEOF
# Auto-generated credentials for RKE2 cluster deployment
# Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# WARNING: Contains secrets — do NOT commit to git

# Feature flags
DEPLOY_UPTIME_KUMA="${DEPLOY_UPTIME_KUMA}"
DEPLOY_LIBRENMS="${DEPLOY_LIBRENMS}"

# Airgapped mode — when true, Harbor proxy-cache uses UPSTREAM_PROXY_REGISTRY
AIRGAPPED="${AIRGAPPED}"
UPSTREAM_PROXY_REGISTRY="${UPSTREAM_PROXY_REGISTRY}"

# Bootstrap registry — pre-existing external registry for Phases 0-3 (required when AIRGAPPED=true)
BOOTSTRAP_REGISTRY="${BOOTSTRAP_REGISTRY}"
BOOTSTRAP_REGISTRY_CA_PEM="${BOOTSTRAP_REGISTRY_CA_PEM}"
BOOTSTRAP_REGISTRY_USERNAME="${BOOTSTRAP_REGISTRY_USERNAME}"
BOOTSTRAP_REGISTRY_PASSWORD="${BOOTSTRAP_REGISTRY_PASSWORD}"

# Git base URL for ArgoCD service repos (airgapped: internal Gitea/GitLab)
GIT_BASE_URL="${GIT_BASE_URL}"

# Argo Rollouts Gateway API plugin URL
ARGO_ROLLOUTS_PLUGIN_URL="${ARGO_ROLLOUTS_PLUGIN_URL}"

# Binary/CRD download URL overrides (point to self-hosted GitLab/mirror for airgapped)
# Example: BINARY_URL_ARGOCD_CLI="https://gitlab.example.com/infra/binaries/-/raw/main/argocd-linux-amd64"
BINARY_URL_ARGOCD_CLI="${BINARY_URL_ARGOCD_CLI}"
BINARY_URL_KUSTOMIZE="${BINARY_URL_KUSTOMIZE}"
BINARY_URL_KUBECONFORM="${BINARY_URL_KUBECONFORM}"
CRD_SCHEMA_BASE_URL="${CRD_SCHEMA_BASE_URL}"
GATEWAY_API_CRD_URL="${GATEWAY_API_CRD_URL}"

# Per-chart OCI URL overrides (required when AIRGAPPED=true)
HELM_OCI_CERT_MANAGER="${HELM_OCI_CERT_MANAGER}"
HELM_OCI_CNPG="${HELM_OCI_CNPG}"
HELM_OCI_CLUSTER_AUTOSCALER="${HELM_OCI_CLUSTER_AUTOSCALER}"
HELM_OCI_REDIS_OPERATOR="${HELM_OCI_REDIS_OPERATOR}"
HELM_OCI_MARIADB_OPERATOR="${HELM_OCI_MARIADB_OPERATOR}"
HELM_OCI_VAULT="${HELM_OCI_VAULT}"
HELM_OCI_HARBOR="${HELM_OCI_HARBOR}"
HELM_OCI_ARGOCD="${HELM_OCI_ARGOCD}"
HELM_OCI_ARGO_ROLLOUTS="${HELM_OCI_ARGO_ROLLOUTS}"
HELM_OCI_KASM="${HELM_OCI_KASM}"
HELM_OCI_KPS="${HELM_OCI_KPS}"
KPS_CHART_VERSION="${KPS_CHART_VERSION}"

KEYCLOAK_BOOTSTRAP_CLIENT_SECRET="${KEYCLOAK_BOOTSTRAP_CLIENT_SECRET}"
KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD}"
MATTERMOST_DB_PASSWORD="${MATTERMOST_DB_PASSWORD}"
MATTERMOST_MINIO_ROOT_USER="${MATTERMOST_MINIO_ROOT_USER}"
MATTERMOST_MINIO_ROOT_PASSWORD="${MATTERMOST_MINIO_ROOT_PASSWORD}"
HARBOR_REDIS_PASSWORD="${HARBOR_REDIS_PASSWORD}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD}"
HARBOR_MINIO_SECRET_KEY="${HARBOR_MINIO_SECRET_KEY}"
HARBOR_DB_PASSWORD="${HARBOR_DB_PASSWORD}"
KASM_PG_SUPERUSER_PASSWORD="${KASM_PG_SUPERUSER_PASSWORD}"
KASM_PG_APP_PASSWORD="${KASM_PG_APP_PASSWORD}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD}"
BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD}"
BASIC_AUTH_HTPASSWD='${BASIC_AUTH_HTPASSWD}'

# Identity Portal OIDC client secret
IDENTITY_PORTAL_OIDC_SECRET="${IDENTITY_PORTAL_OIDC_SECRET}"

# oauth2-proxy Redis session store
OAUTH2_PROXY_REDIS_PASSWORD="${OAUTH2_PROXY_REDIS_PASSWORD}"

# LibreNMS credentials (only used if DEPLOY_LIBRENMS=true)
LIBRENMS_DB_PASSWORD="${LIBRENMS_DB_PASSWORD}"
LIBRENMS_VALKEY_PASSWORD="${LIBRENMS_VALKEY_PASSWORD}"

# GitLab credentials
GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD}"
GITLAB_PRAEFECT_DB_PASSWORD="${GITLAB_PRAEFECT_DB_PASSWORD}"
GITLAB_REDIS_PASSWORD="${GITLAB_REDIS_PASSWORD}"
GITLAB_GITALY_TOKEN="${GITLAB_GITALY_TOKEN}"
GITLAB_PRAEFECT_TOKEN="${GITLAB_PRAEFECT_TOKEN}"
GITLAB_CHART_PATH="${GITLAB_CHART_PATH}"

# GitLab API token (api scope) — leave empty to be prompted at runtime
GITLAB_API_TOKEN="${GITLAB_API_TOKEN}"

# GitLab Runner tokens (populated at runtime by setup-gitlab-services.sh Phase 8)
GITLAB_RUNNER_SHARED_TOKEN="${GITLAB_RUNNER_SHARED_TOKEN}"
GITLAB_RUNNER_GROUP_TOKEN="${GITLAB_RUNNER_GROUP_TOKEN}"

# GitLab Runner Helm chart OCI override (airgapped)
HELM_OCI_GITLAB_RUNNER="${HELM_OCI_GITLAB_RUNNER}"

# CI dependency proxy URLs (airgapped mode)
# Go module proxy (e.g., https://athens.DOMAIN, or "off" for vendor-only)
CI_GOPROXY="${CI_GOPROXY}"
CI_GONOSUMDB="${CI_GONOSUMDB}"
# npm registry URL (e.g., https://nexus.DOMAIN/repository/npm-group/)
CI_NPM_REGISTRY="${CI_NPM_REGISTRY}"
# PyPI index URL (e.g., https://nexus.DOMAIN/repository/pypi-group/simple/)
CI_PIP_INDEX_URL="${CI_PIP_INDEX_URL}"
CI_PIP_TRUSTED_HOST="${CI_PIP_TRUSTED_HOST}"

# Root domain for all service FQDNs (e.g., vault.DOMAIN, harbor.DOMAIN)
DOMAIN="${DOMAIN}"

# Organization name for PKI CA Common Names
ORG_NAME="${ORG_NAME}"

# Keycloak realm name
KC_REALM="${KC_REALM}"

# Git repo URL for ArgoCD bootstrap (derived from git remote)
GIT_REPO_URL="${GIT_REPO_URL}"

# Harvester context name in ~/.kube/config (for auto-extracting kubeconfig)
HARVESTER_CONTEXT="${HARVESTER_CONTEXT}"

# Cloud-init override files (leave empty to use built-in templates)
# Paths are relative to repo root or absolute
USER_DATA_CP_FILE="${USER_DATA_CP_FILE}"
USER_DATA_WORKER_FILE="${USER_DATA_WORKER_FILE}"
ENVEOF
  chmod 600 "$ENV_FILE"
  log_ok "Credentials saved to ${ENV_FILE}"

  # Validate airgapped prerequisites after all vars are loaded
  if [[ "${AIRGAPPED}" == "true" ]]; then
    validate_airgapped_prereqs
  fi
}

# Create a Harbor project via API (from inside the cluster)
# Usage: create_harbor_project <project_name> <public:true|false>
create_harbor_project() {
  local project_name="$1"
  local is_public="${2:-false}"

  local harbor_core_pod
  harbor_core_pod=$(kubectl -n harbor get pod -l component=core -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$harbor_core_pod" ]]; then
    log_warn "Harbor core pod not found, skipping project creation: ${project_name}"
    return 0
  fi

  local harbor_api="http://harbor-core.harbor.svc.cluster.local/api/v2.0"
  local admin_pass="${HARBOR_ADMIN_PASSWORD:-}"
  if [[ -z "$admin_pass" ]]; then
    admin_pass=$(grep 'harborAdminPassword' "${SERVICES_DIR}/harbor/harbor-values.yaml" | awk -F'"' '{print $2}')
  fi
  local auth="admin:${admin_pass}"

  log_info "Creating Harbor project: ${project_name} (public=${is_public})"
  kubectl exec -n harbor "$harbor_core_pod" -- \
    curl -sf -u "$auth" -X POST "${harbor_api}/projects" \
    -H "Content-Type: application/json" \
    -d "{\"project_name\":\"${project_name}\",\"public\":${is_public},\"metadata\":{\"public\":\"${is_public}\"}}" 2>/dev/null || true
}

# Replace CHANGEME tokens and domain references in stdin, write to stdout
_subst_changeme() {
  sed \
    -e "s|CHANGEME_BOOTSTRAP_CLIENT_SECRET|${KEYCLOAK_BOOTSTRAP_CLIENT_SECRET}|g" \
    -e "s|CHANGEME_KEYCLOAK_DB_PASSWORD|${KEYCLOAK_DB_PASSWORD}|g" \
    -e "s|CHANGEME_MATTERMOST_DB_PASSWORD|${MATTERMOST_DB_PASSWORD}|g" \
    -e "s|CHANGEME_MINIO_ROOT_USER|${MATTERMOST_MINIO_ROOT_USER}|g" \
    -e "s|CHANGEME_MINIO_ROOT_PASSWORD|${MATTERMOST_MINIO_ROOT_PASSWORD}|g" \
    -e "s|CHANGEME_HARBOR_REDIS_PASSWORD|${HARBOR_REDIS_PASSWORD}|g" \
    -e "s|CHANGEME_GRAFANA_ADMIN_PASSWORD|${GRAFANA_ADMIN_PASSWORD}|g" \
    -e "s|CHANGEME_LIBRENMS_DB_PASSWORD|${LIBRENMS_DB_PASSWORD}|g" \
    -e "s|CHANGEME_LIBRENMS_VALKEY_PASSWORD|${LIBRENMS_VALKEY_PASSWORD}|g" \
    -e "s|CHANGEME_HARBOR_ADMIN_PASSWORD|${HARBOR_ADMIN_PASSWORD}|g" \
    -e "s|CHANGEME_HARBOR_MINIO_SECRET_KEY|${HARBOR_MINIO_SECRET_KEY}|g" \
    -e "s|CHANGEME_GITLAB_REDIS_PASSWORD|${GITLAB_REDIS_PASSWORD}|g" \
    -e "s|CHANGEME_HARBOR_DB_PASSWORD|${HARBOR_DB_PASSWORD}|g" \
    -e "s|CHANGEME_KASM_PG_SUPERUSER_PASSWORD|${KASM_PG_SUPERUSER_PASSWORD}|g" \
    -e "s|CHANGEME_KASM_PG_APP_PASSWORD|${KASM_PG_APP_PASSWORD}|g" \
    -e "s|CHANGEME_KC_ADMIN_PASSWORD|${KC_ADMIN_PASSWORD}|g" \
    -e "s|admin:CHANGEME_GENERATE_WITH_HTPASSWD|${BASIC_AUTH_HTPASSWD}|g" \
    -e "s|CHANGEME_IDENTITY_PORTAL_OIDC_SECRET|${IDENTITY_PORTAL_OIDC_SECRET:-changeme}|g" \
    -e "s|CHANGEME_OAUTH2_PROXY_REDIS_PASSWORD|${OAUTH2_PROXY_REDIS_PASSWORD}|g" \
    -e "s|CHANGEME_TRAEFIK_LB_IP|${TRAEFIK_LB_IP}|g" \
    -e "s|CHANGEME_GIT_REPO_URL|${GIT_REPO_URL}|g" \
    -e "s|CHANGEME_ARGO_ROLLOUTS_PLUGIN_URL|${ARGO_ROLLOUTS_PLUGIN_URL}|g" \
    -e "s|CHANGEME_BINARY_URL_ARGOCD_CLI|${BINARY_URL_ARGOCD_CLI}|g" \
    -e "s|CHANGEME_BINARY_URL_KUSTOMIZE|${BINARY_URL_KUSTOMIZE}|g" \
    -e "s|CHANGEME_BINARY_URL_KUBECONFORM|${BINARY_URL_KUBECONFORM}|g" \
    -e "s|CHANGEME_CRD_SCHEMA_BASE_URL|${CRD_SCHEMA_BASE_URL}|g" \
    -e "s|CHANGEME_GATEWAY_API_CRD_URL|${GATEWAY_API_CRD_URL}|g" \
    -e "s|CHANGEME_GIT_BASE_URL|${GIT_BASE_URL}|g" \
    -e "s|CHANGEME_TRAEFIK_FQDN|traefik.${DOMAIN}|g" \
    -e "s|CHANGEME_TRAEFIK_TLS_SECRET|traefik-${DOMAIN_DASHED}-tls|g" \
    -e "s|CHANGEME_KC_REALM|${KC_REALM}|g" \
    -e "s|CHANGEME_RANCHER_FQDN|${RANCHER_FQDN:-rancher.${DOMAIN}}|g" \
    -e "s|CHANGEME_DOMAIN_DASHED|${DOMAIN_DASHED}|g" \
    -e "s|CHANGEME_DOMAIN|${DOMAIN}|g" \
    -e "s|example-dot-com|${DOMAIN_DOT}|g" \
    -e "s|example-com|${DOMAIN_DASHED}|g" \
    -e "s|example\.ch|${DOMAIN}|g"
}

# Apply one or more files with credential/domain substitution
kube_apply_subst() {
  local file
  for file in "$@"; do
    log_info "Applying (substituted): ${file#${REPO_ROOT}/}"
    _subst_changeme < "$file" | kubectl apply -f -
  done
}

# Apply a kustomize directory with CHANGEME substitution
kube_apply_k_subst() {
  local dir="$1"
  log_info "Applying kustomization (with credential substitution): ${dir#${REPO_ROOT}/}"
  kubectl kustomize "$dir" | _subst_changeme | kubectl apply -f -
}

# -----------------------------------------------------------------------------
# HTTPS Connectivity Checks (in-cluster curl pod)
# -----------------------------------------------------------------------------

# Deploy a long-running curl pod for HTTPS checks (called once in Phase 1)
deploy_check_pod() {
  log_info "Deploying HTTPS check pod..."
  kubectl delete pod curl-check -n default --ignore-not-found 2>/dev/null || true
  kubectl run curl-check -n default --restart=Never \
    --image=curlimages/curl \
    --overrides='{"spec":{"nodeSelector":{"workload-type":"general"}}}' \
    -- sleep 7200 2>/dev/null || true
  kubectl wait --for=condition=ready pod/curl-check -n default --timeout=120s 2>/dev/null || \
    log_warn "curl-check pod not ready (HTTPS checks will be skipped)"
}

# Check a single HTTPS endpoint from inside the cluster
check_https() {
  local fqdn="$1"
  local lb_ip="${TRAEFIK_LB_IP:-198.51.100.2}"

  # Skip if curl-check pod doesn't exist
  if ! kubectl get pod curl-check -n default &>/dev/null; then
    log_warn "HTTPS check skipped (no curl-check pod): ${fqdn}"
    return 0
  fi

  local http_code issuer
  http_code=$(kubectl exec -n default curl-check -- \
    curl -sk --max-time 15 --resolve "${fqdn}:443:${lb_ip}" \
    -o /dev/null -w '%{http_code}' \
    "https://${fqdn}/" 2>/dev/null || echo "000")

  # Also check certificate issuer to ensure it's from Vault CA, not Traefik default
  issuer=$(kubectl exec -n default curl-check -- \
    curl -skv --max-time 10 --resolve "${fqdn}:443:${lb_ip}" \
    "https://${fqdn}/" 2>&1 | grep -i 'issuer:' | head -1 | sed 's/.*issuer: //' || echo "unknown")

  if [[ "$http_code" -ge 200 && "$http_code" -lt 500 ]]; then
    if echo "$issuer" | grep -qi "${ORG_NAME}\|vault\|Intermediate"; then
      log_ok "HTTPS: https://${fqdn} -> ${http_code} (cert: Vault CA)"
    else
      log_ok "HTTPS: https://${fqdn} -> ${http_code} (cert issuer: ${issuer})"
    fi
  else
    log_warn "HTTPS: https://${fqdn} -> ${http_code} (service may not be fully ready)"
  fi
}

# Run HTTPS checks for a list of FQDNs
check_https_batch() {
  log_step "Running HTTPS connectivity checks..."
  for fqdn in "$@"; do
    check_https "$fqdn"
  done
}

# Clean up the curl-check pod
cleanup_check_pod() {
  kubectl delete pod curl-check -n default --ignore-not-found 2>/dev/null || true
}

# Extract Root CA certificate (local file primary, Vault ca_chain fallback)
extract_root_ca() {
  # Primary: local Root CA file (always present during deploy)
  local root_ca_file="${CLUSTER_DIR}/root-ca.pem"
  if [[ -f "$root_ca_file" ]]; then
    cat "$root_ca_file"
    return
  fi

  # Fallback: extract Root CA from Vault intermediate CA chain
  local vault_init_file="${CLUSTER_DIR}/vault-init.json"
  if [[ ! -f "$vault_init_file" ]]; then
    echo ""
    return
  fi
  local root_token
  root_token=$(jq -r '.root_token' "$vault_init_file" 2>/dev/null || echo "")
  if [[ -z "$root_token" ]]; then
    echo ""
    return
  fi

  # ca_chain returns intermediate + root; extract the root (last cert)
  local chain
  chain=$(vault_exec "$root_token" read -field=ca_chain pki_int/cert/ca_chain 2>/dev/null || echo "")
  if [[ -n "$chain" ]]; then
    echo "$chain" | awk '/-----BEGIN CERTIFICATE-----/{n++} n==2{print}'
  else
    echo ""
  fi
}

# -----------------------------------------------------------------------------
# Distribute Root CA ConfigMap to service namespaces
# Creates a ConfigMap 'vault-root-ca' containing the Vault Root CA PEM in each
# namespace that needs it for TLS verification (OIDC, etc.)
# Must run AFTER Vault PKI (Phase 2) and AFTER namespaces exist.
# -----------------------------------------------------------------------------
distribute_root_ca() {
  local root_ca
  root_ca=$(extract_root_ca)
  if [[ -z "$root_ca" ]]; then
    log_warn "Could not extract Root CA from Vault — skipping CA distribution"
    return 0
  fi

  log_info "Distributing Root CA ConfigMap to service namespaces..."

  local namespaces=(kube-system monitoring argocd argo-rollouts harbor mattermost gitlab keycloak identity-portal gitlab-runners)
  for ns in "${namespaces[@]}"; do
    ensure_namespace "$ns"
    kubectl create configmap vault-root-ca \
      --from-literal=ca.crt="$root_ca" \
      -n "$ns" --dry-run=client -o yaml | kubectl apply -f -
    log_ok "  vault-root-ca ConfigMap in ${ns}"
  done
}

# -----------------------------------------------------------------------------
# Sync Rancher agent CA checksum (stv-aggregation secret)
# When the Rancher management cluster's CA changes (k3k migration, cert rotation),
# the /cacerts endpoint serves a different certificate chain, but the downstream
# cluster's stv-aggregation secret still has the old CATTLE_CA_CHECKSUM.
# This causes ALL system-agent-upgrader pods to fail with:
#   "Configured cacerts checksum does not match given --ca-checksum"
#
# This function fetches the current /cacerts, computes its sha256, and patches
# the stv-aggregation secret if the hash has drifted. It also cleans up any
# failed system-agent-upgrader pods so the controller retries with the fixed hash.
# -----------------------------------------------------------------------------
sync_rancher_agent_ca() {
  local rancher_url
  rancher_url=$(get_rancher_url)

  # Fetch the CA chain that /cacerts actually serves
  local cacerts_pem
  cacerts_pem=$(curl -sk "${rancher_url}/cacerts" 2>/dev/null || echo "")
  if [[ -z "$cacerts_pem" || "$cacerts_pem" == "null" ]]; then
    log_warn "Could not fetch ${rancher_url}/cacerts — skipping agent CA sync"
    return 0
  fi

  # Strip trailing whitespace/newlines from cacerts PEM — a trailing newline
  # causes checksum mismatch between what install.sh computed and what /cacerts
  # now serves (the Rancher cacerts setting may include an extra trailing newline)
  cacerts_pem=$(echo -n "$cacerts_pem" | sed -e 's/[[:space:]]*$//')

  # Compute the sha256 of what /cacerts returns (this is what install.sh checks)
  local actual_hash
  actual_hash=$(echo -n "$cacerts_pem" | sha256sum | awk '{print $1}')

  # Read the current CATTLE_CA_CHECKSUM from the stv-aggregation secret
  local current_hash
  current_hash=$(kubectl get secret stv-aggregation -n cattle-system \
    -o jsonpath='{.data.CATTLE_CA_CHECKSUM}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

  if [[ "$current_hash" == "$actual_hash" ]]; then
    log_ok "Rancher agent CA checksum is current (${actual_hash:0:16}...)"
    return 0
  fi

  log_warn "Rancher agent CA checksum drift detected"
  log_info "  stv-aggregation has: ${current_hash:0:16}..."
  log_info "  /cacerts serves:     ${actual_hash:0:16}..."

  # Replace the secret data with correct hash and CA cert.
  # Uses kubectl get + jq + replace instead of patch, because merge-patch
  # silently no-ops when the base64 encoding roundtrips to the same value.
  local encoded_hash encoded_cert
  encoded_hash=$(echo -n "$actual_hash" | base64 -w0)
  encoded_cert=$(echo -n "$cacerts_pem" | base64 -w0)

  kubectl get secret stv-aggregation -n cattle-system -o json \
    | jq --arg h "$encoded_hash" --arg c "$encoded_cert" \
      '.data.CATTLE_CA_CHECKSUM = $h | .data["ca.crt"] = $c' \
    | kubectl replace -f -
  log_ok "Replaced stv-aggregation: CATTLE_CA_CHECKSUM + ca.crt updated"

  # Clean up failed system-agent-upgrader pods so the controller retries immediately
  local failed_count
  failed_count=$(kubectl get pods -n cattle-system \
    -l upgrade.cattle.io/plan=system-agent-upgrader \
    --field-selector=status.phase=Failed \
    --no-headers 2>/dev/null | wc -l || echo "0")
  if [[ "$failed_count" -gt 0 ]]; then
    log_info "Cleaning up ${failed_count} failed system-agent-upgrader pods..."
    kubectl delete pods -n cattle-system \
      -l upgrade.cattle.io/plan=system-agent-upgrader \
      --field-selector=status.phase=Failed
    log_ok "Failed pods deleted — system-upgrade-controller will retry"
  fi
}

# -----------------------------------------------------------------------------
# Configure Rancher cluster registries (mirrors + CA trust)
# Uses the Rancher API to set spec.rkeConfig.registries on the cluster object.
# Rancher distributes registries.yaml + CA cert to ALL nodes (including future
# autoscaler nodes) before starting rke2-agent. No DaemonSet needed.
#
# Must run AFTER Harbor is deployed and proxy cache projects are created.
# Rancher detects the plan change and performs a rolling update automatically
# (controlled by upgrade_strategy: worker_concurrency=1, cp_concurrency=1).
# -----------------------------------------------------------------------------
configure_rancher_registries() {
  local root_ca
  root_ca=$(extract_root_ca)
  if [[ -z "$root_ca" ]]; then
    log_warn "Could not extract Root CA from Vault — skipping Rancher registries config"
    return 0
  fi

  local rancher_url rancher_token cluster_name
  rancher_url=$(get_rancher_url)
  rancher_token=$(get_rancher_token)
  cluster_name=$(get_cluster_name)

  log_info "Configuring Rancher cluster registries (mirrors + CA)..."

  # Base64-encode the CA PEM — Rancher's Go struct uses []byte for caBundle,
  # which Go JSON marshaling expects as a base64-encoded string.
  # Raw PEM causes webhook error: "illegal base64 data at input byte 0"
  local ca_b64
  ca_b64=$(printf '%s' "$root_ca" | base64 | tr -d '\n')

  local harbor_fqdn="harbor.${DOMAIN}"

  # Build patch payload via kubectl on the Rancher management cluster (K3K).
  # The Rancher Steve API (v1) has inconsistent PATCH/PUT support for
  # provisioning.cattle.io clusters, so we use kubectl patch directly.
  local harvester_kc="${CLUSTER_DIR}/kubeconfig-harvester.yaml"
  local hk="kubectl --kubeconfig=${harvester_kc}"

  # Find the Rancher server pod (runs in cattle-system on the Harvester management cluster)
  local rancher_pod
  rancher_pod=$($hk get pods -n cattle-system -l app=rancher \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$rancher_pod" ]]; then
    log_warn "Could not find K3K Rancher server pod — trying curl fallback"
    _configure_registries_curl "$rancher_url" "$rancher_token" "$cluster_name" "$ca_b64" "$harbor_fqdn"
    return $?
  fi

  # Write the patch JSON to a temp file, copy into pod, apply
  local patch_file
  patch_file=$(mktemp /tmp/registries-patch-XXXXXX.json)

  cat > "$patch_file" <<PATCHEOF
{
  "spec": {
    "rkeConfig": {
      "registries": {
        "configs": {
          "${harbor_fqdn}": {
            "caBundle": "${ca_b64}"
          }
        },
        "mirrors": {
          "docker.io": {
            "endpoint": ["https://${harbor_fqdn}"],
            "rewrite": { "^(.*)\$": "docker.io/\$1" }
          },
          "quay.io": {
            "endpoint": ["https://${harbor_fqdn}"],
            "rewrite": { "^(.*)\$": "quay.io/\$1" }
          },
          "ghcr.io": {
            "endpoint": ["https://${harbor_fqdn}"],
            "rewrite": { "^(.*)\$": "ghcr.io/\$1" }
          },
          "gcr.io": {
            "endpoint": ["https://${harbor_fqdn}"],
            "rewrite": { "^(.*)\$": "gcr.io/\$1" }
          },
          "registry.k8s.io": {
            "endpoint": ["https://${harbor_fqdn}"],
            "rewrite": { "^(.*)\$": "registry.k8s.io/\$1" }
          },
          "docker.elastic.co": {
            "endpoint": ["https://${harbor_fqdn}"],
            "rewrite": { "^(.*)\$": "docker.elastic.co/\$1" }
          },
          "${harbor_fqdn}": {
            "endpoint": ["https://${harbor_fqdn}"]
          }
        }
      }
    }
  }
}
PATCHEOF

  # Copy patch file into Rancher pod and apply via kubectl patch --patch-file
  $hk cp "$patch_file" "cattle-system/${rancher_pod}:/tmp/registries-patch.json" 2>/dev/null
  rm -f "$patch_file"

  local result
  result=$($hk exec -n cattle-system "$rancher_pod" -- \
    sh -c "kubectl patch clusters.provisioning.cattle.io '${cluster_name}' -n fleet-default --type=merge --patch-file /tmp/registries-patch.json" 2>&1) || true

  if echo "$result" | grep -q "patched"; then
    log_ok "Rancher cluster registries configured via kubectl patch"
    log_info "Rancher will perform a rolling update to distribute registries.yaml + CA to all nodes"
    log_info "Monitor progress: kubectl get nodes -w"
  else
    log_warn "kubectl patch result: ${result}"
    log_warn "Trying curl fallback..."
    _configure_registries_curl "$rancher_url" "$rancher_token" "$cluster_name" "$ca_b64" "$harbor_fqdn"
  fi
}

# Curl fallback for configure_rancher_registries
_configure_registries_curl() {
  local rancher_url="$1" rancher_token="$2" cluster_name="$3" ca_b64="$4" harbor_fqdn="$5"

  # GET the full cluster resource
  local cluster_json
  cluster_json=$(curl -sk "${rancher_url}/v1/provisioning.cattle.io.clusters/fleet-default/${cluster_name}" \
    -H "Authorization: Bearer ${rancher_token}")

  if ! echo "$cluster_json" | jq -e '.metadata.name' &>/dev/null; then
    log_warn "Could not fetch cluster spec from Rancher — skipping registries config"
    return 1
  fi

  # Merge registries into the existing cluster spec
  local updated_json
  updated_json=$(echo "$cluster_json" | jq \
    --arg ca "$ca_b64" \
    --arg hf "$harbor_fqdn" \
    '.spec.rkeConfig.registries = {
      "configs": {
        ($hf): { "caBundle": $ca }
      },
      "mirrors": {
        "docker.io":        { "endpoint": ["https://\($hf)"], "rewrite": { "^(.*)$": "docker.io/$1" } },
        "quay.io":          { "endpoint": ["https://\($hf)"], "rewrite": { "^(.*)$": "quay.io/$1" } },
        "ghcr.io":          { "endpoint": ["https://\($hf)"], "rewrite": { "^(.*)$": "ghcr.io/$1" } },
        "gcr.io":           { "endpoint": ["https://\($hf)"], "rewrite": { "^(.*)$": "gcr.io/$1" } },
        "registry.k8s.io":  { "endpoint": ["https://\($hf)"], "rewrite": { "^(.*)$": "registry.k8s.io/$1" } },
        "docker.elastic.co":{ "endpoint": ["https://\($hf)"], "rewrite": { "^(.*)$": "docker.elastic.co/$1" } },
        ($hf):              { "endpoint": ["https://\($hf)"] }
      }
    }')

  local response http_code
  response=$(curl -sk -w "\n%{http_code}" -X PUT \
    "${rancher_url}/v1/provisioning.cattle.io.clusters/fleet-default/${cluster_name}" \
    -H "Authorization: Bearer ${rancher_token}" \
    -H "Content-Type: application/json" \
    -d "$updated_json")

  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    log_ok "Rancher cluster registries configured via API (${http_code})"
    log_info "Rancher will perform a rolling update to distribute registries.yaml + CA to all nodes"
  else
    log_warn "Rancher registries PUT returned ${http_code} — may need manual configuration"
    log_warn "Response: $(echo "$body" | jq -r '.message // .reason // .' 2>/dev/null | head -3)"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Operator Image Push (loads tarballs from operators/images/ → Harbor)
# Uses a crane pod inside the cluster to push images. This avoids needing the
# Vault Root CA trusted on the local machine (which it won't be at Phase 4.10).
# crane --insecure skips TLS verification for the push.
# Tarball naming convention: <name>-<version>-<arch>.tar.gz
#   e.g. node-labeler-v0.2.0-amd64.tar.gz → harbor.DOMAIN/library/node-labeler:v0.2.0
# -----------------------------------------------------------------------------
push_operator_images() {
  local images_dir="${REPO_ROOT}/operators/images"
  if [[ ! -d "$images_dir" ]]; then
    log_warn "No operator images directory found at operators/images/ — skipping"
    return 0
  fi

  local tarballs
  tarballs=$(find "$images_dir" -name '*.tar.gz' 2>/dev/null || true)
  if [[ -z "$tarballs" ]]; then
    log_warn "No image tarballs found in operators/images/ — skipping"
    return 0
  fi

  local harbor_fqdn="harbor.${DOMAIN}"

  # Get Harbor admin password (prefer .env, fall back to raw values file)
  local admin_pass="${HARBOR_ADMIN_PASSWORD:-}"
  if [[ -z "$admin_pass" ]]; then
    admin_pass=$(grep 'harborAdminPassword' "${SERVICES_DIR}/harbor/harbor-values.yaml" | awk -F'"' '{print $2}')
  fi
  if [[ -z "$admin_pass" || "$admin_pass" == *CHANGEME* ]]; then
    log_warn "Could not resolve Harbor admin password — skipping operator image push"
    return 0
  fi

  # Create a crane pod inside the cluster for pushing images
  local pod_name="image-pusher"
  kubectl delete pod "$pod_name" -n default --ignore-not-found 2>/dev/null || true

  log_info "Creating crane pod for image push..."
  kubectl run "$pod_name" -n default \
    --image=gcr.io/go-containerregistry/crane:debug \
    --restart=Never \
    --command -- sleep 900

  if ! kubectl wait --for=condition=ready pod/"$pod_name" -n default --timeout=120s 2>/dev/null; then
    log_warn "crane pod failed to start — skipping operator image push"
    kubectl delete pod "$pod_name" -n default --ignore-not-found 2>/dev/null || true
    return 0
  fi

  # Authenticate crane to Harbor (--insecure skips TLS verify since nodes
  # may not have the Root CA yet at this point in the deploy)
  # Authenticate crane to Harbor — retry with 30s pause for DNS/connectivity
  local auth_ok=false
  local auth_attempt=0
  while [[ $auth_attempt -lt 3 ]]; do
    if kubectl exec "$pod_name" -n default -- \
      crane auth login "${harbor_fqdn}" -u admin -p "${admin_pass}" --insecure 2>&1; then
      auth_ok=true
      log_ok "crane authenticated to ${harbor_fqdn}"
      break
    fi
    auth_attempt=$((auth_attempt + 1))
    if [[ $auth_attempt -lt 3 ]]; then
      log_info "crane auth login failed (attempt ${auth_attempt}/3) — retrying in 30s..."
      sleep 30
    fi
  done
  if [[ "$auth_ok" != "true" ]]; then
    log_warn "crane auth login failed after 3 attempts — skipping operator image push"
    kubectl delete pod "$pod_name" -n default --ignore-not-found 2>/dev/null || true
    return 0
  fi

  # Copy and push each tarball (with per-image retry)
  local push_count=0
  for tarball in $tarballs; do
    local filename
    filename=$(basename "$tarball")

    # Parse image name and tag from filename: node-labeler-v0.2.0-amd64.tar.gz
    local name tag ref
    name=$(echo "$filename" | sed 's/-v[0-9].*//')
    tag=$(echo "$filename" | sed 's/.*-\(v[0-9][^-]*\)-.*/\1/')
    ref="${harbor_fqdn}/library/${name}:${tag}"

    log_info "Copying ${filename} to crane pod..."
    kubectl cp "$tarball" "default/${pod_name}:/tmp/${filename}"

    log_info "Pushing ${ref}..."
    local tarname="${filename%.gz}"
    local push_ok=false
    for _retry in 1 2 3; do
      if kubectl exec "$pod_name" -n default -- \
        sh -c "gunzip -kf '/tmp/${filename}' && crane push '/tmp/${tarname}' '${ref}' --insecure 2>&1 && rm -f '/tmp/${tarname}'" 2>&1; then
        log_ok "Pushed ${ref}"
        push_count=$((push_count + 1))
        push_ok=true
        break
      fi
      [[ $_retry -lt 3 ]] && { log_info "Push failed, retrying in 10s..."; sleep 10; }
    done
    if [[ "$push_ok" != "true" ]]; then
      log_warn "Failed to push ${ref} after 3 attempts"
    fi
  done

  # Clean up the crane pod
  kubectl delete pod "$pod_name" -n default --ignore-not-found 2>/dev/null || true

  if [[ "$push_count" -gt 0 ]]; then
    # Trigger rollout restart so pods pick up the newly available images
    kubectl rollout restart deployment/node-labeler -n node-labeler 2>/dev/null || true
    kubectl rollout restart deployment/storage-autoscaler -n storage-autoscaler 2>/dev/null || true
    kubectl rollout restart deployment/identity-portal-backend -n identity-portal 2>/dev/null || true
    kubectl rollout restart deployment/identity-portal-frontend -n identity-portal 2>/dev/null || true
    log_ok "Operator images pushed to Harbor (${push_count} images)"
  else
    log_warn "No operator images were pushed successfully"
  fi
}

# -----------------------------------------------------------------------------
# Credentials File Output
# -----------------------------------------------------------------------------
write_credentials_file() {
  local creds_file="${CLUSTER_DIR}/credentials.txt"
  log_info "Writing credentials file..."

  # Gather credentials from cluster secrets (best-effort)
  local argocd_pass vault_root_token harbor_pass kasm_pass

  argocd_pass=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")

  harbor_pass=$(grep 'harborAdminPassword' "${SERVICES_DIR}/harbor/harbor-values.yaml" 2>/dev/null | \
    sed -n 's/.*"\([^"]*\)".*/\1/p' || echo "N/A")

  kasm_pass=$(kubectl -n kasm get secret kasm-secrets \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "see kasm-secrets")

  if [[ -f "${CLUSTER_DIR}/vault-init.json" ]]; then
    vault_root_token=$(jq -r '.root_token' "${CLUSTER_DIR}/vault-init.json" 2>/dev/null || echo "see vault-init.json")
  else
    vault_root_token="see vault-init.json (stored on Harvester)"
  fi

  # Extract Root CA certificate
  local root_ca
  root_ca=$(extract_root_ca)

  cat > "$creds_file" <<CREDSEOF
# RKE2 Cluster Credentials
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# WARNING: Contains secrets — store securely and do NOT commit to git

Vault          https://vault.${DOMAIN}          root / ${vault_root_token}
Grafana        https://grafana.${DOMAIN}        admin / ${GRAFANA_ADMIN_PASSWORD:-N/A}
Prometheus     https://prometheus.${DOMAIN}     (ForwardAuth via Keycloak)
Hubble         https://hubble.${DOMAIN}         (ForwardAuth via Keycloak)
Harbor         https://harbor.${DOMAIN}         admin / ${harbor_pass}
ArgoCD         https://argo.${DOMAIN}           admin / ${argocd_pass}
Rollouts       https://rollouts.${DOMAIN}       (ForwardAuth via Keycloak)
Traefik        https://traefik.${DOMAIN}        (ForwardAuth via Keycloak)
Auth           (oauth2-proxy ForwardAuth — protects prometheus, alertmanager, hubble, rollouts, traefik)
Keycloak       https://keycloak.${DOMAIN}       admin / CHANGEME_KC_ADMIN_PASSWORD  (bootstrap — run setup-keycloak.sh)
Mattermost     https://mattermost.${DOMAIN}     (create admin via mmctl post-deploy)
Kasm           https://kasm.${DOMAIN}           admin@kasm.local / ${kasm_pass}
Identity       https://identity.${DOMAIN}      (Keycloak SSO)
CREDSEOF

  # Append optional services
  if [[ "${DEPLOY_UPTIME_KUMA}" == "true" ]]; then
    echo "Uptime Kuma    https://status.${DOMAIN}        (setup wizard on first visit)" >> "$creds_file"
  fi
  if [[ "${DEPLOY_LIBRENMS}" == "true" ]]; then
    echo "LibreNMS       https://librenms.${DOMAIN}      (setup wizard on first visit)" >> "$creds_file"
  fi

  # Append Root CA certificate if available
  if [[ -n "$root_ca" ]]; then
    cat >> "$creds_file" <<CAEOF

# ============================================================
# Root CA Certificate (${ORG_NAME} Root CA)
# Import this into your browser/OS trust store for HTTPS access
# ============================================================
${root_ca}
CAEOF
  fi

  chmod 600 "$creds_file"
  log_ok "Credentials written to ${creds_file}"
}

# =============================================================================
# GitLab API Helpers
# =============================================================================
# Generic GitLab REST call — sets GITLAB_HTTP_CODE as side-effect
GITLAB_HTTP_CODE=""
gitlab_api() {
  local method="$1" endpoint="$2"
  shift 2
  local response rc=0
  response=$(curl -sk --connect-timeout 10 --max-time 90 -w "\n%{http_code}" -X "$method" \
    "${GITLAB_API:-https://gitlab.${DOMAIN}/api/v4}${endpoint}" \
    -H "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
    "$@") || rc=$?
  if [[ $rc -ne 0 ]]; then
    GITLAB_HTTP_CODE="000"
    log_warn "GitLab API call failed: ${method} ${endpoint} (curl exit ${rc})"
    return 1
  fi
  GITLAB_HTTP_CODE=$(echo "$response" | tail -1)
  echo "$response" | sed '$d'
}

gitlab_get() { gitlab_api GET "$1"; }

gitlab_post() {
  local endpoint="$1" data="$2"
  gitlab_api POST "$endpoint" -H "Content-Type: application/json" -d "$data"
}

gitlab_put() {
  local endpoint="$1" data="$2"
  gitlab_api PUT "$endpoint" -H "Content-Type: application/json" -d "$data"
}

gitlab_delete() { gitlab_api DELETE "$1"; }

# Look up GitLab project ID by path (e.g., "platform_services/my-project")
gitlab_project_id() {
  local project_path="$1"
  local encoded
  encoded=$(echo "$project_path" | sed 's|/|%2F|g')
  gitlab_get "/projects/${encoded}" | jq -r '.id // empty' 2>/dev/null
}

# Look up GitLab group ID by path
gitlab_group_id() {
  local group_path="$1"
  local encoded
  encoded=$(echo "$group_path" | sed 's|/|%2F|g')
  gitlab_get "/groups/${encoded}" | jq -r '.id // empty' 2>/dev/null
}

# Protect a branch with access levels
# Usage: gitlab_protect_branch <project_id> <branch> <push_level> <merge_level>
gitlab_protect_branch() {
  local project_id="$1" branch="$2" push_level="${3:-40}" merge_level="${4:-40}"
  # Try to create; if exists (409), update via PUT
  local resp
  resp=$(gitlab_post "/projects/${project_id}/protected_branches" \
    "{\"name\":\"${branch}\",\"push_access_level\":${push_level},\"merge_access_level\":${merge_level},\"allow_force_push\":false}") || {
    log_warn "Failed to protect branch '${branch}' on project ${project_id}"
    return 1
  }
  if [[ "$GITLAB_HTTP_CODE" == "409" ]]; then
    gitlab_delete "/projects/${project_id}/protected_branches/${branch}" >/dev/null 2>&1 || true
    gitlab_post "/projects/${project_id}/protected_branches" \
      "{\"name\":\"${branch}\",\"push_access_level\":${push_level},\"merge_access_level\":${merge_level},\"allow_force_push\":false}" >/dev/null 2>&1 || \
      log_warn "Failed to re-protect branch '${branch}' on project ${project_id}"
  fi
}

# Add MR approval rule to a project
# Usage: gitlab_add_approval_rule <project_id> <rule_name> <approvals_required> [group_ids_csv]
gitlab_add_approval_rule() {
  local project_id="$1" rule_name="$2" approvals_required="$3" group_ids="${4:-}"
  local data="{\"name\":\"${rule_name}\",\"approvals_required\":${approvals_required}"
  if [[ -n "$group_ids" ]]; then
    data="${data},\"group_ids\":[${group_ids}]"
  fi
  data="${data}}"

  # Check if rule already exists
  local existing=""
  existing=$(gitlab_get "/projects/${project_id}/approval_rules" 2>/dev/null | \
    jq -r ".[] | select(.name == \"${rule_name}\") | .id" 2>/dev/null | head -1) || true
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    gitlab_put "/projects/${project_id}/approval_rules/${existing}" "$data" >/dev/null 2>&1 || \
      log_warn "Failed to update approval rule '${rule_name}' on project ${project_id}"
  else
    gitlab_post "/projects/${project_id}/approval_rules" "$data" >/dev/null 2>&1 || \
      log_warn "Failed to create approval rule '${rule_name}' on project ${project_id}"
  fi
}

# Set a project-level setting
gitlab_set_project_setting() {
  local project_id="$1" key="$2" value="$3"
  gitlab_put "/projects/${project_id}" "{\"${key}\":${value}}" >/dev/null 2>&1 || \
    log_warn "Failed to set ${key} on project ${project_id}"
}

# Set or update a group/project CI/CD variable
gitlab_set_variable() {
  local scope="$1" scope_id="$2" key="$3" value="$4" masked="${5:-false}" protected="${6:-false}"
  local data="{\"key\":\"${key}\",\"value\":\"${value}\",\"masked\":${masked},\"protected\":${protected}}"
  gitlab_post "/${scope}/${scope_id}/variables" "$data" >/dev/null 2>&1 || \
    gitlab_put "/${scope}/${scope_id}/variables/${key}" "$data" >/dev/null 2>&1 || true
}

# Sync a Keycloak group to a GitLab group with a specific access level
# Usage: gitlab_sync_group_membership <gitlab_group_id> <keycloak_group_name> <access_level>
# This creates a SAML/OIDC group link so Keycloak group membership auto-maps to GitLab roles
gitlab_create_group_link() {
  local gitlab_group_id="$1" saml_group="$2" access_level="$3"
  # Remove existing link if any, then create
  gitlab_delete "/groups/${gitlab_group_id}/saml_group_links/${saml_group}" >/dev/null 2>&1 || true
  gitlab_post "/groups/${gitlab_group_id}/saml_group_links" \
    "{\"saml_group_name\":\"${saml_group}\",\"access_level\":${access_level}}" >/dev/null 2>&1 || \
  # Fallback: for OIDC group sync, try the newer API
  gitlab_post "/groups/${gitlab_group_id}/saml_group_links" \
    "{\"name\":\"${saml_group}\",\"access_level\":${access_level}}" >/dev/null 2>&1 || true
}

# Create a Harbor robot account and return the secret
# Usage: create_harbor_robot <robot_name> <project_name> <permissions_json>
create_harbor_robot() {
  local robot_name="$1" project_name="$2" access_json="$3"

  local harbor_core_pod
  harbor_core_pod=$(kubectl -n harbor get pod -l component=core -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$harbor_core_pod" ]]; then
    log_warn "Harbor core pod not found, cannot create robot account: ${robot_name}"
    return 1
  fi

  local harbor_api="http://harbor-core.harbor.svc.cluster.local/api/v2.0"
  local admin_pass="${HARBOR_ADMIN_PASSWORD:-}"
  if [[ -z "$admin_pass" ]]; then
    admin_pass=$(grep 'harborAdminPassword' "${SERVICES_DIR}/harbor/harbor-values.yaml" | awk -F'"' '{print $2}')
  fi
  local auth="admin:${admin_pass}"

  local resp
  resp=$(kubectl exec -n harbor "$harbor_core_pod" -- \
    curl -sf -u "$auth" -X POST "${harbor_api}/robots" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${robot_name}\",\"duration\":-1,\"level\":\"system\",\"permissions\":${access_json}}" 2>/dev/null) || true
  echo "$resp"
}

# =============================================================================
# Keycloak Helpers
# =============================================================================
# These functions provide a reusable interface for Keycloak Admin API operations.
# Used by both deploy-cluster.sh (inline OIDC setup) and setup-keycloak.sh (standalone).

# State variables (set by kc_init)
KC_URL="${KC_URL:-}"
KC_REALM="${KC_REALM:-}"
KC_PORT_FORWARD_PID="${KC_PORT_FORWARD_PID:-}"
OIDC_SECRETS_FILE="${OIDC_SECRETS_FILE:-${SCRIPTS_DIR}/oidc-client-secrets.json}"

# Auto-detect connectivity: if direct HTTPS fails, use kubectl port-forward
_kc_ensure_connectivity() {
  if [[ -n "$KC_PORT_FORWARD_PID" ]]; then
    return 0  # Already using port-forward
  fi
  if curl -sfk --connect-timeout 5 --max-time 10 -o /dev/null \
      "${KC_URL}/realms/master" 2>/dev/null; then
    return 0  # Direct access works
  fi
  log_warn "Direct HTTPS to Keycloak unreachable — starting kubectl port-forward"
  kubectl port-forward svc/keycloak -n keycloak 18080:8080 &>/dev/null &
  KC_PORT_FORWARD_PID=$!
  sleep 3
  KC_URL="http://localhost:18080"
  if curl -sf --connect-timeout 5 --max-time 10 -o /dev/null \
      "${KC_URL}/realms/master" 2>/dev/null; then
    log_ok "Port-forward active — using ${KC_URL}"
  else
    die "Cannot reach Keycloak via direct HTTPS or port-forward"
  fi
}

# Cleanup port-forward on exit (idempotent — safe to register multiple times)
_kc_cleanup() {
  if [[ -n "${KC_PORT_FORWARD_PID:-}" ]]; then
    kill "$KC_PORT_FORWARD_PID" 2>/dev/null || true
    KC_PORT_FORWARD_PID=""
  fi
}

# Get a token via the bootstrap client credentials
kc_get_token() {
  local client_id client_secret
  client_id=$(kubectl -n keycloak get secret keycloak-admin-secret \
    -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_CLIENT_ID}' 2>/dev/null | base64 -d || echo "admin-cli-client")
  client_secret=$(kubectl -n keycloak get secret keycloak-admin-secret \
    -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_CLIENT_SECRET}' 2>/dev/null | base64 -d)

  if [[ -z "$client_secret" ]]; then
    die "Could not retrieve KC_BOOTSTRAP_ADMIN_CLIENT_SECRET from keycloak-admin-secret"
  fi

  curl -sfk --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 --retry-all-errors \
    -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=client_credentials" \
    -d "client_id=${client_id}" \
    -d "client_secret=${client_secret}" | jq -r '.access_token'
}

# Make an authenticated API call to Keycloak
kc_api() {
  local method="$1"
  local path="$2"
  shift 2
  local token
  token=$(kc_get_token)

  curl -sfk --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 --retry-all-errors \
    -X "$method" "${KC_URL}/admin${path}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "$@"
}

# Initialize Keycloak connection — sets KC_URL, KC_REALM, OIDC_SECRETS_FILE
kc_init() {
  KC_URL="https://keycloak.${DOMAIN}"
  : "${KC_REALM:=${DOMAIN%%.*}}"
  OIDC_SECRETS_FILE="${SCRIPTS_DIR}/oidc-client-secrets.json"

  # Register cleanup trap (idempotent)
  trap _kc_cleanup EXIT

  _kc_ensure_connectivity

  # Verify token works
  local retries=0
  while ! kc_get_token &>/dev/null && [[ $retries -lt 10 ]]; do
    sleep 5
    retries=$((retries + 1))
  done
  [[ $retries -lt 10 ]] || die "Cannot authenticate to Keycloak at ${KC_URL}"
  log_ok "Keycloak authenticated via bootstrap client credentials"
}

# Create an OIDC confidential client and return the generated secret
kc_create_client() {
  local client_id="$1"
  local redirect_uri="$2"
  local name="${3:-$client_id}"

  log_info "Creating OIDC client: ${client_id}" >&2

  # Check if client already exists
  local existing
  existing=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=${client_id}" 2>/dev/null || echo "[]")
  local existing_id
  existing_id=$(echo "$existing" | jq -r '.[0].id // empty')

  if [[ -n "$existing_id" ]]; then
    log_info "  Client '${client_id}' already exists (id: ${existing_id}) — updating redirectUris" >&2
    local client_json
    client_json=$(kc_api GET "/realms/${KC_REALM}/clients/${existing_id}" 2>/dev/null || echo "{}")
    if [[ -n "$client_json" && "$client_json" != "{}" ]]; then
      local updated_json
      updated_json=$(echo "$client_json" | jq \
        --arg uri "$redirect_uri" \
        '.redirectUris = ($uri | split(",")) | .webOrigins = ["+"] | .attributes["post.logout.redirect.uris"] = "+"')
      echo "$updated_json" | kc_api PUT "/realms/${KC_REALM}/clients/${existing_id}" -d @- 2>/dev/null || \
        log_warn "  Could not update redirectUris for '${client_id}'" >&2
    fi
    # Retrieve secret
    local secret
    secret=$(kc_api GET "/realms/${KC_REALM}/clients/${existing_id}/client-secret" 2>/dev/null | jq -r '.value // empty')
    echo "$secret"
    return 0
  fi

  # Create client
  kc_api POST "/realms/${KC_REALM}/clients" \
    -d "{
      \"clientId\": \"${client_id}\",
      \"name\": \"${name}\",
      \"enabled\": true,
      \"protocol\": \"openid-connect\",
      \"publicClient\": false,
      \"clientAuthenticatorType\": \"client-secret\",
      \"standardFlowEnabled\": true,
      \"directAccessGrantsEnabled\": false,
      \"serviceAccountsEnabled\": false,
      \"redirectUris\": $(echo "$redirect_uri" | jq -R 'split(",")'),
      \"webOrigins\": [\"+\"],
      \"attributes\": {
        \"post.logout.redirect.uris\": \"+\"
      }
    }"

  # Get the internal UUID
  local internal_id
  internal_id=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=${client_id}" | jq -r '.[0].id')

  # Generate and retrieve client secret
  kc_api POST "/realms/${KC_REALM}/clients/${internal_id}/client-secret" >/dev/null
  local secret
  secret=$(kc_api GET "/realms/${KC_REALM}/clients/${internal_id}/client-secret" | jq -r '.value')

  log_ok "  Client '${client_id}' created (secret: ${secret:0:8}...)" >&2
  echo "$secret"
}

# Create a public OIDC client (PKCE, no secret) — for kubernetes / identity-portal
kc_create_public_client() {
  local client_id="$1"
  local redirect_uri="$2"
  local name="${3:-$client_id}"

  log_info "Creating OIDC client: ${client_id} (public)" >&2

  local existing
  existing=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=${client_id}" 2>/dev/null || echo "[]")
  local existing_id
  existing_id=$(echo "$existing" | jq -r '.[0].id // empty')

  if [[ -n "$existing_id" ]]; then
    log_info "  Client '${client_id}' already exists (id: ${existing_id}) — updating" >&2
    local client_json
    client_json=$(kc_api GET "/realms/${KC_REALM}/clients/${existing_id}" 2>/dev/null || echo "{}")
    if [[ -n "$client_json" && "$client_json" != "{}" ]]; then
      local updated_json
      updated_json=$(echo "$client_json" | jq \
        --arg uri "$redirect_uri" \
        '.publicClient = true |
         .standardFlowEnabled = true |
         .directAccessGrantsEnabled = false |
         .serviceAccountsEnabled = false |
         .redirectUris = ($uri | split(",")) |
         .webOrigins = ["+"] |
         .attributes["post.logout.redirect.uris"] = "+" |
         .attributes["pkce.code.challenge.method"] = "S256"')
      echo "$updated_json" | kc_api PUT "/realms/${KC_REALM}/clients/${existing_id}" -d @- 2>/dev/null || \
        log_warn "  Could not update '${client_id}'" >&2
    fi
    return 0
  fi

  kc_api POST "/realms/${KC_REALM}/clients" \
    -d "{
      \"clientId\": \"${client_id}\",
      \"name\": \"${name}\",
      \"enabled\": true,
      \"protocol\": \"openid-connect\",
      \"publicClient\": true,
      \"standardFlowEnabled\": true,
      \"directAccessGrantsEnabled\": false,
      \"serviceAccountsEnabled\": false,
      \"redirectUris\": $(echo "$redirect_uri" | jq -R 'split(",")'),
      \"webOrigins\": [\"+\"],
      \"attributes\": {
        \"post.logout.redirect.uris\": \"+\",
        \"pkce.code.challenge.method\": \"S256\"
      }
    }"
  log_ok "  Client '${client_id}' created (public — no secret)" >&2
}

# Create a service account OIDC client (machine-to-machine, no browser login)
kc_create_service_account_client() {
  local client_id="$1"
  local name="${2:-$client_id}"

  log_info "Creating service account client: ${client_id}" >&2

  local existing
  existing=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=${client_id}" 2>/dev/null || echo "[]")
  local existing_id
  existing_id=$(echo "$existing" | jq -r '.[0].id // empty')

  if [[ -n "$existing_id" ]]; then
    log_info "  Service account client '${client_id}' already exists (id: ${existing_id})" >&2
    local secret
    secret=$(kc_api GET "/realms/${KC_REALM}/clients/${existing_id}/client-secret" 2>/dev/null | jq -r '.value // empty')
    echo "$secret"
    return 0
  fi

  kc_api POST "/realms/${KC_REALM}/clients" \
    -d "{
      \"clientId\": \"${client_id}\",
      \"name\": \"${name}\",
      \"enabled\": true,
      \"protocol\": \"openid-connect\",
      \"publicClient\": false,
      \"clientAuthenticatorType\": \"client-secret\",
      \"standardFlowEnabled\": false,
      \"directAccessGrantsEnabled\": true,
      \"serviceAccountsEnabled\": true,
      \"redirectUris\": [],
      \"webOrigins\": []
    }"

  local internal_id
  internal_id=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=${client_id}" | jq -r '.[0].id')

  kc_api POST "/realms/${KC_REALM}/clients/${internal_id}/client-secret" >/dev/null
  local secret
  secret=$(kc_api GET "/realms/${KC_REALM}/clients/${internal_id}/client-secret" | jq -r '.value')

  log_ok "  Service account client '${client_id}' created (secret: ${secret:0:8}...)" >&2
  echo "$secret"
}

# Save a client secret to the OIDC secrets JSON file (idempotent)
kc_save_secret() {
  local key="$1" value="$2"
  local file="${OIDC_SECRETS_FILE:-${SCRIPTS_DIR}/oidc-client-secrets.json}"
  if [[ ! -f "$file" ]]; then
    echo "{}" > "$file"
    chmod 600 "$file"
  fi
  local tmp; tmp=$(mktemp)
  jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Create realm + admin/general users + TOTP config
kc_setup_realm() {
  log_step "Creating '${KC_REALM}' realm..."
  local existing_realm
  existing_realm=$(kc_api GET "/realms/${KC_REALM}" 2>/dev/null | jq -r '.realm // empty' || echo "")

  if [[ "$existing_realm" == "$KC_REALM" ]]; then
    log_info "Realm '${KC_REALM}' already exists"
  else
    kc_api POST "/realms" \
      -d "{
        \"realm\": \"${KC_REALM}\",
        \"enabled\": true,
        \"displayName\": \"${ORG_NAME}\",
        \"loginWithEmailAllowed\": true,
        \"duplicateEmailsAllowed\": false,
        \"resetPasswordAllowed\": true,
        \"editUsernameAllowed\": false,
        \"bruteForceProtected\": true,
        \"permanentLockout\": false,
        \"maxFailureWaitSeconds\": 900,
        \"minimumQuickLoginWaitSeconds\": 60,
        \"waitIncrementSeconds\": 60,
        \"quickLoginCheckMilliSeconds\": 1000,
        \"maxDeltaTimeSeconds\": 43200,
        \"failureFactor\": 5,
        \"sslRequired\": \"external\",
        \"accessTokenLifespan\": 300,
        \"ssoSessionIdleTimeout\": 120,
        \"ssoSessionMaxLifespan\": 36000
      }"
    log_ok "Realm '${KC_REALM}' created"
  fi

  # Generated passwords for realm users
  REALM_ADMIN_PASS=$(openssl rand -base64 24)
  REALM_USER_PASS=$(openssl rand -base64 24)

  # Create realm admin user
  log_step "Creating realm admin user..."
  local existing_user
  existing_user=$(kc_api GET "/realms/${KC_REALM}/users?username=admin" 2>/dev/null | jq -r '.[0].id // empty' || echo "")

  if [[ -n "$existing_user" ]]; then
    log_info "Admin user already exists (id: ${existing_user})"
  else
    kc_api POST "/realms/${KC_REALM}/users" \
      -d "{
        \"username\": \"admin\",
        \"email\": \"admin@${DOMAIN}\",
        \"enabled\": true,
        \"emailVerified\": true,
        \"firstName\": \"Realm\",
        \"lastName\": \"Admin\",
        \"requiredActions\": [],
        \"credentials\": [{
          \"type\": \"password\",
          \"value\": \"${REALM_ADMIN_PASS}\",
          \"temporary\": false
        }]
      }"
    log_ok "Admin user created"

    # Assign realm-admin role
    local admin_user_id
    admin_user_id=$(kc_api GET "/realms/${KC_REALM}/users?username=admin" | jq -r '.[0].id')
    local rm_client_id
    rm_client_id=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=realm-management" | jq -r '.[0].id')
    local realm_admin_role
    realm_admin_role=$(kc_api GET "/realms/${KC_REALM}/clients/${rm_client_id}/roles/realm-admin")
    kc_api POST "/realms/${KC_REALM}/users/${admin_user_id}/role-mappings/clients/${rm_client_id}" \
      -d "[${realm_admin_role}]"
    log_ok "realm-admin role assigned to admin user"
  fi

  # Create general user
  log_step "Creating general user..."
  local existing_general_user
  existing_general_user=$(kc_api GET "/realms/${KC_REALM}/users?username=user" 2>/dev/null | jq -r '.[0].id // empty' || echo "")

  if [[ -n "$existing_general_user" ]]; then
    log_info "General user already exists (id: ${existing_general_user})"
  else
    kc_api POST "/realms/${KC_REALM}/users" \
      -d "{
        \"username\": \"user\",
        \"email\": \"user@${DOMAIN}\",
        \"enabled\": true,
        \"emailVerified\": true,
        \"firstName\": \"General\",
        \"lastName\": \"User\",
        \"requiredActions\": [],
        \"credentials\": [{
          \"type\": \"password\",
          \"value\": \"${REALM_USER_PASS}\",
          \"temporary\": false
        }]
      }"
    log_ok "General user created"
  fi

  # Enable TOTP as optional action
  log_step "Enabling TOTP 2FA..."
  kc_api PUT "/realms/${KC_REALM}" \
    -d "{
      \"realm\": \"${KC_REALM}\",
      \"otpPolicyType\": \"totp\",
      \"otpPolicyAlgorithm\": \"HmacSHA1\",
      \"otpPolicyDigits\": 6,
      \"otpPolicyPeriod\": 30
    }" 2>/dev/null || true
  kc_api PUT "/realms/${KC_REALM}/authentication/required-actions/CONFIGURE_TOTP" \
    -d '{"alias":"CONFIGURE_TOTP","name":"Configure OTP","defaultAction":false,"enabled":true,"priority":10}' \
    2>/dev/null || true
  log_ok "TOTP available as optional action"
}

# Create 9 standard groups + assign admin to platform-admins, user to developers
kc_create_groups() {
  log_step "Creating Keycloak groups..."
  local groups=("platform-admins" "harvester-admins" "rancher-admins" "infra-engineers" "network-engineers" "senior-developers" "developers" "viewers" "ci-service-accounts")

  for group in "${groups[@]}"; do
    local existing
    existing=$(kc_api GET "/realms/${KC_REALM}/groups?search=${group}" 2>/dev/null | jq -r '.[0].name // empty' || echo "")
    if [[ "$existing" == "$group" ]]; then
      log_info "  Group '${group}' already exists"
    else
      kc_api POST "/realms/${KC_REALM}/groups" -d "{\"name\": \"${group}\"}"
      log_ok "  Group '${group}' created"
    fi
  done

  # Add admin to platform-admins
  local admin_id group_id
  admin_id=$(kc_api GET "/realms/${KC_REALM}/users?username=admin" | jq -r '.[0].id')
  group_id=$(kc_api GET "/realms/${KC_REALM}/groups?search=platform-admins" | jq -r '.[0].id')
  if [[ -n "$admin_id" && -n "$group_id" ]]; then
    kc_api PUT "/realms/${KC_REALM}/users/${admin_id}/groups/${group_id}" 2>/dev/null || true
    log_ok "Admin user added to platform-admins"
  fi

  # Add general user to developers
  local user_id dev_group_id
  user_id=$(kc_api GET "/realms/${KC_REALM}/users?username=user" 2>/dev/null | jq -r '.[0].id // empty' || echo "")
  dev_group_id=$(kc_api GET "/realms/${KC_REALM}/groups?search=developers" 2>/dev/null | jq -r '.[0].id // empty' || echo "")
  if [[ -n "$user_id" && -n "$dev_group_id" ]]; then
    kc_api PUT "/realms/${KC_REALM}/users/${user_id}/groups/${dev_group_id}" 2>/dev/null || true
    log_ok "General user added to developers"
  fi
}

# Create "groups" client scope with group membership mapper
kc_create_groups_scope() {
  log_step "Creating 'groups' client scope..."
  local groups_scope_exists
  groups_scope_exists=$(kc_api GET "/realms/${KC_REALM}/client-scopes" 2>/dev/null | jq -r '.[] | select(.name=="groups") | .id // empty' || echo "")
  if [[ -n "$groups_scope_exists" ]]; then
    log_info "  Client scope 'groups' already exists (id: ${groups_scope_exists})"
  else
    kc_api POST "/realms/${KC_REALM}/client-scopes" \
      -d '{
        "name": "groups",
        "description": "Group membership",
        "protocol": "openid-connect",
        "attributes": {
          "include.in.token.scope": "true",
          "display.on.consent.screen": "true"
        },
        "protocolMappers": [{
          "name": "groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "config": {
            "full.path": "false",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "claim.name": "groups",
            "userinfo.token.claim": "true"
          }
        }]
      }'
    log_ok "  Client scope 'groups' created with group membership mapper"
  fi
}

# Add group membership + audience mappers to a list of clients
kc_add_group_mappers() {
  local client_ids=("$@")
  log_step "Adding group/audience mappers to clients..."
  for client_id_name in "${client_ids[@]}"; do
    local internal_id
    internal_id=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=${client_id_name}" 2>/dev/null | jq -r '.[0].id // empty' || echo "")
    if [[ -n "$internal_id" ]]; then
      kc_api POST "/realms/${KC_REALM}/clients/${internal_id}/protocol-mappers/models" \
        -d "{
          \"name\": \"group-membership\",
          \"protocol\": \"openid-connect\",
          \"protocolMapper\": \"oidc-group-membership-mapper\",
          \"config\": {
            \"full.path\": \"false\",
            \"id.token.claim\": \"true\",
            \"access.token.claim\": \"true\",
            \"claim.name\": \"groups\",
            \"userinfo.token.claim\": \"true\"
          }
        }" 2>/dev/null || true
      kc_api POST "/realms/${KC_REALM}/clients/${internal_id}/protocol-mappers/models" \
        -d "{
          \"name\": \"audience-${client_id_name}\",
          \"protocol\": \"openid-connect\",
          \"protocolMapper\": \"oidc-audience-mapper\",
          \"config\": {
            \"included.client.audience\": \"${client_id_name}\",
            \"id.token.claim\": \"true\",
            \"access.token.claim\": \"true\"
          }
        }" 2>/dev/null || true
      log_ok "  Mappers added to ${client_id_name}"
    fi
  done
}

# Add "groups" optional scope to a list of clients
kc_add_groups_scope_to_clients() {
  local client_ids=("$@")
  local groups_scope_id
  groups_scope_id=$(kc_api GET "/realms/${KC_REALM}/client-scopes" 2>/dev/null | jq -r '.[] | select(.name=="groups") | .id // empty' || echo "")
  if [[ -z "$groups_scope_id" ]]; then
    log_warn "Could not find 'groups' client scope — skipping"
    return
  fi
  for cid in "${client_ids[@]}"; do
    local cid_internal
    cid_internal=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=${cid}" 2>/dev/null | jq -r '.[0].id // empty' || echo "")
    if [[ -n "$cid_internal" ]]; then
      kc_api PUT "/realms/${KC_REALM}/clients/${cid_internal}/optional-client-scopes/${groups_scope_id}" 2>/dev/null || true
    fi
  done
  log_ok "Added 'groups' scope to ${#client_ids[@]} client(s)"
}

# Create 12 test users across all groups
kc_create_test_users() {
  log_step "Creating test users..."
  local TEST_USER_PASS="TestUser2026!"

  _kc_create_test_user() {
    local username="$1" email="$2" first="$3" last="$4"
    shift 4
    local group_names=("$@")

    local existing_id
    existing_id=$(kc_api GET "/realms/${KC_REALM}/users?username=${username}" 2>/dev/null \
      | jq -r '.[0].id // empty' || echo "")

    if [[ -n "$existing_id" ]]; then
      log_info "  User '${username}' already exists — skipping"
    else
      kc_api POST "/realms/${KC_REALM}/users" \
        -d "{
          \"username\": \"${username}\",
          \"email\": \"${email}\",
          \"enabled\": true,
          \"emailVerified\": true,
          \"firstName\": \"${first}\",
          \"lastName\": \"${last}\",
          \"requiredActions\": [],
          \"credentials\": [{
            \"type\": \"password\",
            \"value\": \"${TEST_USER_PASS}\",
            \"temporary\": false
          }]
        }"
      log_ok "  Created user: ${username}"
    fi

    local user_id
    user_id=$(kc_api GET "/realms/${KC_REALM}/users?username=${username}" | jq -r '.[0].id')
    for grp in "${group_names[@]}"; do
      local grp_id
      grp_id=$(kc_api GET "/realms/${KC_REALM}/groups?search=${grp}" 2>/dev/null \
        | jq -r '.[0].id // empty' || echo "")
      if [[ -n "$grp_id" ]]; then
        kc_api PUT "/realms/${KC_REALM}/users/${user_id}/groups/${grp_id}" 2>/dev/null || true
      fi
    done
  }

  _kc_create_test_user "alice.morgan" "alice.morgan@${DOMAIN}" "Alice" "Morgan" \
    platform-admins harvester-admins rancher-admins
  _kc_create_test_user "bob.chen" "bob.chen@${DOMAIN}" "Bob" "Chen" \
    platform-admins
  _kc_create_test_user "carol.silva" "carol.silva@${DOMAIN}" "Carol" "Silva" \
    infra-engineers harvester-admins
  _kc_create_test_user "dave.kumar" "dave.kumar@${DOMAIN}" "Dave" "Kumar" \
    infra-engineers network-engineers
  _kc_create_test_user "eve.mueller" "eve.mueller@${DOMAIN}" "Eve" "Mueller" \
    network-engineers
  _kc_create_test_user "frank.jones" "frank.jones@${DOMAIN}" "Frank" "Jones" \
    senior-developers developers
  _kc_create_test_user "grace.park" "grace.park@${DOMAIN}" "Grace" "Park" \
    senior-developers rancher-admins
  _kc_create_test_user "henry.wilson" "henry.wilson@${DOMAIN}" "Henry" "Wilson" \
    developers
  _kc_create_test_user "iris.tanaka" "iris.tanaka@${DOMAIN}" "Iris" "Tanaka" \
    developers
  _kc_create_test_user "jack.brown" "jack.brown@${DOMAIN}" "Jack" "Brown" \
    developers
  _kc_create_test_user "kate.lee" "kate.lee@${DOMAIN}" "Kate" "Lee" \
    viewers
  _kc_create_test_user "leo.garcia" "leo.garcia@${DOMAIN}" "Leo" "Garcia" \
    viewers developers

  log_ok "12 test users created (password: ${TEST_USER_PASS})"
}

# Bind Grafana to Keycloak OIDC
kc_bind_grafana() {
  log_step "Binding Grafana to Keycloak..."
  local oidc_issuer="https://keycloak.${DOMAIN}/realms/${KC_REALM}"
  local grafana_secret
  grafana_secret=$(jq -r '.grafana' "$OIDC_SECRETS_FILE")

  kubectl -n monitoring set env deployment/grafana \
    GF_AUTH_GENERIC_OAUTH_ENABLED="true" \
    GF_AUTH_GENERIC_OAUTH_NAME="Keycloak" \
    GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP="true" \
    GF_AUTH_GENERIC_OAUTH_CLIENT_ID="grafana" \
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="${grafana_secret}" \
    GF_AUTH_GENERIC_OAUTH_SCOPES="openid profile email" \
    GF_AUTH_GENERIC_OAUTH_AUTH_URL="${oidc_issuer}/protocol/openid-connect/auth?prompt=login" \
    GF_AUTH_GENERIC_OAUTH_TOKEN_URL="${oidc_issuer}/protocol/openid-connect/token" \
    GF_AUTH_GENERIC_OAUTH_API_URL="${oidc_issuer}/protocol/openid-connect/userinfo" \
    GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH="contains(groups[*], 'platform-admins') && 'Admin' || contains(groups[*], 'infra-engineers') && 'Admin' || contains(groups[*], 'network-engineers') && 'Viewer' || contains(groups[*], 'senior-developers') && 'Editor' || contains(groups[*], 'developers') && 'Editor' || 'Viewer'" \
    GF_AUTH_SIGNOUT_REDIRECT_URL="${oidc_issuer}/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2Fgrafana.${DOMAIN}%2Flogin" \
    GF_AUTH_GENERIC_OAUTH_TLS_CLIENT_CA="/etc/ssl/certs/vault-root-ca.pem" \
    2>/dev/null || log_warn "Grafana OIDC binding may need manual configuration"
  log_ok "Grafana OIDC configured"
}

# Bind Vault to Keycloak OIDC
kc_bind_vault() {
  log_step "Binding Vault to Keycloak..."
  local oidc_issuer="https://keycloak.${DOMAIN}/realms/${KC_REALM}"
  local vault_secret vault_init_file root_token
  vault_secret=$(jq -r '.vault' "$OIDC_SECRETS_FILE")
  vault_init_file="${CLUSTER_DIR}/vault-init.json"

  if [[ ! -f "$vault_init_file" ]]; then
    log_warn "vault-init.json not found, configure Vault OIDC manually"
    return 0
  fi

  root_token=$(jq -r '.root_token' "$vault_init_file")
  vault_exec "$root_token" auth enable oidc 2>/dev/null || log_info "OIDC auth already enabled"

  local root_ca_pem
  root_ca_pem=$(extract_root_ca)
  if [[ -n "$root_ca_pem" ]]; then
    echo "$root_ca_pem" > /tmp/vault-oidc-ca.pem
    kubectl cp /tmp/vault-oidc-ca.pem vault/vault-0:/tmp/oidc-ca.pem
    rm -f /tmp/vault-oidc-ca.pem
    vault_exec "$root_token" write auth/oidc/config \
      oidc_discovery_url="${oidc_issuer}" \
      oidc_client_id="vault" \
      oidc_client_secret="${vault_secret}" \
      default_role="default" \
      oidc_discovery_ca_pem=@/tmp/oidc-ca.pem
  else
    log_warn "Could not extract Root CA — Vault OIDC may fail TLS verification"
    vault_exec "$root_token" write auth/oidc/config \
      oidc_discovery_url="${oidc_issuer}" \
      oidc_client_id="vault" \
      oidc_client_secret="${vault_secret}" \
      default_role="default"
  fi

  kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 \
    VAULT_TOKEN="$root_token" \
    sh -c 'vault write auth/oidc/role/default - <<VEOF
{
  "bound_audiences": ["vault"],
  "allowed_redirect_uris": [
    "https://vault.'"${DOMAIN}"'/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback"
  ],
  "user_claim": "preferred_username",
  "groups_claim": "groups",
  "policies": ["default"],
  "token_ttl": "1h"
}
VEOF'
  log_ok "Vault OIDC configured"
}

# Bind Harbor to Keycloak OIDC
kc_bind_harbor() {
  log_step "Binding Harbor to Keycloak..."
  local oidc_issuer="https://keycloak.${DOMAIN}/realms/${KC_REALM}"
  local harbor_secret harbor_admin_pass harbor_core_pod
  harbor_secret=$(jq -r '.harbor' "$OIDC_SECRETS_FILE")
  harbor_admin_pass="${HARBOR_ADMIN_PASSWORD}"
  harbor_core_pod=$(kubectl -n harbor get pod -l component=core -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$harbor_core_pod" ]]; then
    kubectl exec -n harbor "$harbor_core_pod" -- \
      curl -sf -u "admin:${harbor_admin_pass}" -X PUT \
      "http://harbor-core.harbor.svc.cluster.local/api/v2.0/configurations" \
      -H "Content-Type: application/json" \
      -d "{
        \"auth_mode\": \"oidc_auth\",
        \"oidc_name\": \"Keycloak\",
        \"oidc_endpoint\": \"${oidc_issuer}\",
        \"oidc_client_id\": \"harbor\",
        \"oidc_client_secret\": \"${harbor_secret}\",
        \"oidc_scope\": \"openid,profile,email\",
        \"oidc_auto_onboard\": true,
        \"oidc_groups_claim\": \"groups\",
        \"oidc_admin_group\": \"platform-admins\",
        \"oidc_verify_cert\": true,
        \"primary_auth_mode\": true
      }" 2>/dev/null || log_warn "Harbor OIDC binding failed (configure manually in Harbor UI)"

    kubectl -n harbor set env deployment/harbor-core \
      SSL_CERT_FILE="/etc/ssl/certs/vault-root-ca.pem" 2>/dev/null || true
    kubectl -n harbor patch deployment harbor-core --type=json -p '[
      {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "vault-root-ca", "configMap": {"name": "vault-root-ca"}}},
      {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {"name": "vault-root-ca", "mountPath": "/etc/ssl/certs/vault-root-ca.pem", "subPath": "ca.crt", "readOnly": true}}
    ]' 2>/dev/null || log_warn "Could not patch harbor-core with Root CA volume (may already exist)"
    log_ok "Harbor OIDC configured"
  else
    log_warn "Harbor core pod not found, configure OIDC manually"
  fi
}

# Bind Rancher to Keycloak OIDC (automated via Rancher v3 API)
kc_bind_rancher() {
  log_step "Binding Rancher to Keycloak OIDC..."
  local rancher_url rancher_token rancher_secret
  rancher_url=$(get_rancher_url)
  rancher_token=$(get_rancher_token)
  rancher_secret=$(jq -r '.rancher' "$OIDC_SECRETS_FILE")
  local oidc_issuer="https://keycloak.${DOMAIN}/realms/${KC_REALM}"

  if [[ -z "$rancher_secret" || "$rancher_secret" == "null" ]]; then
    log_warn "Rancher OIDC secret not found — skipping"
    return 0
  fi

  # Enable Keycloak OIDC auth provider via Rancher API
  local http_code
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" -X PUT \
    "${rancher_url}/v3/keycloakOIDCConfigs/keycloakoidc" \
    -H "Authorization: Bearer ${rancher_token}" \
    -H "Content-Type: application/json" \
    -d "{
      \"enabled\": true,
      \"clientId\": \"rancher\",
      \"clientSecret\": \"${rancher_secret}\",
      \"issuer\": \"${oidc_issuer}\",
      \"rancherUrl\": \"${rancher_url}\",
      \"authEndpoint\": \"${oidc_issuer}/protocol/openid-connect/auth\",
      \"accessMode\": \"unrestricted\"
    }" 2>/dev/null)

  if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
    log_ok "Rancher Keycloak OIDC configured via API"
  else
    log_warn "Rancher OIDC API returned HTTP ${http_code} — may need manual configuration"
    log_info "  Navigate to: Users & Authentication > Auth Provider > Keycloak (OIDC)"
    log_info "  Client ID: rancher, Issuer: ${oidc_issuer}"
  fi
}

# Create K8s secret for an oauth2-proxy instance from oidc-client-secrets.json
kc_deploy_oauth2_proxy_secret() {
  local client_id="$1"
  local ns="$2"
  local name="$3"

  local client_secret cookie_secret
  client_secret=$(jq -r ".[\"${client_id}\"] // empty" "$OIDC_SECRETS_FILE")
  cookie_secret=$(openssl rand -base64 32 | tr -- '+/' '-_')

  if [[ -z "$client_secret" ]]; then
    log_warn "Client secret for ${client_id} not found — skipping oauth2-proxy-${name}"
    return 1
  fi

  kubectl create secret generic "oauth2-proxy-${name}" \
    --namespace="${ns}" \
    --from-literal=client-secret="${client_secret}" \
    --from-literal=cookie-secret="${cookie_secret}" \
    --dry-run=client -o yaml | kubectl apply -f -
  log_ok "Secret oauth2-proxy-${name} created in ${ns}"
}

# Bind ArgoCD to Keycloak OIDC (patch ConfigMap + RBAC)
kc_bind_argocd() {
  log_step "Binding ArgoCD to Keycloak..."
  local oidc_issuer="https://keycloak.${DOMAIN}/realms/${KC_REALM}"
  local argocd_secret
  argocd_secret=$(jq -r '.argocd' "$OIDC_SECRETS_FILE")

  local argocd_root_ca
  argocd_root_ca=$(extract_root_ca)

  local oidc_yaml
  oidc_yaml="name: Keycloak
issuer: ${oidc_issuer}
clientID: argocd
clientSecret: \"${argocd_secret}\"
requestedScopes:
  - openid
  - profile
  - email
  - groups
forceAuthRequestParameters:
  prompt: login"

  if [[ -n "${argocd_root_ca:-}" ]]; then
    oidc_yaml="${oidc_yaml}
rootCA: |
$(echo "$argocd_root_ca" | sed 's/^/  /')"
  fi

  local patch_json
  patch_json=$(jq -n --arg config "$oidc_yaml" --arg url "https://argo.${DOMAIN}" \
    '{"data": {"url": $url, "oidc.config": $config}}')
  kubectl -n argocd patch configmap argocd-cm --type merge -p "$patch_json" \
    2>/dev/null || log_warn "ArgoCD OIDC binding may need manual configuration"

  kubectl -n argocd patch configmap argocd-rbac-cm --type merge -p "{
    \"data\": {
      \"policy.csv\": \"g, platform-admins, role:admin\ng, developers, role:readonly\np, role:developer, applications, sync, */*, allow\np, role:developer, applications, get, */*, allow\ng, developers, role:developer\n\",
      \"policy.default\": \"role:readonly\"
    }
  }" 2>/dev/null || true

  kubectl -n argocd rollout restart deployment/argocd-server 2>/dev/null || true
  log_ok "ArgoCD OIDC configured"
}

# Bind Mattermost to Keycloak OIDC
kc_bind_mattermost() {
  log_step "Binding Mattermost to Keycloak..."
  local oidc_issuer="https://keycloak.${DOMAIN}/realms/${KC_REALM}"
  local mm_secret
  mm_secret=$(jq -r '.mattermost' "$OIDC_SECRETS_FILE")

  kubectl -n mattermost set env deployment/mattermost \
    MM_OPENIDSETTINGS_ENABLE="true" \
    MM_OPENIDSETTINGS_SECRET="${mm_secret}" \
    MM_OPENIDSETTINGS_ID="mattermost" \
    MM_OPENIDSETTINGS_DISCOVERYENDPOINT="${oidc_issuer}/.well-known/openid-configuration" \
    SSL_CERT_FILE="/etc/ssl/certs/vault-root-ca.pem" \
    2>/dev/null || log_warn "Mattermost OIDC binding may need manual configuration"

  kubectl -n mattermost patch deployment mattermost --type=json -p '[
    {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "vault-root-ca", "configMap": {"name": "vault-root-ca"}}},
    {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {"name": "vault-root-ca", "mountPath": "/etc/ssl/certs/vault-root-ca.pem", "subPath": "ca.crt", "readOnly": true}}
  ]' 2>/dev/null || log_warn "Could not patch mattermost with Root CA volume (may already exist)"
  log_ok "Mattermost OIDC configured"
}
