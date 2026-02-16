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
    harvester_cloud_provider_kubeconfig_path cluster_name ssh_authorized_keys)

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
  ensure_cloud_provider_kubeconfig
  log_ok "External files ready"
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
  if helm repo list 2>/dev/null | grep -q "^${name}"; then
    log_info "Helm repo '${name}' already exists, updating..."
  else
    log_info "Adding Helm repo '${name}' → ${url}"
    helm repo add "$name" "$url"
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

  # Organization name — derive from domain if not set
  # "example.com" → "Example Org", "tiger.net" → "Tiger"
  if [[ -z "${ORG_NAME:-}" ]]; then
    local _domain_base="${DOMAIN%%.*}"
    ORG_NAME=$(echo "$_domain_base" | sed -E 's/([a-z])([A-Z])/\1 \2/g; s/[-_]/ /g' \
      | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
  fi

  : "${KC_REALM:=${DOMAIN%%.*}}"
  : "${GIT_REPO_URL:=$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || echo "git@github.com:OWNER/rke2-cluster.git")}"

  # Harvester context name in ~/.kube/config (for auto-extracting kubeconfig)
  : "${HARVESTER_CONTEXT:=harvester}"

  # Cloud-init override (optional — paths to custom cloud-init YAML files)
  : "${USER_DATA_CP_FILE:=}"
  : "${USER_DATA_WORKER_FILE:=}"

  # Export for subshells
  export DEPLOY_UPTIME_KUMA DEPLOY_LIBRENMS
  export AIRGAPPED UPSTREAM_PROXY_REGISTRY
  export KEYCLOAK_BOOTSTRAP_CLIENT_SECRET KEYCLOAK_DB_PASSWORD
  export MATTERMOST_DB_PASSWORD MATTERMOST_MINIO_ROOT_USER MATTERMOST_MINIO_ROOT_PASSWORD
  export HARBOR_REDIS_PASSWORD HARBOR_ADMIN_PASSWORD HARBOR_MINIO_SECRET_KEY HARBOR_DB_PASSWORD
  export KASM_PG_SUPERUSER_PASSWORD KASM_PG_APP_PASSWORD KC_ADMIN_PASSWORD
  export LIBRENMS_DB_PASSWORD LIBRENMS_VALKEY_PASSWORD
  export GITLAB_ROOT_PASSWORD GITLAB_PRAEFECT_DB_PASSWORD GITLAB_REDIS_PASSWORD
  export GITLAB_GITALY_TOKEN GITLAB_PRAEFECT_TOKEN GITLAB_CHART_PATH
  export GITLAB_API_TOKEN
  export OAUTH2_PROXY_REDIS_PASSWORD
  export GRAFANA_ADMIN_PASSWORD BASIC_AUTH_PASSWORD BASIC_AUTH_HTPASSWD
  export DOMAIN DOMAIN_DASHED DOMAIN_DOT TRAEFIK_LB_IP
  export ORG_NAME KC_REALM GIT_REPO_URL
  export HARVESTER_CONTEXT
  export USER_DATA_CP_FILE USER_DATA_WORKER_FILE

  # Bridge cloud-init overrides to Terraform via TF_VAR_ env vars
  [[ -n "$USER_DATA_CP_FILE" ]] && export TF_VAR_user_data_cp_file="$USER_DATA_CP_FILE"
  [[ -n "$USER_DATA_WORKER_FILE" ]] && export TF_VAR_user_data_worker_file="$USER_DATA_WORKER_FILE"

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
    -e "s|CHANGEME_OAUTH2_PROXY_REDIS_PASSWORD|${OAUTH2_PROXY_REDIS_PASSWORD}|g" \
    -e "s|CHANGEME_TRAEFIK_LB_IP|${TRAEFIK_LB_IP}|g" \
    -e "s|CHANGEME_GIT_REPO_URL|${GIT_REPO_URL}|g" \
    -e "s|CHANGEME_TRAEFIK_FQDN|traefik.${DOMAIN}|g" \
    -e "s|CHANGEME_TRAEFIK_TLS_SECRET|traefik-${DOMAIN_DASHED}-tls|g" \
    -e "s|CHANGEME_KC_REALM|${KC_REALM}|g" \
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

  local namespaces=(kube-system monitoring argocd argo-rollouts harbor mattermost gitlab keycloak)
  for ns in "${namespaces[@]}"; do
    ensure_namespace "$ns"
    kubectl create configmap vault-root-ca \
      --from-literal=ca.crt="$root_ca" \
      -n "$ns" --dry-run=client -o yaml | kubectl apply -f -
    log_ok "  vault-root-ca ConfigMap in ${ns}"
  done
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

  # Find the K3K Rancher server pod
  local rancher_pod
  rancher_pod=$($hk get pods -n k3k-rancher -l app=k3k-rancher-server \
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

  # Copy patch file into K3K pod and apply via kubectl patch --patch-file
  $hk cp "$patch_file" "k3k-rancher/${rancher_pod}:/tmp/registries-patch.json" 2>/dev/null
  rm -f "$patch_file"

  local result
  result=$($hk exec -n k3k-rancher "$rancher_pod" -- \
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
#   e.g. node-labeler-v0.1.0-amd64.tar.gz → harbor.DOMAIN/library/node-labeler:v0.1.0
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
  kubectl exec "$pod_name" -n default -- \
    crane auth login "${harbor_fqdn}" -u admin -p "${admin_pass}" --insecure 2>/dev/null || {
    log_warn "crane auth login failed — skipping operator image push"
    kubectl delete pod "$pod_name" -n default --ignore-not-found 2>/dev/null || true
    return 0
  }

  # Copy and push each tarball
  local push_count=0
  for tarball in $tarballs; do
    local filename
    filename=$(basename "$tarball")

    # Parse image name and tag from filename: node-labeler-v0.1.0-amd64.tar.gz
    local name tag ref
    name=$(echo "$filename" | sed 's/-v[0-9].*//')
    tag=$(echo "$filename" | sed 's/.*-\(v[0-9][^-]*\)-.*/\1/')
    ref="${harbor_fqdn}/library/${name}:${tag}"

    log_info "Copying ${filename} to crane pod..."
    kubectl cp "$tarball" "default/${pod_name}:/tmp/${filename}" 2>/dev/null

    log_info "Pushing ${ref}..."
    local tarname="${filename%.gz}"
    if kubectl exec "$pod_name" -n default -- \
      sh -c "gunzip -kf '/tmp/${filename}' && crane push '/tmp/${tarname}' '${ref}' --insecure && rm -f '/tmp/${tarname}'" 2>/dev/null; then
      log_ok "Pushed ${ref}"
      push_count=$((push_count + 1))
    else
      log_warn "Failed to push ${ref}"
    fi
  done

  # Clean up the crane pod
  kubectl delete pod "$pod_name" -n default --ignore-not-found 2>/dev/null || true

  if [[ "$push_count" -gt 0 ]]; then
    # Trigger rollout restart so pods pick up the newly available images
    kubectl rollout restart deployment/node-labeler -n node-labeler 2>/dev/null || true
    kubectl rollout restart deployment/storage-autoscaler -n storage-autoscaler 2>/dev/null || true
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
