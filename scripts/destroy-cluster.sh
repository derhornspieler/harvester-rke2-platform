#!/usr/bin/env bash
# =============================================================================
# destroy-cluster.sh — Full RKE2 Cluster Teardown
# =============================================================================
# Cleanly destroys the RKE2 cluster and removes orphaned Harvester resources:
#   Terraform destroy → Wait for CAPI/VM cleanup → Remove stuck finalizers
#   → Delete orphaned DataVolumes/PVCs → Verify namespace is clean
#
# Why this exists:
#   terraform destroy only deletes Rancher-managed resources. The actual VM
#   teardown is async via CAPI, and often leaves behind stuck VMs and orphaned
#   PVCs on Harvester due to finalizer races and credential deletion timing.
#
# Prerequisites:
#   1. cluster/terraform.tfvars populated
#   2. Harvester kubeconfig reachable
#   3. Commands: terraform, kubectl, jq
#
# Usage:
#   ./scripts/destroy-cluster.sh              # Full destroy (prompts for confirmation)
#   ./scripts/destroy-cluster.sh --auto       # Skip confirmation prompt
#   ./scripts/destroy-cluster.sh --skip-tf    # Skip Terraform (only Harvester cleanup)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# -----------------------------------------------------------------------------
# CLI Argument Parsing
# -----------------------------------------------------------------------------
SKIP_TERRAFORM=false
AUTO_APPROVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tf)    SKIP_TERRAFORM=true; shift ;;
    --auto)       AUTO_APPROVE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--auto] [--skip-tf]"
      echo "  --auto       Skip confirmation prompt (add -auto-approve to terraform)"
      echo "  --skip-tf    Skip Terraform destroy (only clean up Harvester orphans)"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# =============================================================================
# PHASE 0: PRE-FLIGHT
# =============================================================================
phase_0_preflight() {
  start_phase "PHASE 0: PRE-FLIGHT CHECKS"

  check_prerequisites
  check_tfvars

  # Load credentials (for HARVESTER_CONTEXT)
  generate_or_load_env

  # Ensure Harvester kubeconfig is available
  ensure_harvester_kubeconfig

  local cluster_name vm_ns
  cluster_name=$(get_cluster_name)
  vm_ns=$(get_vm_namespace)

  log_info "Cluster name:    ${cluster_name}"
  log_info "VM namespace:    ${vm_ns}"
  log_info "Skip Terraform:  ${SKIP_TERRAFORM}"
  log_info "Auto approve:    ${AUTO_APPROVE}"

  if [[ "$AUTO_APPROVE" != "true" ]]; then
    echo ""
    echo -e "${RED}${BOLD}  WARNING: This will DESTROY the entire RKE2 cluster '${cluster_name}'${NC}"
    echo -e "${RED}${BOLD}  All workloads, data, and secrets in the cluster will be PERMANENTLY LOST.${NC}"
    echo ""
    read -rp "  Type the cluster name to confirm: " confirm
    if [[ "$confirm" != "$cluster_name" ]]; then
      die "Confirmation failed. Aborting."
    fi
  fi

  end_phase "PHASE 0: PRE-FLIGHT"
}

# =============================================================================
# PHASE 1: TERRAFORM DESTROY
# =============================================================================
phase_1_terraform() {
  start_phase "PHASE 1: TERRAFORM DESTROY"

  local cluster_name
  cluster_name=$(get_cluster_name)

  # Push secrets first (ensure Harvester has latest state backup)
  log_step "Backing up secrets to Harvester..."
  cd "${CLUSTER_DIR}"
  ./terraform.sh push-secrets

  # Run terraform destroy
  log_step "Running terraform destroy..."
  cd "${CLUSTER_DIR}"
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    ./terraform.sh destroy -auto-approve
  else
    ./terraform.sh destroy
  fi

  log_ok "Terraform destroy completed"
  end_phase "PHASE 1: TERRAFORM DESTROY"
}

# =============================================================================
# PHASE 2: HARVESTER CLEANUP
# =============================================================================
phase_2_harvester_cleanup() {
  start_phase "PHASE 2: HARVESTER ORPHAN CLEANUP"

  local cluster_name vm_ns
  cluster_name=$(get_cluster_name)
  vm_ns=$(get_vm_namespace)
  local hk="kubectl --kubeconfig=${CLUSTER_DIR}/kubeconfig-harvester.yaml"

  # --- 2.1 Wait for VMs to be deleted (async CAPI teardown) ---
  log_step "Waiting for VMs to be cleaned up by CAPI..."
  local timeout=300 interval=10 elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local vm_count
    vm_count=$($hk get virtualmachines.kubevirt.io -n "$vm_ns" --no-headers 2>/dev/null \
      | grep -c "^${cluster_name}-" || true)

    if [[ "$vm_count" -eq 0 ]]; then
      log_ok "All cluster VMs deleted"
      break
    fi

    log_info "  ${vm_count} VM(s) still deleting (${elapsed}s/${timeout}s)..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  # --- 2.2 Remove stuck finalizers on VMs ---
  local stuck_vms
  stuck_vms=$($hk get virtualmachines.kubevirt.io -n "$vm_ns" \
    --no-headers -o name 2>/dev/null | grep "${cluster_name}" || true)

  if [[ -n "$stuck_vms" ]]; then
    log_warn "Removing stuck finalizers from remaining VMs..."
    while IFS= read -r vm; do
      [[ -z "$vm" ]] && continue
      $hk patch "$vm" -n "$vm_ns" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      log_info "  Patched: ${vm}"
    done <<< "$stuck_vms"
    sleep 10
  fi

  # --- 2.3 Remove stuck VMIs ---
  local stuck_vmis
  stuck_vmis=$($hk get virtualmachineinstances.kubevirt.io -n "$vm_ns" \
    --no-headers -o name 2>/dev/null | grep "${cluster_name}" || true)

  if [[ -n "$stuck_vmis" ]]; then
    log_warn "Removing stuck VirtualMachineInstances..."
    while IFS= read -r vmi; do
      [[ -z "$vmi" ]] && continue
      $hk patch "$vmi" -n "$vm_ns" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $hk delete "$vmi" -n "$vm_ns" --wait=false 2>/dev/null || true
    done <<< "$stuck_vmis"
    sleep 5
  fi

  # --- 2.4 Delete orphaned DataVolumes ---
  local orphan_dvs
  orphan_dvs=$($hk get datavolumes.cdi.kubevirt.io -n "$vm_ns" \
    --no-headers -o name 2>/dev/null | grep "${cluster_name}" || true)

  if [[ -n "$orphan_dvs" ]]; then
    local dv_count
    dv_count=$(echo "$orphan_dvs" | wc -l | tr -d ' ')
    log_warn "Found ${dv_count} orphaned DataVolume(s) — deleting..."
    while IFS= read -r dv; do
      [[ -z "$dv" ]] && continue
      $hk patch "$dv" -n "$vm_ns" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $hk delete "$dv" -n "$vm_ns" --wait=false 2>/dev/null || true
    done <<< "$orphan_dvs"
    sleep 5
  fi

  # --- 2.5 Delete orphaned PVCs ---
  log_step "Cleaning up orphaned PVCs..."
  local all_pvcs
  all_pvcs=$($hk get pvc -n "$vm_ns" --no-headers -o name 2>/dev/null || true)

  if [[ -n "$all_pvcs" ]]; then
    local pvc_count
    pvc_count=$(echo "$all_pvcs" | wc -l | tr -d ' ')
    log_warn "Found ${pvc_count} PVC(s) in namespace '${vm_ns}' — deleting..."
    while IFS= read -r pvc; do
      [[ -z "$pvc" ]] && continue
      $hk patch "$pvc" -n "$vm_ns" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $hk delete "$pvc" -n "$vm_ns" --wait=false 2>/dev/null || true
      log_info "  Deleted: ${pvc}"
    done <<< "$all_pvcs"
  else
    log_ok "No orphaned PVCs found"
  fi

  # --- 2.6 Final verification ---
  sleep 5
  log_step "Verifying cleanup..."

  local remaining_vms remaining_pvcs
  remaining_vms=$($hk get virtualmachines.kubevirt.io -n "$vm_ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  remaining_pvcs=$($hk get pvc -n "$vm_ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$remaining_vms" -eq 0 && "$remaining_pvcs" -eq 0 ]]; then
    log_ok "Namespace '${vm_ns}' is clean — no VMs or PVCs remaining"
  else
    if [[ "$remaining_vms" -gt 0 ]]; then
      log_warn "${remaining_vms} VM(s) still present:"
      $hk get virtualmachines.kubevirt.io -n "$vm_ns" 2>/dev/null || true
    fi
    if [[ "$remaining_pvcs" -gt 0 ]]; then
      log_warn "${remaining_pvcs} PVC(s) still present:"
      $hk get pvc -n "$vm_ns" 2>/dev/null || true
    fi
  fi

  end_phase "PHASE 2: HARVESTER CLEANUP"
}

# =============================================================================
# PHASE 3: LOCAL CLEANUP
# =============================================================================
phase_3_local_cleanup() {
  start_phase "PHASE 3: LOCAL CLEANUP"

  # Remove generated kubeconfig for the destroyed cluster
  local rke2_kc="${CLUSTER_DIR}/kubeconfig-rke2.yaml"
  if [[ -f "$rke2_kc" ]]; then
    rm -f "$rke2_kc"
    log_ok "Removed RKE2 kubeconfig: ${rke2_kc}"
  fi

  # Remove credentials file
  local creds="${CLUSTER_DIR}/credentials.txt"
  if [[ -f "$creds" ]]; then
    rm -f "$creds"
    log_ok "Removed credentials file: ${creds}"
  fi

  log_info "Preserved files (reusable for next deploy):"
  log_info "  - cluster/terraform.tfvars"
  log_info "  - cluster/kubeconfig-harvester.yaml"
  log_info "  - cluster/kubeconfig-harvester-cloud-cred.yaml"
  log_info "  - cluster/harvester-cloud-provider-kubeconfig"
  log_info "  - scripts/.env"

  end_phase "PHASE 3: LOCAL CLEANUP"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo -e "${BOLD}${RED}"
  echo "  ____  _  _______ ____    ____            _                   "
  echo " |  _ \\| |/ / ____|___ \\  |  _ \\  ___  ___| |_ _ __ ___  _   _"
  echo " | |_) | ' /|  _|   __) | | | | |/ _ \\/ __| __| '__/ _ \\| | | |"
  echo " |  _ <| . \\| |___ / __/  | |_| |  __/\\__ \\ |_| | | (_) | |_| |"
  echo " |_| \\_\\_|\\_\\_____|_____| |____/ \\___||___/\\__|_|  \\___/ \\__, |"
  echo "                                                         |___/ "
  echo -e "${NC}"
  echo ""

  DEPLOY_START_TIME=$(date +%s)
  export DEPLOY_START_TIME

  phase_0_preflight

  if [[ "$SKIP_TERRAFORM" == "false" ]]; then
    phase_1_terraform
  else
    log_info "Skipping Terraform destroy (--skip-tf)"
  fi

  phase_2_harvester_cleanup
  phase_3_local_cleanup

  echo ""
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo -e "${BOLD}${GREEN}  CLUSTER DESTROYED SUCCESSFULLY${NC}"
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo ""
  echo -e "  To redeploy: ${CYAN}./scripts/deploy-cluster.sh${NC}"
  echo ""

  print_total_time
}

main "$@"
