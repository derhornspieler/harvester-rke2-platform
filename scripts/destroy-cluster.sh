#!/usr/bin/env bash
# =============================================================================
# destroy-cluster.sh — Full RKE2 Cluster Teardown
# =============================================================================
# Cleanly destroys the RKE2 cluster and removes orphaned Harvester resources:
#   K8s workload cleanup (GitLab, Redis, CNPG) → Terraform destroy →
#   Wait for CAPI/VM cleanup → Remove stuck finalizers →
#   Delete orphaned DataVolumes/PVCs → Verify namespace is clean
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
#   ./scripts/destroy-cluster.sh --dirty      # Recover from a cancelled/failed deploy
#
# Flags:
#   --auto       Skip the interactive confirmation prompt. Passes -auto-approve
#                to terraform destroy.
#   --skip-tf    Skip the Terraform destroy phase entirely. Useful when Terraform
#                state is already empty and you only need Harvester orphan cleanup.
#   --dirty      Clean up after a cancelled or failed deploy/destroy. In addition
#                to the normal teardown, this purges orphaned CAPI resources
#                (machines, clusters, control planes) and stale cloud credentials
#                from the vcluster Rancher that Terraform doesn't know about.
#                Use this when: a deploy was Ctrl-C'd mid-Terraform, a previous
#                destroy failed to save state, or the Rancher UI still shows a
#                ghost cluster after a normal destroy.
#
# Combining flags:
#   ./scripts/destroy-cluster.sh --auto --dirty   # Non-interactive dirty cleanup
#   ./scripts/destroy-cluster.sh --skip-tf --dirty # Skip TF, clean CAPI + Harvester
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# -----------------------------------------------------------------------------
# CLI Argument Parsing
# -----------------------------------------------------------------------------
SKIP_TERRAFORM=false
AUTO_APPROVE=false
DIRTY_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tf)    SKIP_TERRAFORM=true; shift ;;
    --auto)       AUTO_APPROVE=true; shift ;;
    --dirty)      DIRTY_MODE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--auto] [--skip-tf] [--dirty]"
      echo ""
      echo "Flags:"
      echo "  --auto       Skip confirmation prompt (add -auto-approve to terraform)"
      echo "  --skip-tf    Skip Terraform destroy (only clean up Harvester orphans)"
      echo "  --dirty      Recover from a cancelled/failed deploy. Cleans up orphaned"
      echo "               CAPI resources and stale cloud credentials from vcluster"
      echo "               Rancher that a normal destroy can't reach."
      echo ""
      echo "Examples:"
      echo "  $0                        # Normal destroy (interactive)"
      echo "  $0 --auto                 # Normal destroy (non-interactive)"
      echo "  $0 --auto --dirty         # Recover from failed deploy"
      echo "  $0 --skip-tf --dirty      # Skip Terraform, clean CAPI + Harvester"
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
  log_info "Dirty mode:      ${DIRTY_MODE}"

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
# PHASE 1: CLEAN UP K8S WORKLOADS (graceful shutdown before infra destroy)
# =============================================================================
phase_1_k8s_cleanup() {
  start_phase "PHASE 1: K8S WORKLOAD CLEANUP"

  local rke2_kc="${CLUSTER_DIR}/kubeconfig-rke2.yaml"
  if [[ ! -f "$rke2_kc" ]]; then
    log_warn "RKE2 kubeconfig not found — skipping K8s cleanup"
    end_phase "PHASE 1: K8S WORKLOAD CLEANUP"
    return 0
  fi

  export KUBECONFIG="$rke2_kc"

  # Check if cluster is reachable
  if ! kubectl cluster-info &>/dev/null 2>&1; then
    log_warn "RKE2 cluster not reachable — skipping K8s cleanup"
    end_phase "PHASE 1: K8S WORKLOAD CLEANUP"
    return 0
  fi

  # GitLab: uninstall Helm release and clean up resources
  if helm status gitlab -n gitlab &>/dev/null 2>&1; then
    log_step "Uninstalling GitLab Helm release..."
    helm uninstall gitlab -n gitlab --timeout 5m 2>/dev/null || \
      log_warn "GitLab Helm uninstall had issues (non-fatal)"
  fi

  # Delete GitLab Redis CRs (before operator goes away)
  if kubectl get redisreplication gitlab-redis -n gitlab &>/dev/null 2>&1; then
    log_step "Deleting GitLab Redis resources..."
    kubectl delete redissentinel gitlab-redis -n gitlab --timeout=60s 2>/dev/null || true
    kubectl delete redisreplication gitlab-redis -n gitlab --timeout=60s 2>/dev/null || true
  fi

  # Delete GitLab CNPG cluster (graceful shutdown of PostgreSQL)
  if kubectl get cluster gitlab-postgresql -n database &>/dev/null 2>&1; then
    log_step "Deleting GitLab PostgreSQL cluster..."
    kubectl delete cluster gitlab-postgresql -n database --timeout=120s 2>/dev/null || true
  fi

  # Delete GitLab namespace (waits for finalizers)
  if kubectl get namespace gitlab &>/dev/null 2>&1; then
    log_step "Deleting gitlab namespace..."
    kubectl delete namespace gitlab --timeout=120s 2>/dev/null || \
      log_warn "gitlab namespace deletion timed out (non-fatal)"
  fi

  log_ok "K8s workload cleanup complete"
  end_phase "PHASE 1: K8S WORKLOAD CLEANUP"
}

# =============================================================================
# PHASE 2: TERRAFORM DESTROY
# =============================================================================
phase_2_terraform() {
  start_phase "PHASE 2: TERRAFORM DESTROY"

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
  end_phase "PHASE 2: TERRAFORM DESTROY"
}

# =============================================================================
# PHASE 3: HARVESTER CLEANUP
# =============================================================================
phase_3_harvester_cleanup() {
  start_phase "PHASE 3: HARVESTER ORPHAN CLEANUP"

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

  local rancher_url rancher_token
  rancher_url=$(get_rancher_url)
  rancher_token=$(get_rancher_token)

  # --- 2.7 Clean up stuck CAPI resources in vcluster Rancher (--dirty only) ---
  # When a deploy is cancelled mid-Terraform or the destroy can't save state,
  # CAPI resources (machines, clusters, control planes) get orphaned in the
  # vcluster Rancher's fleet-default namespace with stuck finalizers. These
  # block the next deploy from creating a cluster with the same name.
  if [[ "$DIRTY_MODE" == "true" ]]; then
    log_step "Cleaning up stuck CAPI resources in Rancher (--dirty)..."

    local capi_types=(
      "rke-machine.cattle.io.harvestermachines"
      "cluster.x-k8s.io.machines"
      "rke.cattle.io.rkecontrolplanes"
      "cluster.x-k8s.io.clusters"
    )
    local capi_total=0
    for rtype in "${capi_types[@]}"; do
      local items
      items=$(curl -sk -H "Authorization: Bearer ${rancher_token}" \
        "${rancher_url}/v1/${rtype}/fleet-default" 2>/dev/null \
        | jq -r ".data[]? | select(.metadata.name | test(\"${cluster_name}\")) | .id" 2>/dev/null || true)
      [[ -z "$items" ]] && continue
      while IFS= read -r item_id; do
        [[ -z "$item_id" ]] && continue
        # Remove finalizers first
        curl -sk -X PUT -H "Authorization: Bearer ${rancher_token}" \
          -H "Content-Type: application/json" \
          "${rancher_url}/v1/${rtype}/${item_id}" \
          -d "$(curl -sk -H "Authorization: Bearer ${rancher_token}" \
            "${rancher_url}/v1/${rtype}/${item_id}" 2>/dev/null \
            | jq '.metadata.finalizers = []')" >/dev/null 2>&1 || true
        # Then delete
        curl -sk -X DELETE -H "Authorization: Bearer ${rancher_token}" \
          "${rancher_url}/v1/${rtype}/${item_id}" >/dev/null 2>&1 || true
        log_info "  Cleaned: ${rtype}/${item_id##*/}"
        capi_total=$((capi_total + 1))
      done <<< "$items"
    done
    if [[ "$capi_total" -gt 0 ]]; then
      log_ok "Cleaned up ${capi_total} stuck CAPI resource(s)"
      sleep 5
    else
      log_ok "No stuck CAPI resources found"
    fi
  fi

  # --- 2.8 Clean up stale Rancher machine secrets in fleet-default ---
  # terraform destroy removes the cluster resource but machine-plan, machine-state,
  # and machine-driver-secret objects linger in the Rancher Steve API.  These stale
  # secrets block Rancher from provisioning a new cluster with the same name.
  log_step "Cleaning up stale Rancher machine secrets..."

  local stale_count=0
  for _pass in 1 2 3; do
    local stale_secrets
    stale_secrets=$(curl -sk -H "Authorization: Bearer ${rancher_token}" \
      "${rancher_url}/v1/secrets/fleet-default" 2>/dev/null \
      | jq -r ".data[]? | select(.metadata.name | test(\"${cluster_name}\")) | .metadata.name" 2>/dev/null)
    [[ -z "$stale_secrets" ]] && break
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      curl -sk -X DELETE -H "Authorization: Bearer ${rancher_token}" \
        "${rancher_url}/v1/secrets/fleet-default/${s}" >/dev/null 2>&1 || true
      stale_count=$((stale_count + 1))
    done <<< "$stale_secrets"
    sleep 2
  done
  if [[ "$stale_count" -gt 0 ]]; then
    log_ok "Cleaned up ${stale_count} stale Rancher machine secret(s)"
  else
    log_ok "No stale Rancher machine secrets found"
  fi

  # --- 2.9 Clean up orphaned cloud credential secrets (--dirty only) ---
  # When a deploy fails mid-way or terraform destroy can't save state, old
  # cloud credential secrets (cc-*) linger in cattle-global-data. If they
  # reference the same Rancher token as the harvester kubeconfig, the next
  # terraform apply fails with "token is already in use by secret".
  if [[ "$DIRTY_MODE" == "true" ]]; then
    log_step "Cleaning up orphaned cloud credential secrets (--dirty)..."
    local cc_secrets
    cc_secrets=$(curl -sk -H "Authorization: Bearer ${rancher_token}" \
      "${rancher_url}/v1/secrets/cattle-global-data" 2>/dev/null \
      | jq -r '.data[]? | select(.metadata.name | test("^cc-")) | .metadata.name' 2>/dev/null || true)

    local cc_count=0
    if [[ -n "$cc_secrets" ]]; then
      while IFS= read -r cc; do
        [[ -z "$cc" ]] && continue
        # Check if this cloud credential references our cluster
        local cc_cluster_id
        cc_cluster_id=$(curl -sk -H "Authorization: Bearer ${rancher_token}" \
          "${rancher_url}/v1/secrets/cattle-global-data/${cc}" 2>/dev/null \
          | jq -r '.data["harvestercredentialConfig-clusterId"] // empty' 2>/dev/null \
          | base64 -d 2>/dev/null || true)
        if [[ -n "$cc_cluster_id" ]]; then
          curl -sk -X DELETE -H "Authorization: Bearer ${rancher_token}" \
            "${rancher_url}/v1/secrets/cattle-global-data/${cc}" >/dev/null 2>&1 || true
          log_info "  Deleted orphaned cloud credential: ${cc} (cluster: ${cc_cluster_id})"
          cc_count=$((cc_count + 1))
        fi
      done <<< "$cc_secrets"
    fi
    if [[ "$cc_count" -gt 0 ]]; then
      log_ok "Cleaned up ${cc_count} orphaned cloud credential(s)"
    else
      log_ok "No orphaned cloud credentials found"
    fi
  fi

  end_phase "PHASE 3: HARVESTER CLEANUP"
}

# =============================================================================
# PHASE 4: LOCAL CLEANUP
# =============================================================================
phase_4_local_cleanup() {
  start_phase "PHASE 4: LOCAL CLEANUP"

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

  end_phase "PHASE 4: LOCAL CLEANUP"
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
  phase_1_k8s_cleanup

  if [[ "$SKIP_TERRAFORM" == "false" ]]; then
    phase_2_terraform
  else
    log_info "Skipping Terraform destroy (--skip-tf)"
  fi

  phase_3_harvester_cleanup
  phase_4_local_cleanup

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
