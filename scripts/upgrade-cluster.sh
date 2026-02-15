#!/usr/bin/env bash
# =============================================================================
# upgrade-cluster.sh — Rolling Kubernetes Version Upgrade via Terraform/Rancher
# =============================================================================
# Updates the kubernetes_version in terraform.tfvars and applies via Terraform.
# Rancher then orchestrates a rolling upgrade of all nodes (control plane first,
# then workers) with the upgrade_strategy defined in cluster.tf.
#
# Usage:
#   ./scripts/upgrade-cluster.sh                     # List available versions
#   ./scripts/upgrade-cluster.sh v1.34.2+rke2r3      # Upgrade to specific version
#   ./scripts/upgrade-cluster.sh --check             # Show current vs available
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# -----------------------------------------------------------------------------
# CLI Argument Parsing
# -----------------------------------------------------------------------------
ACTION="upgrade"
TARGET_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)     ACTION="check"; shift ;;
    --list)      ACTION="list"; shift ;;
    -h|--help)
      echo "Usage: $0 [--check] [--list] [VERSION]"
      echo ""
      echo "  --check       Show current version and available upgrades"
      echo "  --list        List all available RKE2 versions from Rancher"
      echo "  VERSION       Target version (e.g., v1.34.2+rke2r3)"
      echo ""
      echo "Examples:"
      echo "  $0 --check"
      echo "  $0 --list"
      echo "  $0 v1.34.2+rke2r3"
      exit 0
      ;;
    *)
      TARGET_VERSION="$1"; shift ;;
  esac
done

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
get_current_version() {
  awk -F'"' '/^kubernetes_version[[:space:]]/ {print $2}' "${CLUSTER_DIR}/terraform.tfvars"
}

list_available_versions() {
  local rancher_url rancher_token
  rancher_url=$(get_rancher_url)
  rancher_token=$(get_rancher_token)

  curl -sk "${rancher_url}/v1/management.cattle.io.settings/rke2-default-version" \
    -H "Authorization: Bearer ${rancher_token}" 2>/dev/null | jq -r '.value // empty'
}

list_all_versions() {
  local rancher_url rancher_token
  rancher_url=$(get_rancher_url)
  rancher_token=$(get_rancher_token)

  # Fetch available RKE2 versions from Rancher
  local versions
  versions=$(curl -sk "${rancher_url}/v1/management.cattle.io.settings" \
    -H "Authorization: Bearer ${rancher_token}" 2>/dev/null \
    | jq -r '.data[] | select(.id | test("rke2")) | select(.value != null and .value != "") | "\(.id): \(.value)"' 2>/dev/null || echo "")

  if [[ -z "$versions" ]]; then
    # Fallback: query the kontainer-driver-metadata for RKE2 releases
    curl -sk "${rancher_url}/v1/rke-k8s-service-options" \
      -H "Authorization: Bearer ${rancher_token}" 2>/dev/null \
      | jq -r '.data[].id' 2>/dev/null | grep "rke2" | sort -V || echo "(no versions found)"
  else
    echo "$versions"
  fi
}

get_node_versions() {
  local kubeconfig="${CLUSTER_DIR}/kubeconfig-rke2.yaml"
  if [[ ! -f "$kubeconfig" ]]; then
    log_warn "Kubeconfig not found: ${kubeconfig}"
    return 1
  fi
  kubectl --kubeconfig="$kubeconfig" get nodes \
    -o custom-columns=NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,ROLES:.metadata.labels.node-role\\.kubernetes\\.io/control-plane \
    --sort-by=.metadata.name 2>/dev/null
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------

cmd_check() {
  local current
  current=$(get_current_version)

  echo -e "${BOLD}Current Kubernetes Version${NC}"
  echo "  terraform.tfvars: ${current}"
  echo ""

  echo -e "${BOLD}Node Versions${NC}"
  get_node_versions || echo "  (cluster not reachable)"
  echo ""

  echo -e "${BOLD}Rancher Default RKE2 Version${NC}"
  local default_ver
  default_ver=$(list_available_versions)
  echo "  ${default_ver:-unknown}"
}

cmd_list() {
  echo -e "${BOLD}Available RKE2 Versions (from Rancher)${NC}"
  list_all_versions
}

cmd_upgrade() {
  local current target
  current=$(get_current_version)
  target="$TARGET_VERSION"

  if [[ -z "$target" ]]; then
    die "No target version specified. Usage: $0 VERSION"
  fi

  # Validate format
  if ! echo "$target" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+\+rke2r[0-9]+$'; then
    die "Invalid version format: ${target}. Expected: v1.34.2+rke2r3"
  fi

  if [[ "$current" == "$target" ]]; then
    log_ok "Already at version ${target} — nothing to do"
    exit 0
  fi

  echo -e "${BOLD}Kubernetes Version Upgrade${NC}"
  echo "  Current: ${current}"
  echo "  Target:  ${target}"
  echo ""

  # Update terraform.tfvars
  log_step "Updating terraform.tfvars..."
  sed -i "s|^kubernetes_version.*|kubernetes_version = \"${target}\"|" "${CLUSTER_DIR}/terraform.tfvars"
  log_ok "terraform.tfvars updated: kubernetes_version = \"${target}\""

  # Also update variables.tf default to keep them in sync
  sed -i "s|default     = \"v[0-9]\+\.[0-9]\+\.[0-9]\++rke2r[0-9]\+\"|default     = \"${target}\"|" "${CLUSTER_DIR}/variables.tf"
  log_ok "variables.tf default updated"

  # Run terraform apply via terraform.sh
  log_step "Running terraform apply to trigger rolling upgrade..."
  cd "${CLUSTER_DIR}"
  ./terraform.sh apply

  log_ok "Terraform apply completed — Rancher is now rolling out the upgrade"
  echo ""
  echo -e "${YELLOW}Rancher will upgrade nodes using the strategy:${NC}"
  echo "  - Control plane: 1 at a time"
  echo "  - Workers: 1 at a time"
  echo ""
  echo "Monitor progress:"
  echo "  kubectl --kubeconfig=${CLUSTER_DIR}/kubeconfig-rke2.yaml get nodes -w"
  echo ""

  # Wait and show node versions
  log_step "Waiting 30s for upgrade to begin..."
  sleep 30
  echo ""
  echo -e "${BOLD}Current Node Versions${NC}"
  get_node_versions || log_warn "Cluster may be temporarily unreachable during upgrade"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
check_prerequisites

case "$ACTION" in
  check)   cmd_check ;;
  list)    cmd_list ;;
  upgrade) cmd_upgrade ;;
esac
