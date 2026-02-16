#!/usr/bin/env bash
# =============================================================================
# deploy-cluster.sh — Full RKE2 Cluster Deployment (Zero Human Intervention)
# =============================================================================
# Deploys the entire stack from bare Harvester to fully operational cluster:
#   Terraform → cert-manager → CNPG → Redis Operator → Node Labeler → Vault
#   → Monitoring → Harbor → ArgoCD → Keycloak → Mattermost → Kasm
#   → Uptime Kuma → LibreNMS (optional) → RBAC → Validation
#   → Keycloak OIDC Setup → oauth2-proxy ForwardAuth → GitLab
#
# Prerequisites:
#   1. cluster/terraform.tfvars populated (see terraform.tfvars.example)
#   2. Harvester context in ~/.kube/config (name configurable via HARVESTER_CONTEXT in .env)
#   3. Commands: terraform, kubectl, helm, jq, openssl, curl
#
# Usage:
#   ./scripts/deploy-cluster.sh              # Full deployment
#   ./scripts/deploy-cluster.sh --skip-tf    # Skip Terraform (cluster exists)
#   ./scripts/deploy-cluster.sh --from 3     # Resume from phase 3
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# -----------------------------------------------------------------------------
# CLI Argument Parsing
# -----------------------------------------------------------------------------
SKIP_TERRAFORM=false
FROM_PHASE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tf)    SKIP_TERRAFORM=true; shift ;;
    --from)       FROM_PHASE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--skip-tf] [--from PHASE_NUMBER]"
      echo "  --skip-tf    Skip Terraform (assume cluster already exists)"
      echo "  --from N     Resume from phase N (0-11)"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# RKE2 kubeconfig path (generated in Phase 0, used by all subsequent phases)
RKE2_KUBECONFIG="${CLUSTER_DIR}/kubeconfig-rke2.yaml"

# If resuming from a later phase, kubeconfig must exist
if [[ $FROM_PHASE -gt 0 || "$SKIP_TERRAFORM" == "true" ]]; then
  if [[ ! -f "$RKE2_KUBECONFIG" ]]; then
    die "Resuming requires ${RKE2_KUBECONFIG} to exist. Run Phase 0 first."
  fi
  export KUBECONFIG="$RKE2_KUBECONFIG"
fi

# =============================================================================
# PHASE 0: TERRAFORM — RKE2 Cluster Provisioning
# =============================================================================
phase_0_terraform() {
  start_phase "PHASE 0: TERRAFORM — RKE2 Cluster Provisioning"

  check_tfvars
  ensure_external_files

  local cluster_name vm_ns
  cluster_name=$(get_cluster_name)
  vm_ns=$(get_vm_namespace)
  log_info "Cluster name: ${cluster_name}"

  # Clean up ALL orphaned resources from a previous cluster destroy.
  # terraform destroy deletes Rancher resources but Harvester-side VMs, DataVolumes,
  # and PVCs can linger due to stuck finalizers or async CAPI teardown races.
  log_step "Cleaning up orphaned Harvester resources from previous cluster..."
  local harvester_kubectl="kubectl --kubeconfig=${CLUSTER_DIR}/kubeconfig-harvester.yaml"

  # 0a. Stuck VMs — remove finalizers so they can be garbage collected
  local stuck_vms
  stuck_vms=$($harvester_kubectl get virtualmachines.kubevirt.io -n "$vm_ns" \
    --no-headers -o name 2>/dev/null | grep "${cluster_name}" || true)
  if [[ -n "$stuck_vms" ]]; then
    log_info "Removing stuck VMs from previous cluster..."
    while IFS= read -r vm; do
      [[ -z "$vm" ]] && continue
      $harvester_kubectl patch "$vm" -n "$vm_ns" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done <<< "$stuck_vms"
    sleep 5
  fi

  # 0b. Stuck VMIs
  local stuck_vmis
  stuck_vmis=$($harvester_kubectl get virtualmachineinstances.kubevirt.io -n "$vm_ns" \
    --no-headers -o name 2>/dev/null | grep "${cluster_name}" || true)
  if [[ -n "$stuck_vmis" ]]; then
    log_info "Removing stuck VMIs from previous cluster..."
    while IFS= read -r vmi; do
      [[ -z "$vmi" ]] && continue
      $harvester_kubectl patch "$vmi" -n "$vm_ns" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $harvester_kubectl delete "$vmi" -n "$vm_ns" --wait=false 2>/dev/null || true
    done <<< "$stuck_vmis"
    sleep 5
  fi

  # 0c. Orphaned DataVolumes
  local orphan_dvs
  orphan_dvs=$($harvester_kubectl get datavolumes.cdi.kubevirt.io -n "$vm_ns" \
    --no-headers -o name 2>/dev/null | grep "${cluster_name}" || true)
  if [[ -n "$orphan_dvs" ]]; then
    log_info "Removing orphaned DataVolumes..."
    while IFS= read -r dv; do
      [[ -z "$dv" ]] && continue
      $harvester_kubectl patch "$dv" -n "$vm_ns" --type=merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      $harvester_kubectl delete "$dv" -n "$vm_ns" --wait=false 2>/dev/null || true
    done <<< "$orphan_dvs"
    sleep 5
  fi

  # 0d. Orphaned PVCs (VM disks AND workload PVCs)
  local orphan_pvcs
  orphan_pvcs=$($harvester_kubectl get pvc -n "$vm_ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$orphan_pvcs" -gt 0 ]]; then
    log_info "Found ${orphan_pvcs} orphaned PVC(s) — deleting..."
    $harvester_kubectl get pvc -n "$vm_ns" --no-headers 2>/dev/null | awk '{print $1}' | \
      while read -r pvc; do
        $harvester_kubectl patch "pvc/${pvc}" -n "$vm_ns" --type=merge \
          -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
        $harvester_kubectl delete "pvc/${pvc}" -n "$vm_ns" --wait=false 2>/dev/null || true
      done
    log_ok "Orphaned PVCs cleaned up"
  else
    log_info "No orphaned PVCs found"
  fi

  # Push fresh kubeconfigs to Harvester secrets BEFORE terraform
  # (terraform.sh pull-secrets runs before every command — ensure it pulls fresh versions)
  log_step "Syncing local files to Harvester secrets..."
  cd "${CLUSTER_DIR}"
  ./terraform.sh push-secrets

  # Terraform apply (pulls secrets → init → plan with saved file → apply → push secrets)
  log_step "Running terraform apply..."
  ./terraform.sh apply

  # Wait for cluster to become Active in Rancher
  wait_for_cluster_active "$cluster_name" 1800

  # Generate kubeconfig
  generate_kubeconfig "$cluster_name" "$RKE2_KUBECONFIG"
  export KUBECONFIG="$RKE2_KUBECONFIG"

  # Verify node connectivity
  log_step "Verifying cluster nodes..."
  local retries=0
  while ! kubectl get nodes &>/dev/null && [[ $retries -lt 30 ]]; do
    sleep 10
    retries=$((retries + 1))
  done

  kubectl get nodes -o wide
  local node_count
  node_count=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
  log_ok "Cluster has ${node_count} nodes"

  end_phase "PHASE 0: TERRAFORM"
}

# =============================================================================
# PHASE 1: CLUSTER FOUNDATION — No TLS Yet
# =============================================================================
phase_1_foundation() {
  start_phase "PHASE 1: CLUSTER FOUNDATION"

  # Wait for Rancher webhook to be ready (prevents "no endpoints available" errors
  # when Helm creates new namespaces — Rancher webhook validates namespace creation)
  log_step "Waiting for Rancher webhook to be ready..."
  local webhook_retries=0
  while [[ $webhook_retries -lt 30 ]]; do
    local ep_count
    ep_count=$(kubectl get endpoints rancher-webhook -n cattle-system -o jsonpath='{.subsets[*].addresses}' 2>/dev/null | grep -c "ip" || true)
    if [[ "$ep_count" -gt 0 ]]; then
      log_ok "Rancher webhook has endpoints"
      break
    fi
    webhook_retries=$((webhook_retries + 1))
    log_info "Rancher webhook not ready (attempt ${webhook_retries}/30)... waiting 10s"
    sleep 10
  done
  if [[ $webhook_retries -ge 30 ]]; then
    log_warn "Rancher webhook did not become ready — continuing (may fail)"
  fi

  # Label all worker nodes (Rancher does NOT propagate workload-type labels from machine pool config)
  label_unlabeled_nodes

  # 1.1 Wait for Traefik system chart + apply HelmChartConfig
  log_step "Waiting for Traefik system chart to be deployed..."
  local traefik_retries=0
  while [[ $traefik_retries -lt 30 ]]; do
    if kubectl get helmcharts.helm.cattle.io rke2-traefik -n kube-system &>/dev/null; then
      log_ok "Traefik HelmChart detected"
      break
    fi
    traefik_retries=$((traefik_retries + 1))
    log_info "Traefik system chart not yet deployed (attempt ${traefik_retries}/30)... waiting 10s"
    sleep 10
  done
  if [[ $traefik_retries -ge 30 ]]; then
    die "Traefik system chart never appeared — check that ingress-controller=traefik is set in cluster config"
  fi

  # Create placeholder vault-root-ca in kube-system so Traefik can mount it
  # (Real CA comes from Phase 2 via distribute_root_ca)
  kubectl create configmap vault-root-ca --from-literal=ca.crt="" \
    -n kube-system --dry-run=client -o yaml | kubectl apply -f -

  # Traefik config (plugin, volumes, timeouts, etc.) is managed via chart_values
  # in cluster.tf — Rancher's managed-chart-config addon reconciles it into the
  # HelmChartConfig. No need to apply traefik-timeout-helmchartconfig.yaml here.
  log_ok "Traefik config managed via Rancher chart_values (cluster.tf)"

  # CoreDNS hairpin DNS: rewrite *.DOMAIN to Traefik ClusterIP for in-cluster OIDC
  log_step "Applying CoreDNS HelmChartConfig (hairpin DNS for in-cluster OIDC)..."
  kube_apply_subst "${SERVICES_DIR}/harbor/coredns-helmchartconfig.yaml"

  # Wait for Traefik CRDs to become available (Middleware, IngressRoute, etc.)
  log_step "Waiting for Traefik CRDs to be available..."
  local crd_retries=0
  while [[ $crd_retries -lt 30 ]]; do
    if kubectl get crd middlewares.traefik.io &>/dev/null; then
      log_ok "Traefik CRDs are available"
      break
    fi
    crd_retries=$((crd_retries + 1))
    log_info "Traefik CRDs not yet registered (attempt ${crd_retries}/30)... waiting 10s"
    sleep 10
  done
  if [[ $crd_retries -ge 30 ]]; then
    log_warn "Traefik CRDs did not become available — Middleware resources may fail"
  fi

  # 1.2 Deploy curl-check pod for HTTPS connectivity testing across phases
  deploy_check_pod

  # 1.3 Gateway API CRDs (required by cert-manager gateway-shim, Traefik, and Cilium)
  log_step "Installing Gateway API standard CRDs..."
  kube_apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
  log_ok "Gateway API CRDs installed"

  # 1.4 cert-manager
  log_step "Installing cert-manager..."
  helm_repo_add jetstack https://charts.jetstack.io
  helm repo update jetstack

  helm_install_if_needed cert-manager jetstack/cert-manager cert-manager \
    --version v1.19.3 \
    --set crds.enabled=true \
    --set config.apiVersion=controller.config.cert-manager.io/v1alpha1 \
    --set config.kind=ControllerConfiguration \
    --set config.enableGatewayAPI=true \
    --set nodeSelector.workload-type=general \
    --set webhook.nodeSelector.workload-type=general \
    --set cainjector.nodeSelector.workload-type=general \
    --set startupapicheck.enabled=false \
    --timeout 10m

  wait_for_deployment cert-manager cert-manager 300s
  wait_for_deployment cert-manager cert-manager-webhook 300s
  log_ok "cert-manager installed"

  # 1.5 CNPG Operator
  log_step "Installing CNPG Operator..."
  helm_repo_add cnpg https://cloudnative-pg.github.io/charts
  helm repo update cnpg

  helm_install_if_needed cnpg-operator cnpg/cloudnative-pg cnpg-system \
    --version 0.27.1 \
    --set nodeSelector.workload-type=general \
    --timeout 10m

  log_ok "CNPG Operator installed"

  # 1.6 Cluster Autoscaler (Rancher cloud provider)
  log_step "Deploying Cluster Autoscaler (Rancher provider)..."
  local rancher_url rancher_token cluster_name
  rancher_url=$(get_rancher_url)
  rancher_token=$(get_rancher_token)
  cluster_name=$(get_cluster_name)

  # Create cloud-config Secret for Rancher autoscaler
  kubectl create secret generic cluster-autoscaler-cloud-config \
    -n kube-system \
    --from-literal=cloud-config="url: ${rancher_url}
token: ${rancher_token}
clusterName: ${cluster_name}
clusterNamespace: fleet-default" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Get Rancher CA cert (self-signed dynamiclistener-ca) and store as configmap
  local rancher_ca
  rancher_ca=$(curl -sk "${rancher_url}/v3/settings/cacerts" \
    -H "Authorization: Bearer ${rancher_token}" | jq -r '.value // empty' 2>/dev/null || echo "")
  if [[ -n "$rancher_ca" ]]; then
    kubectl create configmap cluster-autoscaler-rancher-ca \
      -n kube-system \
      --from-literal=ca.pem="$rancher_ca" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    log_warn "Could not fetch Rancher CA cert — autoscaler may fail TLS verification"
  fi

  helm_repo_add autoscaler https://kubernetes.github.io/autoscaler
  helm repo update autoscaler

  helm_install_if_needed cluster-autoscaler autoscaler/cluster-autoscaler kube-system \
    --set cloudProvider=rancher \
    --set "autoDiscovery.clusterName=${cluster_name}" \
    --set "extraArgs.cloud-config=/config/cloud-config" \
    --set "extraArgs.scale-down-delay-after-add=5m" \
    --set "extraArgs.scale-down-unneeded-time=5m" \
    --set "extraArgs.skip-nodes-with-local-storage=false" \
    --set "extraVolumeSecrets.cluster-autoscaler-cloud-config.mountPath=/config" \
    --set "extraVolumeSecrets.cluster-autoscaler-cloud-config.name=cluster-autoscaler-cloud-config" \
    --set "extraVolumes[0].name=rancher-ca" \
    --set "extraVolumes[0].configMap.name=cluster-autoscaler-rancher-ca" \
    --set "extraVolumeMounts[0].name=rancher-ca" \
    --set "extraVolumeMounts[0].mountPath=/etc/ssl/certs/rancher-ca.pem" \
    --set "extraVolumeMounts[0].subPath=ca.pem" \
    --set "extraVolumeMounts[0].readOnly=true" \
    --set "extraEnv.SSL_CERT_FILE=/etc/ssl/certs/rancher-ca.pem" \
    --set nodeSelector.workload-type=general \
    --set "resources.requests.cpu=50m" \
    --set "resources.requests.memory=128Mi" \
    --set "resources.limits.cpu=200m" \
    --set "resources.limits.memory=256Mi" \
    --timeout 5m

  # Verify autoscaler pod is running (chart names deployment: cluster-autoscaler-rancher-cluster-autoscaler)
  wait_for_deployment kube-system cluster-autoscaler-rancher-cluster-autoscaler 120s 2>/dev/null || \
    log_warn "Cluster autoscaler deployment not ready — check logs"

  local ca_pods
  ca_pods=$(kubectl -n kube-system get pods -l "app.kubernetes.io/name=rancher-cluster-autoscaler" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  if [[ "$ca_pods" -gt 0 ]]; then
    log_ok "Cluster Autoscaler running (${ca_pods} pod)"
  else
    log_warn "Cluster Autoscaler pod not running — check 'kubectl -n kube-system logs -l app.kubernetes.io/name=rancher-cluster-autoscaler'"
  fi

  # 1.7 OpsTree Redis Operator (manages Valkey for Harbor, LibreNMS)
  log_step "Installing OpsTree Redis Operator..."
  helm_repo_add ot-helm https://ot-container-kit.github.io/helm-charts/
  helm repo update ot-helm

  helm_install_if_needed redis-operator ot-helm/redis-operator redis-operator-system \
    --set nodeSelector.workload-type=general \
    --timeout 5m

  log_ok "Redis Operator installed"

  # 1.8 Node Labeler operator — labels autoscaler-created nodes with workload-type
  # machine_selector_config in cluster.tf has a race condition with autoscaler nodes:
  # the rke.cattle.io/rke-machine-pool-name label may not be set early enough for
  # the RKE2 system-agent to include workload-type in kubelet --node-labels.
  log_step "Deploying Node Labeler operator..."
  kube_apply_k_subst "${SERVICES_DIR}/node-labeler"
  if ! wait_for_deployment node-labeler node-labeler 120s 2>/dev/null; then
    log_warn "Node Labeler not ready (image may not be built yet) — continuing"
  fi

  # 1.9 MariaDB Operator (conditional — only if LibreNMS is enabled)
  if [[ "${DEPLOY_LIBRENMS}" == "true" ]]; then
    log_step "Installing MariaDB Operator (for LibreNMS)..."
    helm_repo_add mariadb-operator https://mariadb-operator.github.io/mariadb-operator
    helm repo update mariadb-operator

    helm_install_if_needed mariadb-operator mariadb-operator/mariadb-operator mariadb-operator-system \
      --set nodeSelector.workload-type=general \
      --timeout 5m

    log_ok "MariaDB Operator installed"
  fi

  end_phase "PHASE 1: FOUNDATION"
}

# =============================================================================
# PHASE 2: VAULT + PKI — Fully Scripted
# =============================================================================
phase_2_vault() {
  start_phase "PHASE 2: VAULT + PKI"

  local vault_init_file="${CLUSTER_DIR}/vault-init.json"

  # Wait for Rancher webhook to be ready (prevents "no endpoints available" errors
  # when Helm creates new namespaces — Rancher webhook validates namespace creation)
  log_step "Waiting for Rancher webhook to be ready..."
  local webhook_retries=0
  while [[ $webhook_retries -lt 30 ]]; do
    local ep_count
    ep_count=$(kubectl get endpoints rancher-webhook -n cattle-system -o jsonpath='{.subsets[*].addresses}' 2>/dev/null | grep -c "ip" || true)
    if [[ "$ep_count" -gt 0 ]]; then
      log_ok "Rancher webhook has endpoints"
      break
    fi
    webhook_retries=$((webhook_retries + 1))
    log_info "Rancher webhook not ready (attempt ${webhook_retries}/30)... waiting 10s"
    sleep 10
  done
  if [[ $webhook_retries -ge 30 ]]; then
    log_warn "Rancher webhook did not become ready — continuing (may fail)"
  fi

  # 2.1 Install Vault HA
  log_step "Installing Vault HA (3 replicas)..."
  helm_repo_add hashicorp https://helm.releases.hashicorp.com
  helm repo update hashicorp

  helm_install_if_needed vault hashicorp/vault vault \
    --version 0.32.0 \
    -f "${SERVICES_DIR}/vault/vault-values.yaml" \
    --timeout 5m

  # Wait for pods to be Running (they'll be 0/1 Ready since they're sealed)
  wait_for_pods_running vault 3 300

  # Check if Vault is already initialized (resuming a failed run)
  # vault status exits 2 when sealed — capture output regardless of exit code
  local sealed_status
  sealed_status=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null; true)
  if ! echo "$sealed_status" | jq -e '.initialized' &>/dev/null; then
    sealed_status='{"initialized": false}'
  fi
  local initialized
  initialized=$(echo "$sealed_status" | jq -r '.initialized')

  if [[ "$initialized" == "true" ]]; then
    log_info "Vault is already initialized"
    # If we have vault-init.json, unseal; otherwise try to pull from Harvester
    if [[ ! -f "$vault_init_file" ]]; then
      log_info "Pulling vault-init.json from Harvester secrets..."
      cd "${CLUSTER_DIR}" && ./terraform.sh pull-secrets
    fi

    if [[ ! -f "$vault_init_file" ]]; then
      die "Vault is initialized but vault-init.json not found. Cannot unseal."
    fi

    # Unseal vault-0 if needed
    local is_sealed
    is_sealed=$(echo "$sealed_status" | jq -r '.sealed')
    if [[ "$is_sealed" == "false" ]]; then
      log_ok "vault-0 is already unsealed"
    else
      vault_unseal_replica 0 "$vault_init_file"
    fi

    # Join and unseal vault-1 and vault-2 if they haven't joined Raft yet
    local root_token
    root_token=$(jq -r '.root_token' "$vault_init_file")
    for i in 1 2; do
      local replica_init
      replica_init=$(kubectl exec -n vault "vault-${i}" -- vault status -format=json 2>/dev/null; true)
      local r_initialized
      r_initialized=$(echo "$replica_init" | jq -r '.initialized // false' 2>/dev/null || echo "false")
      if [[ "$r_initialized" != "true" ]]; then
        log_info "vault-${i} not yet in Raft cluster, joining..."
        kubectl exec -n vault "vault-${i}" -- env \
          VAULT_ADDR=http://127.0.0.1:8200 \
          vault operator raft join http://vault-0.vault-internal:8200 2>/dev/null || true
        sleep 3
      fi
      local r_sealed
      r_sealed=$(kubectl exec -n vault "vault-${i}" -- vault status -format=json 2>/dev/null; true)
      r_sealed=$(echo "$r_sealed" | jq -r '.sealed // true' 2>/dev/null || echo "true")
      if [[ "$r_sealed" != "false" ]]; then
        vault_unseal_replica "$i" "$vault_init_file"
      else
        log_ok "vault-${i} is already unsealed"
      fi
    done

    # Wait for all pods to become Ready
    sleep 5
    wait_for_pods_ready vault "app.kubernetes.io/name=vault" 120

    # Verify Raft peers
    log_step "Verifying Raft cluster..."
    vault_exec "$root_token" operator raft list-peers
  else
    # 2.2 Initialize Vault
    log_step "Initializing Vault..."
    vault_init "$vault_init_file"

    # 2.3 Unseal vault-0
    log_step "Unsealing vault-0..."
    vault_unseal_replica 0 "$vault_init_file"
  fi

  # From here on, vault-0 is initialized and unsealed.
  # Join and unseal replicas, configure PKI — all idempotent.

  local root_token
  root_token=$(jq -r '.root_token' "$vault_init_file")

  # 2.4 Join Raft peers and unseal vault-1 and vault-2
  log_step "Ensuring Raft cluster is formed and all replicas unsealed..."
  for i in 1 2; do
    local replica_status
    replica_status=$(kubectl exec -n vault "vault-${i}" -- vault status -format=json 2>/dev/null; true)
    local r_initialized
    r_initialized=$(echo "$replica_status" | jq -r '.initialized // false' 2>/dev/null || echo "false")
    if [[ "$r_initialized" != "true" ]]; then
      log_info "vault-${i} not yet in Raft cluster, joining..."
      kubectl exec -n vault "vault-${i}" -- env \
        VAULT_ADDR=http://127.0.0.1:8200 \
        vault operator raft join http://vault-0.vault-internal:8200 2>/dev/null || true
      sleep 3
    fi
    local r_sealed
    r_sealed=$(kubectl exec -n vault "vault-${i}" -- vault status -format=json 2>/dev/null; true)
    r_sealed=$(echo "$r_sealed" | jq -r '.sealed // true' 2>/dev/null || echo "true")
    if [[ "$r_sealed" != "false" ]]; then
      vault_unseal_replica "$i" "$vault_init_file"
    else
      log_ok "vault-${i} is already unsealed"
    fi
  done

  # Wait for all pods to become Ready
  sleep 5
  wait_for_pods_ready vault "app.kubernetes.io/name=vault" 120

  # Verify Raft peers
  log_step "Verifying Raft cluster..."
  vault_exec "$root_token" operator raft list-peers

  # 2.5 Root CA (local openssl, idempotent)
  # Root CA key never enters Vault — generated locally, stored on Harvester as secret
  if [[ ! -f "${CLUSTER_DIR}/root-ca.pem" ]]; then
    # Try pulling from Harvester (previous build preserves Root CA)
    log_info "Checking Harvester for existing Root CA..."
    cd "${CLUSTER_DIR}" && ./terraform.sh pull-secrets 2>/dev/null || true
  fi

  if [[ ! -f "${CLUSTER_DIR}/root-ca.pem" ]]; then
    log_step "Generating Root CA (15yr, 4096-bit RSA) locally..."
    openssl genrsa -out "${CLUSTER_DIR}/root-ca-key.pem" 4096 2>/dev/null
    openssl req -x509 -new -nodes \
      -key "${CLUSTER_DIR}/root-ca-key.pem" \
      -sha256 -days 5475 \
      -subj "/CN=${ORG_NAME} Root CA" \
      -out "${CLUSTER_DIR}/root-ca.pem"
    chmod 600 "${CLUSTER_DIR}/root-ca-key.pem"
    chmod 644 "${CLUSTER_DIR}/root-ca.pem"
    log_ok "Root CA generated (key stays local, never enters Vault)"
  else
    log_ok "Root CA already exists: ${CLUSTER_DIR}/root-ca.pem"
  fi

  # 2.6 Intermediate CA (Vault generates key, locally signed by Root CA)
  local pki_engines
  pki_engines=$(vault_exec "$root_token" secrets list -format=json 2>/dev/null | jq -r 'keys[]' || echo "")
  if ! echo "$pki_engines" | grep -q "^pki_int/"; then
    log_step "Configuring Intermediate CA (10yr, signed by local Root CA)..."
    vault_exec "$root_token" secrets enable -path=pki_int pki 2>/dev/null || log_info "PKI intermediate already enabled"
    vault_exec "$root_token" secrets tune -max-lease-ttl=87600h pki_int

    # Generate intermediate CSR inside Vault (key never leaves Vault)
    vault_exec "$root_token" write -field=csr pki_int/intermediate/generate/internal \
      common_name="${ORG_NAME} Intermediate CA" \
      ttl=87600h \
      key_bits=4096 > /tmp/intermediate.csr

    # Sign the CSR LOCALLY with the Root CA key (NOT inside Vault)
    openssl x509 -req -in /tmp/intermediate.csr \
      -CA "${CLUSTER_DIR}/root-ca.pem" \
      -CAkey "${CLUSTER_DIR}/root-ca-key.pem" \
      -CAcreateserial \
      -days 3650 -sha256 \
      -extfile <(printf "basicConstraints=critical,CA:true,pathlen:0\nkeyUsage=critical,digitalSignature,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always") \
      -out /tmp/intermediate.crt

    # Build full chain (intermediate + root) for Vault import
    cat /tmp/intermediate.crt "${CLUSTER_DIR}/root-ca.pem" > /tmp/intermediate-chain.crt

    # Import signed intermediate chain into Vault
    kubectl cp /tmp/intermediate-chain.crt vault/vault-0:/tmp/intermediate-chain.crt
    vault_exec "$root_token" write pki_int/intermediate/set-signed \
      certificate=@/tmp/intermediate-chain.crt

    vault_exec "$root_token" write pki_int/config/urls \
      issuing_certificates="http://vault.vault.svc.cluster.local:8200/v1/pki_int/ca" \
      crl_distribution_points="http://vault.vault.svc.cluster.local:8200/v1/pki_int/crl"

    # Create signing role (require_cn=false — cert-manager gateway-shim sends SANs only)
    vault_exec "$root_token" write "pki_int/roles/${DOMAIN_DOT}" \
      "allowed_domains=${DOMAIN}" \
      allow_subdomains=true \
      max_ttl=720h \
      generate_lease=true \
      require_cn=false
    log_ok "Intermediate CA configured with signing role (signed by external Root CA)"
  else
    log_ok "PKI already configured (pki_int/ engine exists)"
  fi

  # 2.7 Configure Kubernetes auth for cert-manager (idempotent)
  local auth_methods
  auth_methods=$(vault_exec "$root_token" auth list -format=json 2>/dev/null | jq -r 'keys[]' || echo "")
  if ! echo "$auth_methods" | grep -q "^kubernetes/"; then
    log_step "Configuring Kubernetes auth..."

    local k8s_host
    k8s_host="https://$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')"

    vault_exec "$root_token" auth enable kubernetes 2>/dev/null || log_info "K8s auth already enabled"

    # Create a long-lived token for Vault SA (K8s 1.24+ does not auto-create SA secrets)
    local sa_jwt sa_ca
    sa_jwt=$(kubectl create token vault -n vault --duration=8760h 2>/dev/null || true)

    if [[ -z "$sa_jwt" ]]; then
      # Fallback: try legacy SA token secret (pre-1.24 clusters)
      local sa_secret
      sa_secret=$(kubectl get secret -n vault --no-headers 2>/dev/null | grep "vault-token" | head -1 | awk '{print $1}' || echo "")
      if [[ -n "$sa_secret" ]]; then
        sa_jwt=$(kubectl get secret -n vault "$sa_secret" -o jsonpath='{.data.token}' | base64 -d)
      else
        die "Cannot create Vault SA token for Kubernetes auth"
      fi
    fi

    sa_ca=$(kubectl get configmap kube-root-ca.crt -n vault -o jsonpath='{.data.ca\.crt}')

    # Write K8s auth config — use a temp file for the CA cert
    echo "$sa_ca" > /tmp/vault-k8s-ca.crt
    kubectl cp /tmp/vault-k8s-ca.crt vault/vault-0:/tmp/k8s-ca.crt

    vault_exec "$root_token" write auth/kubernetes/config \
      kubernetes_host="${k8s_host}:443" \
      kubernetes_ca_cert=@/tmp/k8s-ca.crt \
      issuer="https://kubernetes.default.svc.cluster.local"

    # Create cert-manager policy
    vault_exec_stdin "$root_token" policy write cert-manager - <<POLICY
path "pki_int/sign/${DOMAIN_DOT}" {
  capabilities = ["create", "update"]
}
path "pki_int/issue/${DOMAIN_DOT}" {
  capabilities = ["create", "update"]
}
path "pki_int/cert/ca" {
  capabilities = ["read"]
}
POLICY

    # Create K8s auth role for cert-manager
    vault_exec "$root_token" write auth/kubernetes/role/cert-manager-issuer \
      bound_service_account_names=vault-issuer \
      bound_service_account_namespaces=cert-manager \
      policies=cert-manager \
      ttl=1h
    log_ok "Kubernetes auth configured for cert-manager"
  else
    log_ok "Kubernetes auth already configured"
  fi

  # 2.8 Store vault-init.json on Harvester
  log_step "Storing vault-init.json on Harvester..."
  cd "${CLUSTER_DIR}" && ./terraform.sh push-secrets
  log_ok "vault-init.json backed up to Harvester"

  # 2.9 Apply cert-manager RBAC + ClusterIssuer
  log_step "Applying cert-manager RBAC and ClusterIssuer..."
  kube_apply -f "${SERVICES_DIR}/cert-manager/rbac.yaml"
  kube_apply_subst "${SERVICES_DIR}/cert-manager/cluster-issuer.yaml"
  wait_for_clusterissuer vault-issuer 120

  # 2.10 Apply Vault Gateway + HTTPRoute
  log_step "Applying Vault Gateway + HTTPRoute..."
  kube_apply_subst "${SERVICES_DIR}/vault/gateway.yaml" \
                   "${SERVICES_DIR}/vault/httproute.yaml"

  log_ok "TLS is now available cluster-wide via vault-issuer"

  # Cleanup temp files
  rm -f /tmp/intermediate.csr /tmp/intermediate.crt /tmp/intermediate-chain.crt \
       /tmp/vault-k8s-ca.crt "${CLUSTER_DIR}/root-ca.srl"

  # HTTPS connectivity check
  wait_for_tls_secret vault "vault-${DOMAIN_DASHED}-tls" 120
  check_https "vault.${DOMAIN}"

  # Distribute Root CA to service namespaces BEFORE monitoring (Grafana needs it)
  log_step "Distributing Root CA to service namespaces..."
  distribute_root_ca

  # Restart Traefik to pick up real vault-root-ca (services need it for OIDC TLS)
  log_step "Restarting Traefik to pick up Root CA..."
  kubectl rollout restart daemonset/rke2-traefik -n kube-system
  kubectl rollout status daemonset/rke2-traefik -n kube-system --timeout=120s

  end_phase "PHASE 2: VAULT + PKI"
}

# =============================================================================
# PHASE 3: MONITORING STACK
# =============================================================================
phase_3_monitoring() {
  start_phase "PHASE 3: MONITORING STACK"

  log_step "Deploying monitoring stack (Prometheus, Grafana, Loki, Alloy, Alertmanager)..."
  kube_apply_k_subst "${SERVICES_DIR}/monitoring-stack"

  # Wait for key deployments
  wait_for_deployment monitoring grafana 300s
  wait_for_pods_ready monitoring "app=prometheus" 300
  wait_for_pods_ready monitoring "app=loki" 300

  # Verify TLS certs
  log_step "Verifying TLS certificates..."
  wait_for_tls_secret monitoring "grafana-${DOMAIN_DASHED}-tls" 120
  wait_for_tls_secret monitoring "prometheus-${DOMAIN_DASHED}-tls" 120
  wait_for_tls_secret monitoring "alertmanager-${DOMAIN_DASHED}-tls" 120
  wait_for_tls_secret kube-system "hubble-${DOMAIN_DASHED}-tls" 120

  # HTTPS connectivity checks
  check_https_batch "grafana.${DOMAIN}" "prometheus.${DOMAIN}" "alertmanager.${DOMAIN}" "hubble.${DOMAIN}"

  # 3.2 Storage Autoscaler operator (needs Prometheus running)
  # Non-fatal: image may not be built yet on first deploy
  log_step "Deploying Storage Autoscaler operator..."
  kube_apply_k_subst "${SERVICES_DIR}/storage-autoscaler"
  if ! wait_for_deployment storage-autoscaler storage-autoscaler 120s 2>/dev/null; then
    log_warn "Storage Autoscaler not ready (image may not be built yet) — continuing"
  fi

  # Apply VolumeAutoscaler CRs for namespaces that exist now (vault, monitoring).
  # CRs for namespaces created later (database, harbor, mattermost, etc.) are
  # applied in Phase 9 after all services are deployed.
  log_step "Applying VolumeAutoscaler CRs (available namespaces)..."
  for cr in "${SERVICES_DIR}/storage-autoscaler/examples/"*.yaml; do
    kubectl apply -f "$cr" 2>/dev/null || true
  done
  log_ok "Storage Autoscaler deployed"

  end_phase "PHASE 3: MONITORING STACK"
}

# =============================================================================
# PHASE 4: HARBOR — Container Registry
# =============================================================================
phase_4_harbor() {
  start_phase "PHASE 4: HARBOR"

  # 4.1 Namespaces
  log_step "Creating namespaces..."
  kube_apply -f "${SERVICES_DIR}/harbor/namespace.yaml"
  kube_apply -f "${SERVICES_DIR}/harbor/minio/namespace.yaml"
  ensure_namespace database

  # 4.2 MinIO (runs in parallel with 4.3 — but in a script we do sequential)
  log_step "Deploying MinIO for Harbor..."
  kube_apply_subst "${SERVICES_DIR}/harbor/minio/secret.yaml"
  kube_apply -f "${SERVICES_DIR}/harbor/minio/pvc.yaml"
  kube_apply -f "${SERVICES_DIR}/harbor/minio/deployment.yaml"
  kube_apply -f "${SERVICES_DIR}/harbor/minio/service.yaml"
  wait_for_deployment minio minio 300s
  kube_apply -f "${SERVICES_DIR}/harbor/minio/job-create-buckets.yaml"
  log_ok "MinIO deployed"

  # 4.3 CNPG harbor-pg
  log_step "Deploying CNPG harbor-pg cluster..."
  kube_apply_subst "${SERVICES_DIR}/harbor/postgres/secret.yaml"
  kube_apply -f "${SERVICES_DIR}/harbor/postgres/harbor-pg-cluster.yaml"
  kube_apply -f "${SERVICES_DIR}/harbor/postgres/harbor-pg-scheduled-backup.yaml"
  wait_for_cnpg_primary database harbor-pg 600
  log_ok "CNPG harbor-pg deployed"

  # 4.4 Redis Sentinel (via OpsTree Redis Operator)
  log_step "Deploying Redis Sentinel for Harbor..."
  kube_apply_subst "${SERVICES_DIR}/harbor/valkey/secret.yaml"
  kube_apply -f "${SERVICES_DIR}/harbor/valkey/replication.yaml"
  kube_apply -f "${SERVICES_DIR}/harbor/valkey/sentinel.yaml"
  # Wait for replication master + replicas, then sentinel pods
  wait_for_pods_ready harbor "app=harbor-redis" 300
  wait_for_pods_ready harbor "app=harbor-redis-sentinel" 300
  log_ok "Redis Sentinel deployed"

  # 4.5 Harbor Helm chart (substitute CHANGEME tokens in values before install)
  log_step "Installing Harbor..."
  helm_repo_add goharbor https://helm.goharbor.io
  helm repo update goharbor

  local harbor_values_tmp
  harbor_values_tmp=$(mktemp)
  _subst_changeme < "${SERVICES_DIR}/harbor/harbor-values.yaml" > "$harbor_values_tmp"

  helm_install_if_needed harbor goharbor/harbor harbor \
    --version 1.18.2 \
    -f "$harbor_values_tmp" \
    --timeout 10m

  rm -f "$harbor_values_tmp"

  wait_for_deployment harbor harbor-core 600s
  log_ok "Harbor deployed"

  # 4.6 Gateway + HTTPRoute + HPAs
  log_step "Applying Harbor Gateway, HTTPRoute, and HPAs..."
  kube_apply_subst "${SERVICES_DIR}/harbor/gateway.yaml" \
                   "${SERVICES_DIR}/harbor/httproute.yaml"
  kube_apply -f "${SERVICES_DIR}/harbor/hpa-core.yaml" \
             -f "${SERVICES_DIR}/harbor/hpa-registry.yaml" \
             -f "${SERVICES_DIR}/harbor/hpa-trivy.yaml"

  wait_for_tls_secret harbor "harbor-${DOMAIN_DASHED}-tls" 120

  # HTTPS connectivity check
  check_https "harbor.${DOMAIN}"

  # 4.7 Configure proxy cache projects via Harbor API
  log_step "Configuring Harbor proxy cache projects..."
  configure_harbor_projects

  # 4.8 Distribute Root CA to service namespaces (monitoring, argocd, harbor, mattermost)
  log_step "Distributing Root CA to service namespaces..."
  distribute_root_ca

  # 4.9 Configure Rancher cluster registries (mirrors + CA trust for all nodes)
  log_step "Configuring Rancher cluster registries (Harbor mirrors + CA)..."
  configure_rancher_registries

  # 4.10 Push pre-built operator images to Harbor
  log_step "Pushing operator images to Harbor..."
  push_operator_images

  end_phase "PHASE 4: HARBOR"
}

configure_harbor_projects() {
  # Wait for Harbor API to be responsive
  local harbor_core_pod
  harbor_core_pod=$(kubectl -n harbor get pod -l component=core -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$harbor_core_pod" ]]; then
    log_warn "Harbor core pod not found, skipping project configuration"
    return 0
  fi

  local harbor_api="http://harbor-core.harbor.svc.cluster.local/api/v2.0"
  local admin_pass
  admin_pass=$(grep 'harborAdminPassword' "${SERVICES_DIR}/harbor/harbor-values.yaml" | awk -F'"' '{print $2}')
  local auth="admin:${admin_pass}"

  # Wait for API readiness
  local retries=0
  while [[ $retries -lt 30 ]]; do
    if kubectl exec -n harbor "$harbor_core_pod" -- \
      curl -sf -u "$auth" "${harbor_api}/systeminfo" &>/dev/null; then
      break
    fi
    sleep 10
    retries=$((retries + 1))
  done

  if [[ $retries -ge 30 ]]; then
    log_warn "Harbor API not responsive, skipping project configuration (configure manually later)"
    return 0
  fi

  # Proxy cache registries — all use type "docker-registry" in Harbor API
  # Bash 3.2 compatible (no associative arrays)
  local registry_names="dockerhub quay ghcr gcr k8s elastic"
  local registry_urls

  if [[ "${AIRGAPPED:-false}" == "true" ]]; then
    if [[ -z "${UPSTREAM_PROXY_REGISTRY:-}" ]]; then
      die "AIRGAPPED=true but UPSTREAM_PROXY_REGISTRY is not set in .env"
    fi
    log_info "Airgapped mode: using upstream proxy ${UPSTREAM_PROXY_REGISTRY}"
    registry_urls="https://${UPSTREAM_PROXY_REGISTRY}/dockerhub https://${UPSTREAM_PROXY_REGISTRY}/quay https://${UPSTREAM_PROXY_REGISTRY}/ghcr https://${UPSTREAM_PROXY_REGISTRY}/gcr https://${UPSTREAM_PROXY_REGISTRY}/k8s https://${UPSTREAM_PROXY_REGISTRY}/elastic"
  else
    registry_urls="https://registry-1.docker.io https://quay.io https://ghcr.io https://gcr.io https://registry.k8s.io https://docker.elastic.co"
  fi

  local i=1
  for project in $registry_names; do
    local endpoint
    endpoint=$(echo "$registry_urls" | cut -d' ' -f"$i")
    i=$((i + 1))
    log_info "Creating proxy cache registry: ${project} → ${endpoint}"

    # Create registry endpoint
    kubectl exec -n harbor "$harbor_core_pod" -- \
      curl -sf -u "$auth" -X POST "${harbor_api}/registries" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${project}\",\"type\":\"docker-registry\",\"url\":\"${endpoint}\",\"insecure\":false}" 2>/dev/null || true

    # Get registry ID
    local reg_id
    reg_id=$(kubectl exec -n harbor "$harbor_core_pod" -- \
      curl -sf -u "$auth" "${harbor_api}/registries" 2>/dev/null | \
      jq -r ".[] | select(.name==\"${project}\") | .id" 2>/dev/null || echo "")

    if [[ -n "$reg_id" ]]; then
      # Create proxy cache project
      kubectl exec -n harbor "$harbor_core_pod" -- \
        curl -sf -u "$auth" -X POST "${harbor_api}/projects" \
        -H "Content-Type: application/json" \
        -d "{\"project_name\":\"${project}\",\"registry_id\":${reg_id},\"public\":true,\"metadata\":{\"public\":\"true\"}}" 2>/dev/null || true
    fi
  done

  # CICD projects
  for project in library charts dev; do
    log_info "Creating CICD project: ${project}"
    kubectl exec -n harbor "$harbor_core_pod" -- \
      curl -sf -u "$auth" -X POST "${harbor_api}/projects" \
      -H "Content-Type: application/json" \
      -d "{\"project_name\":\"${project}\",\"public\":false}" 2>/dev/null || true
  done

  log_ok "Harbor projects configured"
}

# =============================================================================
# PHASE 5: ARGOCD + ARGO ROLLOUTS
# =============================================================================
phase_5_argocd() {
  start_phase "PHASE 5: ARGOCD + ARGO ROLLOUTS"

  # 5.1 ArgoCD
  log_step "Installing ArgoCD HA..."
  ensure_namespace argocd

  local argocd_values_tmp; argocd_values_tmp=$(mktemp)
  _subst_changeme < "${SERVICES_DIR}/argo/argocd/argocd-values.yaml" > "$argocd_values_tmp"
  helm_install_if_needed argocd oci://ghcr.io/argoproj/argo-helm/argo-cd argocd \
    -f "$argocd_values_tmp" --timeout 10m
  rm -f "$argocd_values_tmp"

  wait_for_deployment argocd argocd-server 300s
  log_ok "ArgoCD deployed"

  log_step "Applying ArgoCD Gateway + HTTPRoute..."
  kube_apply_subst "${SERVICES_DIR}/argo/argocd/gateway.yaml" \
                   "${SERVICES_DIR}/argo/argocd/httproute.yaml"
  wait_for_tls_secret argocd "argo-${DOMAIN_DASHED}-tls" 120

  # Retrieve initial admin password
  local argocd_pass
  argocd_pass=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "not-yet-available")
  log_ok "ArgoCD initial admin password: ${argocd_pass}"

  # 5.2 Argo Rollouts
  log_step "Installing Argo Rollouts..."
  ensure_namespace argo-rollouts

  helm_install_if_needed argo-rollouts oci://ghcr.io/argoproj/argo-helm/argo-rollouts argo-rollouts \
    -f "${SERVICES_DIR}/argo/argo-rollouts/argo-rollouts-values.yaml" \
    --timeout 5m

  log_ok "Argo Rollouts deployed"

  log_step "Applying Rollouts oauth2-proxy middleware, Gateway + HTTPRoute..."
  kube_apply_subst "${SERVICES_DIR}/argo/argo-rollouts/oauth2-proxy.yaml"
  kube_apply -f "${SERVICES_DIR}/argo/argo-rollouts/middleware-oauth2-proxy.yaml"
  kube_apply_subst "${SERVICES_DIR}/argo/argo-rollouts/gateway.yaml" \
                   "${SERVICES_DIR}/argo/argo-rollouts/httproute.yaml"
  wait_for_tls_secret argo-rollouts "rollouts-${DOMAIN_DASHED}-tls" 120

  # HTTPS connectivity checks
  check_https_batch "argo.${DOMAIN}" "rollouts.${DOMAIN}"

  end_phase "PHASE 5: ARGOCD + ARGO ROLLOUTS"
}

# =============================================================================
# PHASE 6: KEYCLOAK
# =============================================================================
phase_6_keycloak() {
  start_phase "PHASE 6: KEYCLOAK"

  # 6.1 Ensure namespaces
  ensure_namespace keycloak
  ensure_namespace database

  # 6.2 CNPG keycloak-pg (in database namespace)
  log_step "Deploying CNPG keycloak-pg cluster..."
  kube_apply_subst "${SERVICES_DIR}/keycloak/postgres/secret.yaml"
  kube_apply -f "${SERVICES_DIR}/keycloak/postgres/keycloak-pg-cluster.yaml"
  wait_for_cnpg_primary database keycloak-pg 600
  log_ok "CNPG keycloak-pg deployed"

  # 6.3 Keycloak application
  log_step "Deploying Keycloak HA stack..."
  kube_apply_k_subst "${SERVICES_DIR}/keycloak"

  # Wait for Keycloak deployment (may only get 1 replica on small clusters)
  wait_for_deployment keycloak keycloak 300s || {
    local kc_avail
    kc_avail=$(kubectl -n keycloak get deployment keycloak -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    if [[ "$kc_avail" -ge 1 ]]; then
      log_warn "Keycloak has ${kc_avail}/2 replica(s) — continuing (2nd replica needs more general pool capacity)"
    else
      die "Keycloak has no available replicas"
    fi
  }

  wait_for_tls_secret keycloak "keycloak-${DOMAIN_DASHED}-tls" 120

  # HTTPS connectivity check
  check_https "keycloak.${DOMAIN}"

  # Verify Infinispan cluster formation
  log_step "Verifying Keycloak cluster..."
  sleep 15
  local cluster_log
  cluster_log=$(kubectl -n keycloak logs deployment/keycloak 2>/dev/null | grep -i "cluster" | tail -3 || echo "")
  if [[ -n "$cluster_log" ]]; then
    log_info "Keycloak cluster status:"
    echo "$cluster_log"
  fi

  end_phase "PHASE 6: KEYCLOAK"
}

# =============================================================================
# PHASE 7: REMAINING SERVICES
# =============================================================================
phase_7_remaining() {
  start_phase "PHASE 7: MATTERMOST + KASM + UPTIME KUMA + LIBRENMS"

  # Ensure database namespace exists (needed when resuming with --from 7)
  ensure_namespace database

  # 7.1 Mattermost — CNPG first, then app
  log_step "Deploying CNPG mattermost-pg cluster..."
  kube_apply_subst "${SERVICES_DIR}/mattermost/postgres/secret.yaml"
  kube_apply -f "${SERVICES_DIR}/mattermost/postgres/mattermost-pg-cluster.yaml"
  wait_for_cnpg_primary database mattermost-pg 600
  log_ok "CNPG mattermost-pg deployed"

  log_step "Deploying Mattermost..."
  kube_apply_k_subst "${SERVICES_DIR}/mattermost"

  # Wait for MinIO, then Mattermost
  wait_for_pods_ready mattermost "app=mattermost-minio" 300
  wait_for_deployment mattermost mattermost 300s || {
    local mm_avail
    mm_avail=$(kubectl -n mattermost get deployment mattermost -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    if [[ "${mm_avail:-0}" -ge 1 ]]; then
      log_warn "Mattermost has ${mm_avail} replica(s) — continuing"
    else
      log_warn "Mattermost has no available replicas yet (may need general pool to scale up)"
    fi
  }

  # Create MinIO bucket for Mattermost via mc Job (minio image doesn't include mc)
  log_step "Creating Mattermost MinIO bucket..."
  local minio_user minio_pass
  minio_user=$(kubectl -n mattermost get secret mattermost-minio-secret -o jsonpath='{.data.MINIO_ROOT_USER}' 2>/dev/null | base64 -d || echo "")
  minio_pass=$(kubectl -n mattermost get secret mattermost-minio-secret -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' 2>/dev/null | base64 -d || echo "")

  if [[ -n "$minio_user" && -n "$minio_pass" ]]; then
    # Delete previous Job run if it exists
    kubectl -n mattermost delete job mattermost-create-bucket --ignore-not-found 2>/dev/null || true

    kubectl apply -n mattermost -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: mattermost-create-bucket
  namespace: mattermost
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      nodeSelector:
        workload-type: general
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: quay.io/minio/mc:latest
          command:
            - /bin/sh
            - -c
            - |
              mc alias set local http://mattermost-minio.mattermost.svc.cluster.local:9000 \
                "\${MINIO_ROOT_USER}" "\${MINIO_ROOT_PASSWORD}" && \
              mc mb --ignore-existing local/mattermost
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: mattermost-minio-secret
                  key: MINIO_ROOT_USER
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mattermost-minio-secret
                  key: MINIO_ROOT_PASSWORD
EOF
    # Wait for Job to complete
    kubectl -n mattermost wait --for=condition=complete job/mattermost-create-bucket --timeout=120s 2>/dev/null || \
      log_warn "MinIO bucket creation Job did not complete (check manually)"
    log_ok "Mattermost MinIO bucket created"
  else
    log_warn "Mattermost MinIO secret not found, create bucket manually later"
  fi

  wait_for_tls_secret mattermost "mattermost-${DOMAIN_DASHED}-tls" 120
  log_ok "Mattermost deployed"

  # HTTPS connectivity check for Mattermost
  check_https "mattermost.${DOMAIN}"

  # 7.2 Kasm Workspaces
  log_step "Deploying Kasm Workspaces..."
  kube_apply -f "${SERVICES_DIR}/kasm/namespace.yaml"

  # CNPG for Kasm (PG 14)
  kube_apply_subst "${SERVICES_DIR}/kasm/postgres/secret.yaml"
  kube_apply -f "${SERVICES_DIR}/kasm/postgres/kasm-pg-cluster.yaml"
  wait_for_cnpg_primary database kasm-pg 600

  # Kasm requires uuid-ossp extension for uuid_generate_v4() — create via superuser
  log_info "Creating uuid-ossp extension in Kasm database..."
  local kasm_pg_su_pass
  kasm_pg_su_pass=$(kubectl -n database get secret kasm-pg-superuser-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  if [[ -n "$kasm_pg_su_pass" ]]; then
    kubectl run kasm-pg-ext -n database --rm -i --restart=Never \
      --image=postgres:14-alpine \
      --overrides='{"spec":{"nodeSelector":{"workload-type":"database"}}}' \
      -- psql "postgresql://postgres:${kasm_pg_su_pass}@kasm-pg-rw.database.svc.cluster.local:5432/kasm" \
      -c 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";' 2>/dev/null || log_warn "uuid-ossp extension may already exist"
    log_ok "uuid-ossp extension ready"
  else
    log_warn "Could not get Kasm PG superuser password — uuid-ossp extension may need manual creation"
  fi

  # Kasm Helm install (chart name is kasmtech/kasm, NOT kasmtech/kasm-helm)
  helm_repo_add kasmtech https://helm.kasmweb.com/ 2>/dev/null || true
  helm repo update kasmtech 2>/dev/null || true

  local kasm_values_tmp; kasm_values_tmp=$(mktemp)
  _subst_changeme < "${SERVICES_DIR}/kasm/kasm-values.yaml" > "$kasm_values_tmp"
  helm_install_if_needed kasm kasmtech/kasm kasm \
    -f "$kasm_values_tmp" --version 1.1181.0 \
    --timeout 10m || log_warn "Kasm Helm install had issues (may need manual review)"
  rm -f "$kasm_values_tmp"

  # Wait for Kasm db-init job to complete (seeds schema, has ttlSecondsAfterFinished=100)
  log_info "Waiting for Kasm DB initialization job..."
  kubectl wait --for=condition=complete job/kasm-db-init-job -n kasm --timeout=300s 2>/dev/null || \
    log_warn "Kasm db-init job may not have completed — check 'kubectl logs -n kasm -l app.kubernetes.io/name=kasm-db-init'"

  # Wait for Kasm pods to become ready
  log_info "Waiting for Kasm pods..."
  wait_for_deployment kasm kasm-api-deployment 300s 2>/dev/null || log_warn "Kasm API not ready"

  # Kasm ingress (IngressRoute exception)
  kube_apply_subst "${SERVICES_DIR}/kasm/certificate.yaml" \
                   "${SERVICES_DIR}/kasm/ingressroute.yaml"
  log_ok "Kasm deployed"

  # HTTPS connectivity check for Kasm
  check_https "kasm.${DOMAIN}"

  # 7.3 Uptime Kuma (status page)
  if [[ "${DEPLOY_UPTIME_KUMA}" == "true" ]]; then
    log_step "Deploying Uptime Kuma..."
    kube_apply_k_subst "${SERVICES_DIR}/uptime-kuma"
    wait_for_deployment uptime-kuma uptime-kuma 300s || \
      log_warn "Uptime Kuma not ready yet — may need general pool to scale up"
    wait_for_tls_secret uptime-kuma "status-${DOMAIN_DASHED}-tls" 120
    check_https "status.${DOMAIN}"
    log_ok "Uptime Kuma deployed"
  else
    log_info "Skipping Uptime Kuma (DEPLOY_UPTIME_KUMA=false)"
  fi

  # 7.4 LibreNMS (network monitoring — disabled by default)
  if [[ "${DEPLOY_LIBRENMS}" == "true" ]]; then
    log_step "Deploying LibreNMS stack..."
    kube_apply_k_subst "${SERVICES_DIR}/librenms"
    # Wait for MariaDB Galera to form
    log_info "Waiting for LibreNMS MariaDB Galera cluster..."
    wait_for_pods_ready librenms "app.kubernetes.io/name=librenms-mariadb" 600 || \
      log_warn "LibreNMS MariaDB not fully ready"
    # Wait for Redis replication + sentinel
    wait_for_pods_ready librenms "app=librenms-redis" 300 || \
      log_warn "LibreNMS Redis replication not fully ready"
    wait_for_pods_ready librenms "app=librenms-redis-sentinel" 300 || \
      log_warn "LibreNMS Redis sentinel not fully ready"
    # Wait for app
    wait_for_deployment librenms librenms 300s || \
      log_warn "LibreNMS not ready yet"
    wait_for_tls_secret librenms "librenms-${DOMAIN_DASHED}-tls" 120
    check_https "librenms.${DOMAIN}"
    log_ok "LibreNMS deployed"
  else
    log_info "Skipping LibreNMS (DEPLOY_LIBRENMS=false)"
  fi

  end_phase "PHASE 7: REMAINING SERVICES"
}

# =============================================================================
# PHASE 8: DNS RECORDS
# =============================================================================
phase_8_dns() {
  start_phase "PHASE 8: DNS RECORDS"

  local lb_ip
  lb_ip=$(awk -F'"' '/^traefik_lb_ip[[:space:]]/ {print $2}' "${CLUSTER_DIR}/terraform.tfvars" 2>/dev/null)
  lb_ip="${lb_ip:-198.51.100.2}"

  log_info "Create the following A records pointing to ${lb_ip}:"
  echo ""
  local fqdns=(
    "vault.${DOMAIN}"
    "grafana.${DOMAIN}"
    "prometheus.${DOMAIN}"
    "alertmanager.${DOMAIN}"
    "hubble.${DOMAIN}"
    "traefik.${DOMAIN}"
    "harbor.${DOMAIN}"
    "argo.${DOMAIN}"
    "rollouts.${DOMAIN}"
    "keycloak.${DOMAIN}"
    "mattermost.${DOMAIN}"
    "kasm.${DOMAIN}"
    "gitlab.${DOMAIN}"
  )
  [[ "${DEPLOY_UPTIME_KUMA}" == "true" ]] && fqdns+=("status.${DOMAIN}")
  [[ "${DEPLOY_LIBRENMS}" == "true" ]] && fqdns+=("librenms.${DOMAIN}")
  for fqdn in "${fqdns[@]}"; do
    echo "  ${fqdn}  →  ${lb_ip}"
  done
  echo ""
  log_warn "If DNS is API-driven, add automation here. Otherwise create records manually."

  end_phase "PHASE 8: DNS RECORDS"
}

# =============================================================================
# PHASE 9: VALIDATION
# =============================================================================
phase_9_validation() {
  start_phase "PHASE 9: VALIDATION"

  # Apply RBAC manifests (Keycloak OIDC groups → Kubernetes RBAC)
  log_step "Applying RBAC manifests..."
  kube_apply_k "${SERVICES_DIR}/rbac"
  log_ok "RBAC manifests applied"

  # Re-apply all VolumeAutoscaler CRs now that every namespace exists
  log_step "Applying all VolumeAutoscaler CRs..."
  for cr in "${SERVICES_DIR}/storage-autoscaler/examples/"*.yaml; do
    kubectl apply -f "$cr" 2>/dev/null || log_warn "  Failed to apply: ${cr##*/}"
  done
  log_ok "VolumeAutoscaler CRs applied"

  local errors=0

  # Nodes
  log_step "Checking nodes..."
  local not_ready
  not_ready=$(kubectl get nodes --no-headers | grep -cv "Ready" || true)
  if [[ "$not_ready" -gt 0 ]]; then
    log_error "${not_ready} node(s) not Ready"
    errors=$((errors + 1))
  else
    log_ok "All nodes Ready"
  fi

  # Vault
  log_step "Checking Vault..."
  for i in 0 1 2; do
    local sealed
    sealed=$(kubectl exec -n vault "vault-${i}" -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "unknown")
    if [[ "$sealed" == "false" ]]; then
      log_ok "vault-${i}: unsealed"
    else
      log_error "vault-${i}: sealed or unreachable"
      errors=$((errors + 1))
    fi
  done

  # ClusterIssuer
  log_step "Checking ClusterIssuer..."
  local issuer_ready
  issuer_ready=$(kubectl get clusterissuer vault-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$issuer_ready" == "True" ]]; then
    log_ok "ClusterIssuer vault-issuer: Ready"
  else
    log_error "ClusterIssuer vault-issuer: not Ready"
    errors=$((errors + 1))
  fi

  # TLS Secrets
  log_step "Checking TLS secrets..."
  local expected_secrets=(
    "vault:vault-${DOMAIN_DASHED}-tls"
    "monitoring:grafana-${DOMAIN_DASHED}-tls"
    "monitoring:prometheus-${DOMAIN_DASHED}-tls"
    "monitoring:alertmanager-${DOMAIN_DASHED}-tls"
    "kube-system:hubble-${DOMAIN_DASHED}-tls"
    "harbor:harbor-${DOMAIN_DASHED}-tls"
    "argocd:argo-${DOMAIN_DASHED}-tls"
    "argo-rollouts:rollouts-${DOMAIN_DASHED}-tls"
    "keycloak:keycloak-${DOMAIN_DASHED}-tls"
    "mattermost:mattermost-${DOMAIN_DASHED}-tls"
  )
  [[ "${DEPLOY_UPTIME_KUMA}" == "true" ]] && expected_secrets+=("uptime-kuma:status-${DOMAIN_DASHED}-tls")
  [[ "${DEPLOY_LIBRENMS}" == "true" ]] && expected_secrets+=("librenms:librenms-${DOMAIN_DASHED}-tls")
  for entry in "${expected_secrets[@]}"; do
    local ns="${entry%%:*}"
    local name="${entry##*:}"
    if kubectl -n "$ns" get secret "$name" &>/dev/null; then
      log_ok "  ${ns}/${name}"
    else
      log_warn "  ${ns}/${name} — not found (cert-manager may still be issuing)"
    fi
  done

  # Gateways
  log_step "Checking Gateways..."
  kubectl get gateways -A --no-headers 2>/dev/null | while read -r ns name _rest; do
    log_ok "  Gateway: ${ns}/${name}"
  done

  # Final HTTPS connectivity checks (all services)
  log_step "Running comprehensive HTTPS connectivity checks..."
  local check_fqdns=(
    "vault.${DOMAIN}"
    "grafana.${DOMAIN}"
    "prometheus.${DOMAIN}"
    "alertmanager.${DOMAIN}"
    "hubble.${DOMAIN}"
    "harbor.${DOMAIN}"
    "argo.${DOMAIN}"
    "rollouts.${DOMAIN}"
    "keycloak.${DOMAIN}"
    "mattermost.${DOMAIN}"
    "kasm.${DOMAIN}"
  )
  [[ "${DEPLOY_UPTIME_KUMA}" == "true" ]] && check_fqdns+=("status.${DOMAIN}")
  [[ "${DEPLOY_LIBRENMS}" == "true" ]] && check_fqdns+=("librenms.${DOMAIN}")
  check_https_batch "${check_fqdns[@]}"

  # Key pods
  log_step "Checking critical pods..."
  local critical_deployments=(
    "cert-manager:cert-manager"
    "monitoring:grafana"
    "storage-autoscaler:storage-autoscaler"
    "harbor:harbor-core"
    "argocd:argocd-server"
    "keycloak:keycloak"
    "mattermost:mattermost"
  )
  for entry in "${critical_deployments[@]}"; do
    local ns="${entry%%:*}"
    local name="${entry##*:}"
    local avail
    avail=$(kubectl -n "$ns" get deployment "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    if [[ "$avail" -gt 0 ]]; then
      log_ok "  ${ns}/${name}: ${avail} replica(s) available"
    else
      log_error "  ${ns}/${name}: no available replicas"
      errors=$((errors + 1))
    fi
  done

  # VolumeAutoscaler CRs
  log_step "Checking VolumeAutoscaler CRs..."
  local va_count
  va_count=$(kubectl get volumeautoscalers -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$va_count" -gt 0 ]]; then
    log_ok "  ${va_count} VolumeAutoscaler CR(s) deployed"
    kubectl get volumeautoscalers -A 2>/dev/null || true
  else
    log_warn "  No VolumeAutoscaler CRs found — storage autoscaling is not active"
  fi

  # Summary
  echo ""
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}  DEPLOYMENT SUMMARY${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo ""

  # Gather all credentials (some from .env, some from cluster secrets)
  local argocd_pass harbor_pass kasm_pass vault_root_token
  argocd_pass=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "N/A")
  harbor_pass=$(grep 'harborAdminPassword' "${SERVICES_DIR}/harbor/harbor-values.yaml" 2>/dev/null | \
    sed -n 's/.*"\([^"]*\)".*/\1/p' || echo "N/A")
  kasm_pass=$(kubectl -n kasm get secret kasm-secrets \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "see kasm-secrets")
  if [[ -f "${CLUSTER_DIR}/vault-init.json" ]]; then
    vault_root_token=$(jq -r '.root_token' "${CLUSTER_DIR}/vault-init.json" 2>/dev/null || echo "see vault-init.json")
  else
    vault_root_token="see vault-init.json (stored on Harvester)"
  fi

  echo "  Service FQDNs (all point to Traefik LB):"
  echo "    Vault:       https://vault.${DOMAIN}"
  echo "    Grafana:     https://grafana.${DOMAIN}"
  echo "    Prometheus:  https://prometheus.${DOMAIN}"
  echo "    Alertmanager: https://alertmanager.${DOMAIN}"
  echo "    Hubble:      https://hubble.${DOMAIN}"
  echo "    Traefik:     https://traefik.${DOMAIN}"
  echo "    Harbor:      https://harbor.${DOMAIN}"
  echo "    ArgoCD:      https://argo.${DOMAIN}"
  echo "    Rollouts:    https://rollouts.${DOMAIN}"
  echo "    Keycloak:    https://keycloak.${DOMAIN}"
  echo "    Mattermost:  https://mattermost.${DOMAIN}"
  echo "    Kasm:        https://kasm.${DOMAIN}"
  echo "    GitLab:      https://gitlab.${DOMAIN} (external)"
  [[ "${DEPLOY_UPTIME_KUMA}" == "true" ]] && echo "    Uptime Kuma: https://status.${DOMAIN}"
  [[ "${DEPLOY_LIBRENMS}" == "true" ]] && echo "    LibreNMS:    https://librenms.${DOMAIN}"
  echo ""
  echo "  Credentials:"
  echo "    Vault root token:  ${vault_root_token}"
  echo "    ArgoCD admin:      admin / ${argocd_pass}"
  echo "    Harbor admin:      admin / ${harbor_pass}"
  echo "    Grafana admin:     admin / ${GRAFANA_ADMIN_PASSWORD:-N/A}"
  echo "    Kasm admin:        admin@kasm.local / ${kasm_pass}"
  echo "    Keycloak bootstrap: admin / CHANGEME_KC_ADMIN_PASSWORD (temporary — run setup-keycloak.sh)"
  echo "    Auth (prom/alertmanager/hubble/rollouts/traefik): via oauth2-proxy ForwardAuth"
  echo ""
  echo "  Vault PKI (External Root CA):"
  echo "    Root CA:         15yr validity (${ORG_NAME} Root CA, key offline)"
  echo "    Intermediate CA: 10yr validity (${ORG_NAME} Intermediate CA, key in Vault)"
  echo "    Leaf certs:      30d auto-renewed by cert-manager"
  echo "    ClusterIssuer:   vault-issuer (pki_int/sign/${DOMAIN_DOT})"
  echo ""

  # Extract and display Root CA
  local root_ca
  root_ca=$(extract_root_ca)
  if [[ -n "$root_ca" ]]; then
    echo "  Root CA Certificate (import into browser/OS trust store):"
    echo "$root_ca"
    echo ""
  fi

  echo -e "  ${YELLOW}Next steps:${NC}"
  echo "    1. Run: ./scripts/setup-gitlab.sh      (GitLab deployment)"
  echo "    2. Run: ./scripts/setup-cicd.sh        (ArgoCD + Rollouts integration)"
  echo "    3. Create DNS A records (see Phase 8 output above)"
  echo "    4. Import Root CA certificate above into your browser/OS trust store"
  echo ""

  # Write credentials file (includes Root CA)
  write_credentials_file

  # Clean up HTTPS check pod
  cleanup_check_pod

  if [[ $errors -gt 0 ]]; then
    log_error "Deployment completed with ${errors} error(s). Review above."
  else
    log_ok "All checks passed!"
  fi

  print_total_time
  end_phase "PHASE 9: VALIDATION"
}

# =============================================================================
# PHASE 10: KEYCLOAK OIDC SETUP
# =============================================================================
phase_10_keycloak_setup() {
  start_phase "PHASE 10: KEYCLOAK OIDC SETUP"

  log_step "Running Keycloak OIDC setup..."
  "${SCRIPT_DIR}/setup-keycloak.sh"

  # Deploy oauth2-proxy instances with per-service OIDC client secrets
  log_step "Configuring oauth2-proxy ForwardAuth..."
  local oidc_secrets_file="${SCRIPTS_DIR}/oidc-client-secrets.json"

  if [[ -f "$oidc_secrets_file" ]]; then
    local services=("prometheus-oidc" "alertmanager-oidc" "hubble-oidc" "traefik-dashboard-oidc" "rollouts-oidc")
    local namespaces=("monitoring" "monitoring" "kube-system" "kube-system" "argo-rollouts")
    local names=("prometheus" "alertmanager" "hubble" "traefik-dashboard" "rollouts")

    for i in "${!services[@]}"; do
      local client_id="${services[$i]}"
      local ns="${namespaces[$i]}"
      local name="${names[$i]}"
      local client_secret cookie_secret

      client_secret=$(jq -r ".[\"${client_id}\"] // empty" "$oidc_secrets_file")
      cookie_secret=$(openssl rand -base64 32 | tr -- '+/' '-_')

      if [[ -z "$client_secret" ]]; then
        log_warn "Client secret for ${client_id} not found — skipping oauth2-proxy-${name}"
        continue
      fi

      kubectl create secret generic "oauth2-proxy-${name}" \
        --namespace="${ns}" \
        --from-literal=client-secret="${client_secret}" \
        --from-literal=cookie-secret="${cookie_secret}" \
        --dry-run=client -o yaml | kubectl apply -f -
      log_ok "Secret oauth2-proxy-${name} created in ${ns}"
    done

    # Apply oauth2-proxy deployments + ForwardAuth middlewares
    kube_apply_subst "${SERVICES_DIR}/monitoring-stack/prometheus/oauth2-proxy.yaml"
    kube_apply_subst "${SERVICES_DIR}/monitoring-stack/prometheus/middleware-oauth2-proxy.yaml"
    kube_apply_subst "${SERVICES_DIR}/monitoring-stack/alertmanager/oauth2-proxy.yaml"
    kube_apply_subst "${SERVICES_DIR}/monitoring-stack/alertmanager/middleware-oauth2-proxy.yaml"
    kube_apply_subst "${SERVICES_DIR}/monitoring-stack/kube-system/oauth2-proxy-hubble.yaml"
    kube_apply_subst "${SERVICES_DIR}/monitoring-stack/kube-system/middleware-oauth2-proxy-hubble.yaml"
    kube_apply_subst "${SERVICES_DIR}/monitoring-stack/kube-system/oauth2-proxy-traefik-dashboard.yaml"
    kube_apply_subst "${SERVICES_DIR}/monitoring-stack/kube-system/middleware-oauth2-proxy-traefik-dashboard.yaml"
    kube_apply_subst "${SERVICES_DIR}/argo/argo-rollouts/oauth2-proxy.yaml"
    kube_apply_subst "${SERVICES_DIR}/argo/argo-rollouts/middleware-oauth2-proxy.yaml"
    log_ok "oauth2-proxy ForwardAuth configured for all protected services"
  else
    log_warn "oidc-client-secrets.json not found — oauth2-proxy auth will not work"
  fi

  end_phase "PHASE 10: KEYCLOAK OIDC SETUP"
}

# =============================================================================
# PHASE 11: GITLAB
# =============================================================================
phase_11_gitlab() {
  start_phase "PHASE 11: GITLAB"

  log_step "Running GitLab deployment..."
  "${SCRIPT_DIR}/setup-gitlab.sh"

  end_phase "PHASE 11: GITLAB"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
main() {
  echo -e "${BOLD}${BLUE}"
  echo "  ____  _  _______ ____    ____             _             "
  echo " |  _ \\| |/ / ____|___ \\  |  _ \\  ___ _ __ | | ___  _   _"
  echo " | |_) | ' /|  _|   __) | | | | |/ _ \\ '_ \\| |/ _ \\| | | |"
  echo " |  _ <| . \\| |___ / __/  | |_| |  __/ |_) | | (_) | |_| |"
  echo " |_| \\_\\_|\\_\\_____|_____| |____/ \\___| .__/|_|\\___/ \\__, |"
  echo "                                     |_|            |___/ "
  echo -e "${NC}"
  echo ""

  DEPLOY_START_TIME=$(date +%s)
  export DEPLOY_START_TIME

  # Pre-flight checks
  check_prerequisites

  # Generate or load credentials (replaces CHANGEME at apply time)
  generate_or_load_env

  # Execute phases
  if [[ "$SKIP_TERRAFORM" == "false" && $FROM_PHASE -le 0 ]]; then
    phase_0_terraform
  fi

  [[ $FROM_PHASE -le 1 ]] && phase_1_foundation
  [[ $FROM_PHASE -le 2 ]] && phase_2_vault
  [[ $FROM_PHASE -le 3 ]] && phase_3_monitoring
  [[ $FROM_PHASE -le 4 ]] && phase_4_harbor
  [[ $FROM_PHASE -le 5 ]] && phase_5_argocd
  [[ $FROM_PHASE -le 6 ]] && phase_6_keycloak
  [[ $FROM_PHASE -le 7 ]] && phase_7_remaining
  [[ $FROM_PHASE -le 8 ]] && phase_8_dns
  [[ $FROM_PHASE -le 9 ]] && phase_9_validation
  [[ $FROM_PHASE -le 10 ]] && phase_10_keycloak_setup
  [[ $FROM_PHASE -le 11 ]] && phase_11_gitlab
}

main "$@"
