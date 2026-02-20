#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# build.sh — Golden Image Build Orchestrator
# =============================================================================
# Creates a pre-baked Rocky 9 qcow2 with all static RKE2 node config using
# virt-customize inside a temporary Harvester utility VM.
#
# Usage:
#   ./build.sh build             Full lifecycle: create -> wait -> import -> cleanup
#   ./build.sh list              Show existing golden images in Harvester
#   ./build.sh delete <name>     Delete an old golden image
#   ./build.sh destroy           Manual cleanup if build fails mid-way
# =============================================================================

# --- Colors & Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

die() {
  log_error "$@"
  exit 1
}

# --- Constants ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$(cd "${SCRIPT_DIR}/../cluster" 2>/dev/null && pwd || echo "")"
HARVESTER_KUBECONFIG="${SCRIPT_DIR}/kubeconfig-harvester.yaml"
KUBECTL="kubectl --kubeconfig=${HARVESTER_KUBECONFIG}"
IMAGE_DATE=$(date +%Y%m%d)
CHECK_POD_NAME="golden-build-check"
_BUILD_VM_NAMESPACE=""   # set by cmd_build(), used by EXIT trap

# --- Helper Functions ---

check_prerequisites() {
  local missing=()
  for cmd in kubectl terraform jq; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
  log_ok "Prerequisites found: kubectl, terraform, jq"
}

ensure_kubeconfig() {
  if [[ -f "$HARVESTER_KUBECONFIG" ]]; then
    log_ok "Harvester kubeconfig found: ${HARVESTER_KUBECONFIG}"
    return 0
  fi

  # Try copying from cluster/ directory
  if [[ -n "$CLUSTER_DIR" && -f "${CLUSTER_DIR}/kubeconfig-harvester.yaml" ]]; then
    cp "${CLUSTER_DIR}/kubeconfig-harvester.yaml" "$HARVESTER_KUBECONFIG"
    chmod 600 "$HARVESTER_KUBECONFIG"
    log_ok "Copied kubeconfig from cluster/ directory"
    return 0
  fi

  die "Harvester kubeconfig not found at ${HARVESTER_KUBECONFIG}\n  Copy from cluster/ or place it manually."
}

check_connectivity() {
  if ! $KUBECTL cluster-info &>/dev/null; then
    die "Cannot connect to Harvester cluster via ${HARVESTER_KUBECONFIG}"
  fi
  log_ok "Harvester cluster is reachable"
}

# Extract a quoted tfvars value by variable name
_get_tfvar() {
  awk -F'"' "/^${1}[[:space:]]/ {print \$2}" "${SCRIPT_DIR}/terraform.tfvars" 2>/dev/null || echo ""
}

get_image_name() {
  local prefix
  prefix=$(_get_tfvar image_name_prefix)
  [[ -z "$prefix" ]] && prefix="rke2-rocky9-golden"
  echo "${prefix}-${IMAGE_DATE}"
}

get_vm_namespace() {
  local ns
  ns=$(_get_tfvar vm_namespace)
  [[ -z "$ns" ]] && die "vm_namespace not set in terraform.tfvars"
  echo "$ns"
}

# Deploy a temporary curl pod on Harvester (same network as VM)
deploy_check_pod() {
  local ns="$1"
  $KUBECTL delete pod "$CHECK_POD_NAME" -n "$ns" --ignore-not-found 2>/dev/null || true
  $KUBECTL run "$CHECK_POD_NAME" -n "$ns" --restart=Never \
    --image=curlimages/curl -- sleep 3600 2>/dev/null
  $KUBECTL wait --for=condition=ready "pod/${CHECK_POD_NAME}" -n "$ns" \
    --timeout=120s 2>/dev/null || die "Check pod did not become ready"
  log_ok "Check pod deployed on Harvester"
}

# Poll VM readiness via the in-cluster check pod
check_vm_ready() {
  local ns="$1"
  local vm_ip="$2"
  $KUBECTL exec -n "$ns" "$CHECK_POD_NAME" -- \
    curl -sf --max-time 5 "http://${vm_ip}:8080/ready" &>/dev/null
}

# Clean up the check pod
cleanup_check_pod() {
  local ns="$1"
  $KUBECTL delete pod "$CHECK_POD_NAME" -n "$ns" --ignore-not-found 2>/dev/null || true
}

# --- Build Command ---

cmd_build() {
  local start_time
  start_time=$(date +%s)

  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BOLD}${BLUE}  Golden Image Build${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo ""

  check_prerequisites
  ensure_kubeconfig
  check_connectivity

  local image_name
  image_name=$(get_image_name)
  # Use global so the EXIT trap can reference it after cmd_build() returns
  _BUILD_VM_NAMESPACE=$(get_vm_namespace)
  local vm_namespace="$_BUILD_VM_NAMESPACE"

  # Check for existing image with same name
  if $KUBECTL get virtualmachineimages.harvesterhci.io "${image_name}" -n "${vm_namespace}" &>/dev/null; then
    die "Image '${image_name}' already exists. Use './build.sh delete ${image_name}' first, or wait until tomorrow."
  fi

  # Ensure cleanup on exit
  trap 'cleanup_check_pod "${_BUILD_VM_NAMESPACE}" 2>/dev/null || true' EXIT

  # -----------------------------------------------------------------------
  # Step 1/5: Terraform Apply
  # -----------------------------------------------------------------------
  log_step "Step 1/5: Creating base image + utility VM..."
  cd "$SCRIPT_DIR"

  terraform init -reconfigure -input=false

  terraform apply -auto-approve

  local vm_ip
  vm_ip=$(terraform output -raw utility_vm_ip 2>/dev/null || echo "")
  if [[ -z "$vm_ip" ]]; then
    die "Could not get utility VM IP from Terraform output"
  fi
  log_ok "Utility VM created at ${vm_ip}"

  # -----------------------------------------------------------------------
  # Step 2/5: Wait for HTTP ready (via in-cluster check pod)
  # -----------------------------------------------------------------------
  log_step "Step 2/5: Waiting for golden image build to complete..."
  log_info "Deploying check pod on Harvester (operator machine may not reach VM network)..."
  deploy_check_pod "$vm_namespace"

  local timeout=1800 interval=15 elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    if check_vm_ready "$vm_namespace" "$vm_ip"; then
      log_ok "Golden image build complete"
      break
    fi
    if [[ $((elapsed % 60)) -eq 0 && $elapsed -gt 0 ]]; then
      log_info "  Still building... (${elapsed}s / ${timeout}s)"
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  cleanup_check_pod "$vm_namespace"

  if [[ $elapsed -ge $timeout ]]; then
    log_error "Timeout waiting for golden image build (${timeout}s)"
    log_error "Debug: ssh rocky@${vm_ip} 'cat /var/log/build-golden.log' (from a host on the VM network)"
    die "Build timed out. Run './build.sh destroy' to clean up."
  fi

  # -----------------------------------------------------------------------
  # Step 3/5: Import golden image into Harvester
  # -----------------------------------------------------------------------
  log_step "Step 3/5: Importing golden image into Harvester..."

  $KUBECTL apply -f - <<VMIMAGE
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: ${image_name}
  namespace: ${vm_namespace}
spec:
  displayName: "${image_name}"
  sourceType: download
  url: "http://${vm_ip}:8080/golden.qcow2"
  storageClassParameters:
    migratable: "true"
    numberOfReplicas: "3"
    staleReplicaTimeout: "30"
VMIMAGE

  log_ok "VirtualMachineImage CRD applied: ${image_name}"

  # -----------------------------------------------------------------------
  # Step 4/5: Wait for image import
  # -----------------------------------------------------------------------
  log_step "Step 4/5: Waiting for Harvester to import image..."
  local import_timeout=600 import_elapsed=0

  while [[ $import_elapsed -lt $import_timeout ]]; do
    local progress
    progress=$($KUBECTL get virtualmachineimages.harvesterhci.io "${image_name}" \
      -n "${vm_namespace}" -o jsonpath='{.status.progress}' 2>/dev/null || echo "0")

    local conditions
    conditions=$($KUBECTL get virtualmachineimages.harvesterhci.io "${image_name}" \
      -n "${vm_namespace}" -o jsonpath='{.status.conditions}' 2>/dev/null || echo "")

    # Check if import is complete (Imported condition = True)
    if echo "$conditions" | jq -e '.[] | select(.type=="Imported" and .status=="True")' &>/dev/null; then
      log_ok "Image import complete: ${image_name}"
      break
    fi

    log_info "  Import progress: ${progress}% (${import_elapsed}s / ${import_timeout}s)"
    sleep 15
    import_elapsed=$((import_elapsed + 15))
  done

  if [[ $import_elapsed -ge $import_timeout ]]; then
    log_warn "Image import may still be in progress (${import_timeout}s timeout reached)"
    log_info "Check status: kubectl get virtualmachineimages ${image_name} -n ${vm_namespace}"
  fi

  # -----------------------------------------------------------------------
  # Step 5/5: Cleanup — destroy utility VM
  # -----------------------------------------------------------------------
  log_step "Step 5/5: Cleaning up utility VM..."
  cd "$SCRIPT_DIR"
  terraform destroy -auto-approve
  log_ok "Utility VM and base image cleaned up"

  # --- Summary ---
  local elapsed_total=$(( $(date +%s) - start_time ))
  local mins=$(( elapsed_total / 60 ))
  local secs=$(( elapsed_total % 60 ))

  echo ""
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo -e "${BOLD}${GREEN}  Golden Image Build Complete${NC}"
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo -e "${GREEN}  Image:     ${image_name}${NC}"
  echo -e "${GREEN}  Namespace: ${vm_namespace}${NC}"
  echo -e "${GREEN}  Time:      ${mins}m ${secs}s${NC}"
  echo ""
  echo -e "To use this image in your cluster, set in cluster/terraform.tfvars:"
  echo -e "  use_golden_image  = true"
  echo -e "  golden_image_name = \"${image_name}\""
  echo ""
}

# --- List Command ---

cmd_list() {
  ensure_kubeconfig
  check_connectivity

  local vm_namespace
  vm_namespace=$(get_vm_namespace)

  echo ""
  echo -e "${BOLD}Golden images in namespace '${vm_namespace}':${NC}"
  echo ""

  $KUBECTL get virtualmachineimages.harvesterhci.io -n "${vm_namespace}" \
    --no-headers -o custom-columns=\
'NAME:.metadata.name,DISPLAY:.spec.displayName,SIZE:.status.size,PROGRESS:.status.progress,AGE:.metadata.creationTimestamp' \
    2>/dev/null | grep "rke2-rocky9-golden" || echo "  (no golden images found)"

  echo ""
}

# --- Delete Command ---

cmd_delete() {
  local image_name="${1:-}"
  if [[ -z "$image_name" ]]; then
    die "Usage: ./build.sh delete <image-name>\n  Run './build.sh list' to see available images."
  fi

  ensure_kubeconfig
  check_connectivity

  local vm_namespace
  vm_namespace=$(get_vm_namespace)

  if ! $KUBECTL get virtualmachineimages.harvesterhci.io "${image_name}" -n "${vm_namespace}" &>/dev/null; then
    die "Image '${image_name}' not found in namespace '${vm_namespace}'"
  fi

  log_info "Deleting golden image: ${image_name}..."
  $KUBECTL delete virtualmachineimages.harvesterhci.io "${image_name}" -n "${vm_namespace}"
  log_ok "Image '${image_name}' deleted"
}

# --- Destroy Command (manual cleanup) ---

cmd_destroy() {
  log_info "Running terraform destroy for manual cleanup..."
  ensure_kubeconfig

  cd "$SCRIPT_DIR"
  terraform init -reconfigure -input=false

  terraform destroy "$@"
  log_ok "Cleanup complete"
}

# --- Main ---

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args...]

Golden Image Build System — Pre-bakes Rocky 9 with RKE2 node config

Commands:
  build              Full lifecycle: create -> wait -> import -> cleanup
  list               Show existing golden images in Harvester
  delete <name>      Delete an old golden image
  destroy            Manual cleanup if build fails mid-way

Examples:
  $(basename "$0") build
  $(basename "$0") list
  $(basename "$0") delete rke2-rocky9-golden-20260213
  $(basename "$0") destroy -auto-approve
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
  build)
    cmd_build
    ;;
  list)
    cmd_list
    ;;
  delete)
    cmd_delete "$@"
    ;;
  destroy)
    cmd_destroy "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    die "Unknown command: ${COMMAND}\n  Run '$(basename "$0") --help' for usage."
    ;;
esac
