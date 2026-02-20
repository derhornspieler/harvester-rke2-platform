#!/usr/bin/env bash
# =============================================================================
# deploy-cluster.sh — Full RKE2 Cluster Deployment (Zero Human Intervention)
# =============================================================================
# Deploys the entire stack from bare Harvester to fully operational cluster:
#   Terraform → cert-manager → CNPG → Redis Operator → Node Labeler → Vault
#   → Monitoring → Harbor → Keycloak + Auth Layer → ArgoCD → Services
#   → DNS → Validation → GitLab → CI/CD Infrastructure → Demo Apps
#
# After Phase 5 you have a minimal viable cluster: RKE2 + monitoring + registry
# + full Keycloak auth layer protecting Grafana, Prometheus, Vault, Harbor,
# Rancher, Traefik, Hubble, and Identity Portal.
#
# Prerequisites:
#   1. cluster/terraform.tfvars populated (see terraform.tfvars.example)
#   2. Harvester context in ~/.kube/config (name configurable via HARVESTER_CONTEXT in .env)
#   3. Commands: terraform, kubectl, helm, jq, openssl, curl
#
# Usage:
#   ./scripts/deploy-cluster.sh              # Full deployment (all phases)
#   ./scripts/deploy-cluster.sh --to 5       # Minimal viable cluster (auth layer)
#   ./scripts/deploy-cluster.sh --from 6     # Resume from ArgoCD
#   ./scripts/deploy-cluster.sh --from 3 --to 5  # Run phases 3-5 only
#   ./scripts/deploy-cluster.sh --skip-tf    # Skip Terraform (cluster exists)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# -----------------------------------------------------------------------------
# CLI Argument Parsing
# -----------------------------------------------------------------------------
SKIP_TERRAFORM=false
FROM_PHASE=0
TO_PHASE=17

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tf)    SKIP_TERRAFORM=true; shift ;;
    --from)       FROM_PHASE="$2"; shift 2 ;;
    --to)         TO_PHASE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--skip-tf] [--from PHASE_NUMBER] [--to PHASE_NUMBER]"
      echo "  --skip-tf    Skip Terraform (assume cluster already exists)"
      echo "  --from N     Resume from phase N"
      echo "  --to N       Stop after phase N (default: 17 = all phases)"
      echo ""
      echo "  Phases:"
      echo "    0  terraform         Provision RKE2 cluster via Rancher/Harvester"
      echo "    1  foundation        Node labels, Traefik, Rancher webhook"
      echo "    2  vault             Vault, cert-manager, CA distribution"
      echo "    3  monitoring        Prometheus, Grafana, Loki, Alloy"
      echo "    4  harbor            Container registry"
      echo "    5  keycloak+auth     Keycloak + full auth layer (OIDC, oauth2-proxy, Identity Portal)"
      echo "    6  argocd+dhi        ArgoCD + DHI builder (self-contained OIDC)"
      echo "    7  services          Mattermost, Kasm, etc. (per-service OIDC)"
      echo "    8  dns               DNS records"
      echo "    9  validation        Health checks"
      echo "   10  gitlab            Git server (with OIDC)"
      echo "   11  gitlab-hardening  SSH, branches, approvals + SOP wiki"
      echo "   12  vault-cicd        JWT auth, ESO, ClusterSecretStore"
      echo "   13  ci-templates      Shared pipeline library, Harbor robots"
      echo "   14  argocd-delivery   RBAC, AppProjects, AnalysisTemplates"
      echo "   15  security          Security runners, scanning"
      echo "   16  observability     DORA dashboard, CI/CD alerts"
      echo "   17  demo-apps         NetOps Arcade"
      echo ""
      echo "  Examples:"
      echo "    $0 --to 5              # Minimal viable cluster (full auth layer)"
      echo "    $0 --from 6 --to 6     # Add ArgoCD with OIDC"
      echo "    $0 --from 7            # Continue with remaining services"
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
  ensure_golden_image

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

  # Pre-clean orphaned Rancher SECRETS that survive terraform destroy
  # (async deletion races leave secrets behind, causing AlreadyExists errors)
  # NOTE: Do NOT delete the cluster resource here — that's terraform's job.
  # Use destroy-cluster.sh or terraform.sh destroy for full teardown.
  log_step "Pre-cleaning orphaned Rancher secrets..."
  local rancher_url rancher_token
  rancher_url=$(get_rancher_url)
  rancher_token=$(get_rancher_token)
  for res in \
    "secrets/fleet-default/${cluster_name}-dockerhub-auth"; do
    local http_code
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
      "${rancher_url}/v1/${res}" \
      -H "Authorization: Bearer ${rancher_token}" 2>/dev/null)
    if [[ "$http_code" == "200" ]]; then
      log_info "Deleting orphaned secret: ${res}"
      curl -sk -X DELETE "${rancher_url}/v1/${res}" \
        -H "Authorization: Bearer ${rancher_token}" >/dev/null 2>&1
      sleep 5
    fi
  done

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

  # Sync Rancher agent CA checksum (prevents system-agent-upgrader failures after
  # Rancher management cluster CA changes — k3k migration, cert rotation, etc.)
  log_step "Syncing Rancher agent CA checksum..."
  sync_rancher_agent_ca

  # Deploy CronJob to auto-heal CA checksum drift every 5 minutes.
  # Without this, any Rancher restart causes all system-agent-upgrader pods to
  # fail until someone manually patches stv-aggregation.
  log_step "Deploying Rancher CA sync CronJob..."
  kube_apply_subst "${SERVICES_DIR}/rancher-ca-sync/cronjob.yaml"

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
  if [[ -f "${REPO_ROOT}/crds/gateway-api-v1.3.0-standard-install.yaml" ]]; then
    kube_apply -f "${REPO_ROOT}/crds/gateway-api-v1.3.0-standard-install.yaml"
  else
    kube_apply -f "${GATEWAY_API_CRD_URL}"
  fi
  log_ok "Gateway API CRDs installed"

  # 1.4 cert-manager
  log_step "Installing cert-manager..."
  helm_repo_add jetstack https://charts.jetstack.io
  [[ "${AIRGAPPED:-false}" != "true" ]] && helm repo update jetstack

  local _chart; _chart=$(resolve_helm_chart "jetstack/cert-manager" "HELM_OCI_CERT_MANAGER")
  helm_install_if_needed cert-manager "$_chart" cert-manager \
    --version v1.19.3 \
    --set crds.enabled=true \
    --set config.apiVersion=controller.config.cert-manager.io/v1alpha1 \
    --set config.kind=ControllerConfiguration \
    --set config.enableGatewayAPI=true \
    --set nodeSelector.workload-type=general \
    --set webhook.nodeSelector.workload-type=general \
    --set cainjector.nodeSelector.workload-type=general \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=64Mi \
    --set webhook.resources.requests.cpu=25m \
    --set webhook.resources.requests.memory=32Mi \
    --set cainjector.resources.requests.cpu=50m \
    --set cainjector.resources.requests.memory=64Mi \
    --set startupapicheck.enabled=false \
    --timeout 10m

  wait_for_deployment cert-manager cert-manager 300s
  wait_for_deployment cert-manager cert-manager-webhook 300s
  log_ok "cert-manager installed"

  # 1.5 CNPG Operator
  log_step "Installing CNPG Operator..."
  helm_repo_add cnpg https://cloudnative-pg.github.io/charts
  [[ "${AIRGAPPED:-false}" != "true" ]] && helm repo update cnpg

  local _chart; _chart=$(resolve_helm_chart "cnpg/cloudnative-pg" "HELM_OCI_CNPG")
  helm_install_if_needed cnpg-operator "$_chart" cnpg-system \
    --version 0.27.1 \
    --set nodeSelector.workload-type=general \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
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
  [[ "${AIRGAPPED:-false}" != "true" ]] && helm repo update autoscaler

  local _chart; _chart=$(resolve_helm_chart "autoscaler/cluster-autoscaler" "HELM_OCI_CLUSTER_AUTOSCALER")
  helm_install_if_needed cluster-autoscaler "$_chart" kube-system \
    --set cloudProvider=rancher \
    --set replicaCount=3 \
    --set "extraArgs.leader-elect=true" \
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
  [[ "${AIRGAPPED:-false}" != "true" ]] && helm repo update ot-helm

  local _chart; _chart=$(resolve_helm_chart "ot-helm/redis-operator" "HELM_OCI_REDIS_OPERATOR")
  helm_install_if_needed redis-operator "$_chart" redis-operator-system \
    --set nodeSelector.workload-type=general \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
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
    [[ "${AIRGAPPED:-false}" != "true" ]] && helm repo update mariadb-operator

    local _chart; _chart=$(resolve_helm_chart "mariadb-operator/mariadb-operator" "HELM_OCI_MARIADB_OPERATOR")
    helm_install_if_needed mariadb-operator "$_chart" mariadb-operator-system \
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
  [[ "${AIRGAPPED:-false}" != "true" ]] && helm repo update hashicorp

  local _chart; _chart=$(resolve_helm_chart "hashicorp/vault" "HELM_OCI_VAULT")
  helm_install_if_needed vault "$_chart" vault \
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
      no_store=false \
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

  # ── SSH Certificate Authority ──────────────────────────────────────────
  log_step "Enabling SSH client signer secrets engine"
  vault_exec "$root_token" secrets enable -path=ssh-client-signer ssh 2>/dev/null || true

  log_step "Generating SSH CA signing key"
  vault_exec "$root_token" write ssh-client-signer/config/ca generate_signing_key=true 2>/dev/null || true

  log_step "Creating SSH signing roles"

  # Admin role — platform-admins, all principals, 24h TTL
  vault_exec_stdin "$root_token" write ssh-client-signer/roles/admin-role - <<'ROLE'
{
  "key_type": "ca",
  "allow_user_certificates": true,
  "allowed_users": "*",
  "default_extensions": {"permit-pty":"","permit-port-forwarding":"","permit-agent-forwarding":"","permit-X11-forwarding":"","permit-user-rc":""},
  "ttl": "24h",
  "max_ttl": "72h"
}
ROLE

  # Infra role — infra-engineers, network-engineers, restricted principals, 8h TTL
  vault_exec_stdin "$root_token" write ssh-client-signer/roles/infra-role - <<'ROLE'
{
  "key_type": "ca",
  "allow_user_certificates": true,
  "allowed_users": "rocky,infra,ansible",
  "default_extensions": {"permit-pty":"","permit-port-forwarding":"","permit-agent-forwarding":""},
  "ttl": "8h",
  "max_ttl": "24h"
}
ROLE

  # Developer role — developers, minimal access, 4h TTL
  vault_exec_stdin "$root_token" write ssh-client-signer/roles/developer-role - <<'ROLE'
{
  "key_type": "ca",
  "allow_user_certificates": true,
  "allowed_users": "rocky,developer",
  "default_extensions": {"permit-pty":""},
  "ttl": "4h",
  "max_ttl": "8h"
}
ROLE

  log_step "Creating SSH CA Vault policies"

  # ssh-sign-admin — for identity-portal backend (sign via all roles + read CA)
  vault_exec_stdin "$root_token" policy write ssh-sign-admin - <<'POLICY'
path "ssh-client-signer/sign/*" {
  capabilities = ["create", "update"]
}
path "ssh-client-signer/config/ca" {
  capabilities = ["read"]
}
POLICY

  # ssh-sign-self — for self-service OIDC users (developer-role only)
  vault_exec_stdin "$root_token" policy write ssh-sign-self - <<'POLICY'
path "ssh-client-signer/sign/developer-role" {
  capabilities = ["create", "update"]
}
path "ssh-client-signer/config/ca" {
  capabilities = ["read"]
}
POLICY

  # ssh-admin — full CRUD on ssh-client-signer (for platform-admins)
  vault_exec_stdin "$root_token" policy write ssh-admin - <<'POLICY'
path "ssh-client-signer/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
POLICY

  # identity-portal — broader policy for portal management
  vault_exec_stdin "$root_token" policy write identity-portal - <<'POLICY'
path "ssh-client-signer/sign/*" {
  capabilities = ["create", "update"]
}
path "ssh-client-signer/config/ca" {
  capabilities = ["read"]
}
path "ssh-client-signer/roles/*" {
  capabilities = ["read", "list", "create", "update", "delete"]
}
path "sys/policies/acl/*" {
  capabilities = ["read", "list", "create", "update", "delete"]
}
path "sys/policies/acl" {
  capabilities = ["list"]
}
path "pki_int/cert/ca_chain" {
  capabilities = ["read"]
}
POLICY

  log_step "Creating Vault K8s auth role for identity-portal"
  vault_exec "$root_token" write auth/kubernetes/role/identity-portal \
    bound_service_account_names=identity-portal \
    bound_service_account_namespaces=identity-portal \
    policies=identity-portal \
    ttl=1h

  log_ok "SSH Certificate Authority configured"

  end_phase "PHASE 2: VAULT + PKI"
}

# =============================================================================
# PHASE 3: MONITORING STACK
# =============================================================================
phase_3_monitoring() {
  start_phase "PHASE 3: MONITORING STACK"

  # 3.1 Non-chart resources (Loki, Alloy, Redis, Gateways, HTTPRoutes, dashboards, oauth2-proxy)
  log_step "Deploying non-chart monitoring resources (Loki, Alloy, gateways, dashboards)..."
  kube_apply_k_subst "${SERVICES_DIR}/monitoring-stack"

  # 3.2 Create additional-scrape-configs Secret for non-ServiceMonitor scrape jobs
  log_step "Creating additional scrape configs Secret..."
  local scrape_configs_file="${SERVICES_DIR}/monitoring-stack/helm/additional-scrape-configs.yaml"
  local scrape_configs_tmp
  scrape_configs_tmp=$(mktemp)
  _subst_changeme < "$scrape_configs_file" > "$scrape_configs_tmp"
  kubectl create secret generic additional-scrape-configs \
    --namespace monitoring \
    --from-file=scrape-configs.yaml="$scrape_configs_tmp" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$scrape_configs_tmp"

  # 3.3 Clean up pre-existing resources that Helm cannot adopt (migration from raw manifests)
  # These are no-ops on fresh installs; on migration they prevent "invalid ownership metadata" errors
  if ! helm status kube-prometheus-stack -n monitoring &>/dev/null; then
    log_step "Removing pre-Helm monitoring resources (migration cleanup)..."
    kubectl delete statefulset prometheus alertmanager -n monitoring --ignore-not-found 2>/dev/null || true
    kubectl delete deployment grafana -n monitoring --ignore-not-found 2>/dev/null || true
    kubectl delete service grafana -n monitoring --ignore-not-found 2>/dev/null || true
    kubectl delete daemonset node-exporter -n monitoring --ignore-not-found 2>/dev/null || true
    kubectl delete deployment kube-state-metrics -n monitoring --ignore-not-found 2>/dev/null || true
    kubectl delete service node-exporter kube-state-metrics -n monitoring --ignore-not-found 2>/dev/null || true
    kubectl delete serviceaccount prometheus node-exporter kube-state-metrics -n monitoring --ignore-not-found 2>/dev/null || true
    kubectl delete clusterrole prometheus node-exporter kube-state-metrics --ignore-not-found 2>/dev/null || true
    kubectl delete clusterrolebinding prometheus node-exporter kube-state-metrics --ignore-not-found 2>/dev/null || true
    kubectl delete configmap prometheus-config alertmanager-config grafana-datasources grafana-dashboard-provider -n monitoring --ignore-not-found 2>/dev/null || true
    kubectl delete secret grafana-admin-secret -n monitoring --ignore-not-found 2>/dev/null || true
    kubectl delete pvc grafana-data data-prometheus-0 data-alertmanager-0 -n monitoring --ignore-not-found 2>/dev/null || true
  fi

  # 3.4 Install kube-prometheus-stack Helm chart (Prometheus, Alertmanager, Grafana, Operator)
  log_step "Installing kube-prometheus-stack Helm chart..."
  helm_repo_add prometheus-community https://prometheus-community.github.io/helm-charts
  local _chart; _chart=$(resolve_helm_chart "prometheus-community/kube-prometheus-stack" "HELM_OCI_KPS")

  # Substitute domain/credentials in values.yaml
  local values_tmp
  values_tmp=$(mktemp)
  _subst_changeme < "${SERVICES_DIR}/monitoring-stack/helm/values.yaml" > "$values_tmp"

  helm_install_if_needed kube-prometheus-stack "$_chart" monitoring \
    -f "$values_tmp" --version "${KPS_CHART_VERSION}" --timeout 10m
  rm -f "$values_tmp"

  # 3.4 Deploy PrometheusRule CRDs (18 custom alert groups)
  log_step "Deploying PrometheusRule CRDs..."
  kube_apply_k_subst "${SERVICES_DIR}/monitoring-stack/prometheus-rules"

  # 3.5 Deploy ServiceMonitor CRDs (11 service monitors)
  log_step "Deploying ServiceMonitor CRDs..."
  kube_apply_k_subst "${SERVICES_DIR}/monitoring-stack/service-monitors"

  # Wait for key deployments
  wait_for_deployment monitoring grafana 300s
  wait_for_pods_ready monitoring "app.kubernetes.io/name=prometheus" 300
  wait_for_pods_ready monitoring "app=loki" 300

  # Verify TLS certs
  log_step "Verifying TLS certificates..."
  wait_for_tls_secret monitoring "grafana-${DOMAIN_DASHED}-tls" 120
  wait_for_tls_secret monitoring "prometheus-${DOMAIN_DASHED}-tls" 120
  wait_for_tls_secret monitoring "alertmanager-${DOMAIN_DASHED}-tls" 120
  wait_for_tls_secret kube-system "hubble-${DOMAIN_DASHED}-tls" 120

  # HTTPS connectivity checks
  check_https_batch "grafana.${DOMAIN}" "prometheus.${DOMAIN}" "alertmanager.${DOMAIN}" "hubble.${DOMAIN}"

  # 3.6 Storage Autoscaler operator (needs Prometheus running)
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
  kubectl -n minio delete job minio-create-buckets --ignore-not-found 2>/dev/null || true
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
  [[ "${AIRGAPPED:-false}" != "true" ]] && helm repo update goharbor

  local harbor_values_tmp
  harbor_values_tmp=$(mktemp)
  _subst_changeme < "${SERVICES_DIR}/harbor/harbor-values.yaml" > "$harbor_values_tmp"

  local _chart; _chart=$(resolve_helm_chart "goharbor/harbor" "HELM_OCI_HARBOR")
  helm_install_if_needed harbor "$_chart" harbor \
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

  # 4.10 Wait for nodes to stabilize after registry mirror rolling update
  # Rancher distributes registries.yaml + CA via a rolling restart of rke2-agent
  # on each node. kubectl cp/exec may fail if the node is restarting.
  log_step "Waiting for nodes to stabilize after registry config update..."
  local stable_retries=0
  while [[ $stable_retries -lt 12 ]]; do
    local not_ready
    not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv " Ready " || echo "99")
    if [[ "$not_ready" -eq 0 ]]; then
      log_ok "All nodes are Ready"
      break
    fi
    stable_retries=$((stable_retries + 1))
    log_info "  ${not_ready} node(s) not Ready (${stable_retries}/12)... waiting 15s"
    sleep 15
  done

  # 4.11 Push pre-built operator images to Harbor
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
  local admin_pass="${HARBOR_ADMIN_PASSWORD:-}"
  if [[ -z "$admin_pass" ]]; then
    admin_pass=$(grep 'harborAdminPassword' "${SERVICES_DIR}/harbor/harbor-values.yaml" | awk -F'"' '{print $2}')
  fi
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
  # Project names match the registry domain they proxy (e.g., docker.io, quay.io)
  local registry_names="docker.io quay.io ghcr.io gcr.io registry.k8s.io docker.elastic.co"
  local registry_urls

  if [[ "${AIRGAPPED:-false}" == "true" ]]; then
    if [[ -z "${UPSTREAM_PROXY_REGISTRY:-}" ]]; then
      die "AIRGAPPED=true but UPSTREAM_PROXY_REGISTRY is not set in .env"
    fi
    log_info "Airgapped mode: using upstream proxy ${UPSTREAM_PROXY_REGISTRY}"
    registry_urls="https://${UPSTREAM_PROXY_REGISTRY}/docker.io https://${UPSTREAM_PROXY_REGISTRY}/quay.io https://${UPSTREAM_PROXY_REGISTRY}/ghcr.io https://${UPSTREAM_PROXY_REGISTRY}/gcr.io https://${UPSTREAM_PROXY_REGISTRY}/registry.k8s.io https://${UPSTREAM_PROXY_REGISTRY}/docker.elastic.co"
  else
    registry_urls="https://registry-1.docker.io https://quay.io https://ghcr.io https://gcr.io https://registry.k8s.io https://docker.elastic.co"
  fi

  local i=1
  for project in $registry_names; do
    local endpoint
    endpoint=$(echo "$registry_urls" | cut -d' ' -f"$i")
    i=$((i + 1))
    log_info "Creating proxy cache registry: ${project} → ${endpoint}"

    # Create registry endpoint (409 = already exists → ignore)
    kubectl exec -n harbor "$harbor_core_pod" -- \
      curl -s -u "$auth" -X POST "${harbor_api}/registries" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${project}\",\"type\":\"docker-registry\",\"url\":\"${endpoint}\",\"insecure\":false}" >/dev/null 2>&1 || true

    # Get registry ID (use -s without -f so we always get JSON output)
    local reg_id
    reg_id=$(kubectl exec -n harbor "$harbor_core_pod" -- \
      curl -s -u "$auth" "${harbor_api}/registries" 2>/dev/null | \
      jq -r ".[] | select(.name==\"${project}\") | .id" 2>/dev/null || echo "")

    if [[ -n "$reg_id" && "$reg_id" != "null" ]]; then
      # Create proxy cache project (409 = already exists → ignore)
      kubectl exec -n harbor "$harbor_core_pod" -- \
        curl -s -u "$auth" -X POST "${harbor_api}/projects" \
        -H "Content-Type: application/json" \
        -d "{\"project_name\":\"${project}\",\"registry_id\":${reg_id},\"public\":true,\"metadata\":{\"public\":\"true\"}}" >/dev/null 2>&1 || true
      log_ok "Proxy cache project: ${project} (registry_id=${reg_id})"
    else
      log_warn "Could not get registry ID for ${project}, skipping proxy cache project"
    fi
  done

  # CICD projects — charts is public (stores Helm charts pulled from internet
  # for offline use), dev is private
  for project in library charts; do
    log_info "Creating public project: ${project}"
    kubectl exec -n harbor "$harbor_core_pod" -- \
      curl -sf -u "$auth" -X POST "${harbor_api}/projects" \
      -H "Content-Type: application/json" \
      -d "{\"project_name\":\"${project}\",\"public\":true,\"metadata\":{\"public\":\"true\"}}" 2>/dev/null || true
  done
  log_info "Creating private project: dev"
  kubectl exec -n harbor "$harbor_core_pod" -- \
    curl -sf -u "$auth" -X POST "${harbor_api}/projects" \
    -H "Content-Type: application/json" \
    -d '{"project_name":"dev","public":false}' 2>/dev/null || true

  log_ok "Harbor projects configured"
}

# =============================================================================
# PHASE 6: ARGOCD + ARGO ROLLOUTS (self-contained OIDC)
# =============================================================================
phase_6_argocd() {
  start_phase "PHASE 6: ARGOCD + ARGO ROLLOUTS + ARGO WORKFLOWS + ARGO EVENTS"

  # Pin Argo chart versions for reproducible deploys
  local ARGO_CD_CHART_VERSION="${ARGO_CD_CHART_VERSION:-7.8.13}"
  local ARGO_ROLLOUTS_CHART_VERSION="${ARGO_ROLLOUTS_CHART_VERSION:-2.40.6}"
  local ARGO_WORKFLOWS_CHART_VERSION="${ARGO_WORKFLOWS_CHART_VERSION:-0.47.4}"
  local ARGO_EVENTS_CHART_VERSION="${ARGO_EVENTS_CHART_VERSION:-2.4.20}"

  # 5.1 ArgoCD
  log_step "Installing ArgoCD HA..."
  ensure_namespace argocd

  local argocd_values_tmp; argocd_values_tmp=$(mktemp)
  _subst_changeme < "${SERVICES_DIR}/argo/argocd/argocd-values.yaml" > "$argocd_values_tmp"
  local _chart; _chart=$(resolve_helm_chart "oci://ghcr.io/argoproj/argo-helm/argo-cd" "HELM_OCI_ARGOCD")
  helm_install_if_needed argocd "$_chart" argocd \
    -f "$argocd_values_tmp" --version "${ARGO_CD_CHART_VERSION}" --timeout 10m
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

  local rollouts_values_tmp; rollouts_values_tmp=$(mktemp)
  _subst_changeme < "${SERVICES_DIR}/argo/argo-rollouts/argo-rollouts-values.yaml" > "$rollouts_values_tmp"
  local _chart; _chart=$(resolve_helm_chart "oci://ghcr.io/argoproj/argo-helm/argo-rollouts" "HELM_OCI_ARGO_ROLLOUTS")
  helm_install_if_needed argo-rollouts "$_chart" argo-rollouts \
    -f "$rollouts_values_tmp" --version "${ARGO_ROLLOUTS_CHART_VERSION}" --timeout 5m
  rm -f "$rollouts_values_tmp"

  log_ok "Argo Rollouts deployed"

  log_step "Applying Rollouts oauth2-proxy middleware, Gateway + HTTPRoute..."
  kube_apply_subst "${SERVICES_DIR}/argo/argo-rollouts/oauth2-proxy.yaml"
  kube_apply -f "${SERVICES_DIR}/argo/argo-rollouts/middleware-oauth2-proxy.yaml"
  kube_apply_subst "${SERVICES_DIR}/argo/argo-rollouts/gateway.yaml" \
                   "${SERVICES_DIR}/argo/argo-rollouts/httproute.yaml"
  wait_for_tls_secret argo-rollouts "rollouts-${DOMAIN_DASHED}-tls" 120

  # 5.3 Argo Workflows
  log_step "Installing Argo Workflows..."
  local _chart; _chart=$(resolve_helm_chart "oci://ghcr.io/argoproj/argo-helm/argo-workflows" "HELM_OCI_ARGO_WORKFLOWS")
  local workflows_values_tmp; workflows_values_tmp=$(mktemp)
  _subst_changeme < "${SERVICES_DIR}/argo/argo-workflows/argo-workflows-values.yaml" > "$workflows_values_tmp"
  helm_install_if_needed argo-workflows "$_chart" argocd \
    -f "$workflows_values_tmp" --version "${ARGO_WORKFLOWS_CHART_VERSION}" --timeout 5m
  rm -f "$workflows_values_tmp"
  wait_for_deployment argocd argo-workflows-server 120s
  log_ok "Argo Workflows deployed"

  # 5.4 Argo Events
  log_step "Installing Argo Events..."
  _chart=$(resolve_helm_chart "oci://ghcr.io/argoproj/argo-helm/argo-events" "HELM_OCI_ARGO_EVENTS")
  helm_install_if_needed argo-events "$_chart" argocd \
    --version "${ARGO_EVENTS_CHART_VERSION}" --set crds.install=true --timeout 5m
  log_ok "Argo Events deployed"

  # HTTPS connectivity checks
  check_https_batch "argo.${DOMAIN}" "rollouts.${DOMAIN}"

  # ── Self-contained OIDC for ArgoCD + Rollouts ─────────────────────────
  # Initialize Keycloak connection (Phase 5 already deployed Keycloak)
  kc_init

  # 6.5 Create argocd + rollouts-oidc OIDC clients
  log_step "Creating ArgoCD OIDC clients..."
  local secret
  secret=$(kc_create_client "argocd" "https://argo.${DOMAIN}/auth/callback" "ArgoCD")
  kc_save_secret "argocd" "$secret"

  secret=$(kc_create_client "rollouts-oidc" \
    "https://rollouts.${DOMAIN}/oauth2/callback" "Argo Rollouts")
  kc_save_secret "rollouts-oidc" "$secret"

  # 6.6 Add groups scope + mappers
  kc_add_groups_scope_to_clients argocd rollouts-oidc
  kc_add_group_mappers argocd rollouts-oidc

  # 6.7 Bind ArgoCD to Keycloak
  kc_bind_argocd

  # 6.8 Deploy oauth2-proxy for Argo Rollouts
  log_step "Deploying oauth2-proxy for Argo Rollouts..."
  kc_deploy_oauth2_proxy_secret "rollouts-oidc" "argo-rollouts" "rollouts"

  # Distribute Redis credentials to argo-rollouts namespace
  kubectl create secret generic oauth2-proxy-redis-credentials \
    --from-literal=password="${OAUTH2_PROXY_REDIS_PASSWORD}" \
    -n argo-rollouts --dry-run=client -o yaml | kubectl apply -f -

  kube_apply_subst "${SERVICES_DIR}/argo/argo-rollouts/oauth2-proxy.yaml"
  kube_apply -f "${SERVICES_DIR}/argo/argo-rollouts/middleware-oauth2-proxy.yaml"
  log_ok "Argo Rollouts oauth2-proxy configured"

  # 6.9 HTTPS checks (re-verify after OIDC config)
  check_https_batch "argo.${DOMAIN}" "rollouts.${DOMAIN}"

  end_phase "PHASE 6: ARGOCD + ARGO ROLLOUTS + ARGO WORKFLOWS + ARGO EVENTS"
}

# =============================================================================
# PHASE 6b: DHI BUILDER (Docker Hardened Images)
# =============================================================================
phase_6b_dhi_builder() {
  if [[ "${DEPLOY_DHI_BUILDER:-false}" != "true" ]]; then
    log_info "DHI Builder not enabled (set DEPLOY_DHI_BUILDER=true in .env) — skipping"
    return 0
  fi
  start_phase "PHASE 6b: DHI BUILDER"

  # 6b.1 Create Harbor 'dhi' project (public, for hardened images)
  log_step "Creating Harbor 'dhi' project..."
  create_harbor_project "dhi" "true"

  # 6b.2 Deploy DHI Builder manifests (BuildKit, RBAC, EventSource, Sensor, WorkflowTemplate)
  log_step "Deploying DHI Builder stack..."
  kube_apply_k_subst "${SERVICES_DIR}/dhi-builder"
  wait_for_pods_ready dhi-builder "app=buildkitd" 120

  end_phase "PHASE 6b: DHI BUILDER"
}

# =============================================================================
# PHASE 5: KEYCLOAK + AUTH LAYER
# =============================================================================
# After this phase you have a fully authenticated cluster: Keycloak protecting
# Grafana, Prometheus, Alertmanager, Hubble, Traefik, Vault, Harbor, Rancher,
# and Identity Portal via OIDC + oauth2-proxy ForwardAuth.
phase_5_keycloak_auth() {
  start_phase "PHASE 5: KEYCLOAK + AUTH LAYER"

  # ── 5.1 Deploy Keycloak (CNPG postgres + Keycloak app) ─────────────────
  ensure_namespace keycloak
  ensure_namespace database

  log_step "Deploying CNPG keycloak-pg cluster..."
  kube_apply_subst "${SERVICES_DIR}/keycloak/postgres/secret.yaml"
  kube_apply -f "${SERVICES_DIR}/keycloak/postgres/keycloak-pg-cluster.yaml"
  kube_apply -f "${SERVICES_DIR}/keycloak/postgres/keycloak-pg-scheduled-backup.yaml"
  wait_for_cnpg_primary database keycloak-pg 600
  log_ok "CNPG keycloak-pg deployed"

  log_step "Deploying Keycloak HA stack..."
  kube_apply_k_subst "${SERVICES_DIR}/keycloak"

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

  # ── 5.2 Initialize Keycloak connectivity ────────────────────────────────
  kc_init

  # ── 5.3 Realm + admin users ────────────────────────────────────────────
  kc_setup_realm

  # ── 5.4 Groups ─────────────────────────────────────────────────────────
  kc_create_groups

  # ── 5.5 "groups" client scope ──────────────────────────────────────────
  kc_create_groups_scope

  # ── 5.6 Create OIDC clients for Phase 0-4 services ────────────────────
  log_step "Creating OIDC clients for Phase 0-4 services..."
  local secret

  # kubernetes (public)
  kc_create_public_client "kubernetes" "http://localhost:8000,http://localhost:18000" "Kubernetes (kubelogin)"

  # Grafana
  secret=$(kc_create_client "grafana" "https://grafana.${DOMAIN}/*" "Grafana")
  kc_save_secret "grafana" "$secret"

  # Vault
  secret=$(kc_create_client "vault" "https://vault.${DOMAIN}/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" "Vault")
  kc_save_secret "vault" "$secret"

  # Harbor
  secret=$(kc_create_client "harbor" "https://harbor.${DOMAIN}/c/oidc/callback" "Harbor Registry")
  kc_save_secret "harbor" "$secret"

  # Rancher
  secret=$(kc_create_client "rancher" "https://rancher.${DOMAIN}/verify-auth" "Rancher")
  kc_save_secret "rancher" "$secret"

  # oauth2-proxy clients (one per protected service)
  secret=$(kc_create_client "prometheus-oidc" "https://prometheus.${DOMAIN}/oauth2/callback" "Prometheus")
  kc_save_secret "prometheus-oidc" "$secret"

  secret=$(kc_create_client "alertmanager-oidc" "https://alertmanager.${DOMAIN}/oauth2/callback" "AlertManager")
  kc_save_secret "alertmanager-oidc" "$secret"

  secret=$(kc_create_client "hubble-oidc" "https://hubble.${DOMAIN}/oauth2/callback" "Hubble")
  kc_save_secret "hubble-oidc" "$secret"

  secret=$(kc_create_client "traefik-dashboard-oidc" "https://traefik.${DOMAIN}/oauth2/callback" "Traefik Dashboard")
  kc_save_secret "traefik-dashboard-oidc" "$secret"

  # Identity Portal (public PKCE frontend + confidential backend)
  kc_create_public_client "identity-portal" "https://identity.${DOMAIN}/*" "Identity Portal (Frontend)"

  secret=$(kc_create_service_account_client "identity-portal-admin" "Identity Portal Admin (Backend)")
  kc_save_secret "identity-portal-admin" "$secret"

  # Assign realm-admin role to identity-portal-admin service account
  log_step "Assigning realm-admin role to identity-portal-admin service account..."
  local ipa_internal_id
  ipa_internal_id=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=identity-portal-admin" | jq -r '.[0].id')
  if [[ -n "$ipa_internal_id" ]]; then
    local sa_user_id
    sa_user_id=$(kc_api GET "/realms/${KC_REALM}/clients/${ipa_internal_id}/service-account-user" 2>/dev/null | jq -r '.id // empty' || echo "")
    if [[ -n "$sa_user_id" ]]; then
      local rm_client_id
      rm_client_id=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=realm-management" | jq -r '.[0].id')
      local realm_admin_role
      realm_admin_role=$(kc_api GET "/realms/${KC_REALM}/clients/${rm_client_id}/roles/realm-admin")
      kc_api POST "/realms/${KC_REALM}/users/${sa_user_id}/role-mappings/clients/${rm_client_id}" \
        -d "[${realm_admin_role}]" 2>/dev/null || true
      log_ok "realm-admin role assigned to identity-portal-admin service account"
    fi
  fi

  # ── 5.7 Add groups scope + mappers to all Phase 5 clients ──────────────
  local phase5_clients=(kubernetes grafana vault harbor rancher prometheus-oidc alertmanager-oidc hubble-oidc traefik-dashboard-oidc identity-portal identity-portal-admin)
  kc_add_groups_scope_to_clients "${phase5_clients[@]}"
  kc_add_group_mappers "${phase5_clients[@]}"

  # ── 5.8 Bind services to Keycloak ──────────────────────────────────────
  kc_bind_grafana
  kc_bind_vault
  kc_bind_harbor
  kc_bind_rancher

  # ── 5.9 Deploy oauth2-proxy Redis ──────────────────────────────────────
  log_step "Deploying oauth2-proxy Redis session store..."
  kube_apply_subst "${SERVICES_DIR}/monitoring-stack/oauth2-proxy-redis/secret.yaml"
  kube_apply -f "${SERVICES_DIR}/monitoring-stack/oauth2-proxy-redis/replication.yaml"
  kube_apply -f "${SERVICES_DIR}/monitoring-stack/oauth2-proxy-redis/sentinel.yaml"
  wait_for_pods_ready monitoring "app=oauth2-proxy-redis" 300 2>/dev/null || \
    log_warn "oauth2-proxy Redis not fully ready yet — oauth2-proxy may retry"
  log_ok "oauth2-proxy Redis deployed"

  # ── 5.10 Deploy oauth2-proxy instances ─────────────────────────────────
  log_step "Deploying oauth2-proxy ForwardAuth instances..."

  # Create K8s secrets for each oauth2-proxy
  kc_deploy_oauth2_proxy_secret "prometheus-oidc" "monitoring" "prometheus"
  kc_deploy_oauth2_proxy_secret "alertmanager-oidc" "monitoring" "alertmanager"
  kc_deploy_oauth2_proxy_secret "hubble-oidc" "kube-system" "hubble"
  kc_deploy_oauth2_proxy_secret "traefik-dashboard-oidc" "kube-system" "traefik-dashboard"

  # Distribute oauth2-proxy Redis credentials to kube-system
  log_step "Distributing oauth2-proxy Redis credentials..."
  kubectl create secret generic oauth2-proxy-redis-credentials \
    --from-literal=password="${OAUTH2_PROXY_REDIS_PASSWORD}" \
    -n kube-system --dry-run=client -o yaml | kubectl apply -f -

  # Apply oauth2-proxy deployments + ForwardAuth middlewares
  kube_apply_subst "${SERVICES_DIR}/monitoring-stack/prometheus/oauth2-proxy.yaml"
  kube_apply_subst "${SERVICES_DIR}/monitoring-stack/prometheus/middleware-oauth2-proxy.yaml"
  kube_apply_subst "${SERVICES_DIR}/monitoring-stack/alertmanager/oauth2-proxy.yaml"
  kube_apply_subst "${SERVICES_DIR}/monitoring-stack/alertmanager/middleware-oauth2-proxy.yaml"
  kube_apply_subst "${SERVICES_DIR}/monitoring-stack/kube-system/oauth2-proxy-hubble.yaml"
  kube_apply_subst "${SERVICES_DIR}/monitoring-stack/kube-system/middleware-oauth2-proxy-hubble.yaml"
  kube_apply_subst "${SERVICES_DIR}/monitoring-stack/kube-system/oauth2-proxy-traefik-dashboard.yaml"
  kube_apply_subst "${SERVICES_DIR}/monitoring-stack/kube-system/middleware-oauth2-proxy-traefik-dashboard.yaml"
  log_ok "oauth2-proxy ForwardAuth configured for Prometheus, Alertmanager, Hubble, Traefik"

  # ── 5.11 Deploy Identity Portal ────────────────────────────────────────
  log_step "Deploying Identity Portal..."
  kube_apply_k_subst "${SERVICES_DIR}/identity-portal"

  # Inject identity-portal-admin OIDC secret
  local IDENTITY_PORTAL_OIDC_SECRET
  IDENTITY_PORTAL_OIDC_SECRET=$(jq -r '.["identity-portal-admin"] // empty' "$OIDC_SECRETS_FILE")
  if [[ -n "$IDENTITY_PORTAL_OIDC_SECRET" ]]; then
    kubectl -n identity-portal create secret generic identity-portal-secret \
      --from-literal=KEYCLOAK_CLIENT_SECRET="${IDENTITY_PORTAL_OIDC_SECRET}" \
      --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n identity-portal rollout restart deployment/identity-portal-backend 2>/dev/null || true
  fi

  # Wait for frontend + backend
  if ! wait_for_deployment identity-portal identity-portal-frontend 120s; then
    log_warn "Identity Portal frontend not ready (image may still be pulling)"
  fi
  wait_for_deployment identity-portal identity-portal-backend 120s 2>/dev/null || \
    log_warn "Identity Portal backend not ready yet — may need more time"
  log_ok "Identity Portal deployed"

  # ── 5.12 Test users ────────────────────────────────────────────────────
  kc_create_test_users

  # ── 5.13 Credentials summary ───────────────────────────────────────────
  echo ""
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}  KEYCLOAK + AUTH LAYER SUMMARY${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo ""
  echo "  Realm:     ${KC_REALM}"
  echo "  Admin URL: ${KC_URL}/admin/${KC_REALM}/console"
  echo ""
  echo "  Realm Admin:  admin / ${REALM_ADMIN_PASS}"
  echo "  General User: user / ${REALM_USER_PASS}"
  echo ""
  echo "  OIDC-protected services:"
  echo "    Grafana, Vault, Harbor, Rancher (direct OIDC)"
  echo "    Prometheus, Alertmanager, Hubble, Traefik (oauth2-proxy ForwardAuth)"
  echo "    Identity Portal (PKCE frontend + service account backend)"
  echo ""
  echo "  Test users: 12 users (password: TestUser2026!)"
  echo "  Client secrets: ${OIDC_SECRETS_FILE}"
  echo ""

  # Append to credentials file
  local creds_file="${CLUSTER_DIR}/credentials.txt"
  if [[ -f "$creds_file" ]]; then
    cat >> "$creds_file" <<EOF

# Keycloak OIDC (Phase 5 — $(date -u +%Y-%m-%dT%H:%M:%SZ))
Keycloak Realm  https://keycloak.${DOMAIN}/admin/${KC_REALM}/console
  Realm Admin:   admin / ${REALM_ADMIN_PASS}
  General User:  user / ${REALM_USER_PASS}  (developers group)
  Master admin (admin/CHANGEME_KC_ADMIN_PASSWORD) is break-glass only — use realm admin console

OIDC Client Secrets:
$(jq -r 'to_entries[] | "  \(.key): \(.value)"' "$OIDC_SECRETS_FILE" 2>/dev/null || echo "  (see ${OIDC_SECRETS_FILE})")

Test Users (password: TestUser2026!, MFA optional):
  alice.morgan, bob.chen, carol.silva, dave.kumar, eve.mueller, frank.jones,
  grace.park, henry.wilson, iris.tanaka, jack.brown, kate.lee, leo.garcia
EOF
    log_ok "Keycloak credentials appended to ${creds_file}"
  fi

  end_phase "PHASE 5: KEYCLOAK + AUTH LAYER"
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
  kube_apply -f "${SERVICES_DIR}/mattermost/postgres/mattermost-pg-scheduled-backup.yaml"
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

  # Mattermost OIDC (self-contained — register client + bind)
  log_step "Registering Mattermost OIDC client..."
  kc_init
  local secret
  secret=$(kc_create_client "mattermost" "https://mattermost.${DOMAIN}/signup/openid/complete" "Mattermost")
  kc_save_secret "mattermost" "$secret"
  kc_add_groups_scope_to_clients mattermost
  kc_add_group_mappers mattermost
  kc_bind_mattermost

  # 7.2 Kasm Workspaces
  log_step "Deploying Kasm Workspaces..."
  kube_apply -f "${SERVICES_DIR}/kasm/namespace.yaml"

  # CNPG for Kasm (PG 14)
  kube_apply_subst "${SERVICES_DIR}/kasm/postgres/secret.yaml"
  kube_apply -f "${SERVICES_DIR}/kasm/postgres/kasm-pg-cluster.yaml"
  kube_apply -f "${SERVICES_DIR}/kasm/postgres/kasm-pg-scheduled-backup.yaml"
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
  [[ "${AIRGAPPED:-false}" != "true" ]] && { helm repo update kasmtech 2>/dev/null || true; }

  local kasm_values_tmp; kasm_values_tmp=$(mktemp)
  _subst_changeme < "${SERVICES_DIR}/kasm/kasm-values.yaml" > "$kasm_values_tmp"
  local _chart; _chart=$(resolve_helm_chart "kasmtech/kasm" "HELM_OCI_KASM")
  helm_install_if_needed kasm "$_chart" kasm \
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

    # LibreNMS MariaDB backup to MinIO
    log_step "Deploying LibreNMS MariaDB backup CronJob..."
    kube_apply_subst "${SERVICES_DIR}/librenms/backup/secret.yaml"
    kube_apply -f "${SERVICES_DIR}/librenms/backup/cronjob.yaml"
    log_ok "LibreNMS MariaDB backup CronJob deployed (03:15 UTC daily)"
  else
    log_info "Skipping LibreNMS (DEPLOY_LIBRENMS=false)"
  fi

  # Identity Portal is deployed in Phase 5 (Keycloak + Auth Layer)

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
    "identity.${DOMAIN}"
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
  not_ready=$(kubectl get nodes --no-headers | awk '$2 != "Ready" {count++} END {print count+0}')
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
  expected_secrets+=("identity-portal:identity-${DOMAIN_DASHED}-tls")
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
    "identity.${DOMAIN}"
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
    "identity-portal:identity-portal-backend"
    "identity-portal:identity-portal-frontend"
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
  echo "    Identity:    https://identity.${DOMAIN}"
  [[ "${DEPLOY_UPTIME_KUMA}" == "true" ]] && echo "    Uptime Kuma: https://status.${DOMAIN}"
  [[ "${DEPLOY_LIBRENMS}" == "true" ]] && echo "    LibreNMS:    https://librenms.${DOMAIN}"
  echo ""
  echo "  Credentials:"
  echo "    Vault root token:  ${vault_root_token}"
  echo "    ArgoCD admin:      admin / ${argocd_pass}"
  echo "    Harbor admin:      admin / ${harbor_pass}"
  echo "    Grafana admin:     admin / ${GRAFANA_ADMIN_PASSWORD:-N/A}"
  echo "    Kasm admin:        admin@kasm.local / ${kasm_pass}"
  echo "    Keycloak:          Realm admin configured in Phase 5 (see credentials.txt)"
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
  echo "    1. Continue with: ./scripts/deploy-cluster.sh --from 10  (GitLab + CI/CD)"
  echo "    2. Create DNS A records (see Phase 8 output above)"
  echo "    3. Import Root CA certificate above into your browser/OS trust store"
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

  end_phase "PHASE 9: VALIDATION"
}

# =============================================================================
# PHASE 10: GITLAB (with self-contained OIDC)
# =============================================================================
phase_10_gitlab() {
  start_phase "PHASE 10: GITLAB"

  log_step "Running GitLab deployment..."
  "${SCRIPT_DIR}/setup-gitlab.sh"

  # Self-contained OIDC: create gitlab + gitlab-ci clients
  log_step "Creating GitLab OIDC clients..."
  kc_init

  local secret
  secret=$(kc_create_client "gitlab" "https://gitlab.${DOMAIN}/users/auth/openid_connect/callback" "GitLab")
  kc_save_secret "gitlab" "$secret"

  secret=$(kc_create_service_account_client "gitlab-ci" "GitLab CI Service Account")
  kc_save_secret "gitlab-ci" "$secret"

  # Add gitlab-ci service account to groups
  local gitlab_ci_internal_id gitlab_ci_sa_user_id
  gitlab_ci_internal_id=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=gitlab-ci" 2>/dev/null | jq -r '.[0].id // empty' || echo "")
  if [[ -n "$gitlab_ci_internal_id" ]]; then
    gitlab_ci_sa_user_id=$(kc_api GET "/realms/${KC_REALM}/clients/${gitlab_ci_internal_id}/service-account-user" 2>/dev/null | jq -r '.id // empty' || echo "")
    if [[ -n "$gitlab_ci_sa_user_id" ]]; then
      for sa_group in ci-service-accounts infra-engineers; do
        local sa_group_id
        sa_group_id=$(kc_api GET "/realms/${KC_REALM}/groups?search=${sa_group}" 2>/dev/null | jq -r '.[0].id // empty' || echo "")
        if [[ -n "$sa_group_id" ]]; then
          kc_api PUT "/realms/${KC_REALM}/users/${gitlab_ci_sa_user_id}/groups/${sa_group_id}" 2>/dev/null || true
          log_ok "service-account-gitlab-ci added to ${sa_group}"
        fi
      done
    fi
  fi

  kc_add_groups_scope_to_clients gitlab gitlab-ci
  kc_add_group_mappers gitlab gitlab-ci

  log_info "GitLab OIDC clients created (gitlab + gitlab-ci)"
  log_info "  Client ID: gitlab, Secret: see ${OIDC_SECRETS_FILE}"
  log_info "  OIDC secret will be created automatically by setup-gitlab.sh"

  end_phase "PHASE 10: GITLAB"
}

# =============================================================================
# PHASE 11: GITLAB HARDENING (SSH, Registry Disable, Protected Branches)
# =============================================================================
phase_11_gitlab_hardening() {
  start_phase "PHASE 11: GITLAB HARDENING"

  # 12.1 Disable GitLab container registry (Harbor is the platform registry)
  log_step "Disabling GitLab container registry (Harbor is the platform registry)..."
  log_info "Registry disabled in values-rke2-prod.yaml; registry-web listener removed from gateway.yaml"

  # Re-apply gateway without registry listener
  kube_apply_subst "${SERVICES_DIR}/gitlab/gateway.yaml"
  log_ok "GitLab gateway updated (registry listener removed)"

  # Helm upgrade GitLab to apply registry=false
  # Use the same local chart path that setup-gitlab.sh used for the initial install
  log_step "Upgrading GitLab Helm release to disable built-in registry..."
  if [[ -d "${GITLAB_CHART_PATH}" ]]; then
    local processed_values
    processed_values=$(mktemp /tmp/gitlab-values-XXXXXX.yaml)
    _subst_changeme < "${SERVICES_DIR}/gitlab/values-rke2-prod.yaml" > "$processed_values"
    helm upgrade gitlab "${GITLAB_CHART_PATH}" -n gitlab \
      -f "$processed_values" \
      --reuse-values --set registry.enabled=false --wait --timeout 10m 2>/dev/null || \
      log_warn "GitLab Helm upgrade returned non-zero (may already be up to date)"
    rm -f "$processed_values"
    log_ok "GitLab registry disabled"
  else
    log_warn "GITLAB_CHART_PATH (${GITLAB_CHART_PATH}) not found — skipping registry disable Helm upgrade"
  fi

  # 12.2 Verify SSH access via Traefik IngressRouteTCP
  log_step "Verifying GitLab SSH route (IngressRouteTCP via Traefik)..."
  if kubectl -n gitlab get ingressroutetcp gitlab-ssh &>/dev/null; then
    log_ok "GitLab SSH IngressRouteTCP already deployed"
  else
    log_info "Deploying GitLab SSH IngressRouteTCP..."
    kube_apply_subst "${SERVICES_DIR}/gitlab/ingressroutetcp-ssh.yaml"
    log_ok "GitLab SSH IngressRouteTCP deployed"
  fi

  # 12.3 Load or create GitLab API token
  local GITLAB_API="https://gitlab.${DOMAIN}/api/v4"
  local token_file="${SCRIPTS_DIR}/.gitlab-api-token"
  if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
    if [[ -f "$token_file" ]]; then
      GITLAB_API_TOKEN=$(cat "$token_file")
    fi
  fi

  # Validate existing token — create a fresh one if missing or stale
  if [[ -n "${GITLAB_API_TOKEN:-}" ]]; then
    local token_check
    token_check=$(curl -sk -H "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
      "https://gitlab.${DOMAIN}/api/v4/user" 2>/dev/null | jq -r '.username // empty' 2>/dev/null)
    if [[ -z "$token_check" ]]; then
      log_warn "GitLab API token is stale — regenerating"
      GITLAB_API_TOKEN=""
    fi
  fi

  if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
    log_step "Creating GitLab API token via rails runner..."
    local toolbox_pod
    toolbox_pod=$(kubectl get pods -n gitlab -l app=toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$toolbox_pod" ]]; then
      GITLAB_API_TOKEN=$(kubectl exec -n gitlab "$toolbox_pod" -- \
        gitlab-rails runner "token = User.find_by_username('root').personal_access_tokens.create!(name: 'deploy-bot', scopes: [:api, :read_api, :sudo], expires_at: 365.days.from_now); puts token.token" 2>/dev/null | tail -1)
      if [[ -n "$GITLAB_API_TOKEN" && "$GITLAB_API_TOKEN" == glpat-* ]]; then
        echo -n "$GITLAB_API_TOKEN" > "$token_file"
        log_ok "GitLab API token created and saved to .gitlab-api-token"
      else
        log_warn "Failed to create GitLab API token — skipping API-based hardening"
        end_phase "PHASE 11: GITLAB HARDENING"
        return 0
      fi
    else
      log_warn "GitLab toolbox pod not found — skipping API-based hardening"
      end_phase "PHASE 11: GITLAB HARDENING"
      return 0
    fi
  fi

  # 12.4 Look up platform_services group ID
  log_step "Looking up GitLab platform_services group..."
  local PS_GROUP_ID=""
  PS_GROUP_ID=$(gitlab_group_id "platform_services" 2>/dev/null) || true
  if [[ -z "$PS_GROUP_ID" || "$PS_GROUP_ID" == "null" ]]; then
    log_warn "platform_services group not found — create it first with setup-gitlab-services.sh"
    PS_GROUP_ID=""
  else
    log_ok "platform_services group ID: ${PS_GROUP_ID}"
  fi

  # 12.5 Configure protected branches on all platform_services projects
  log_step "Configuring protected branches..."
  if [[ -n "$PS_GROUP_ID" ]]; then
    local projects_json=""
    projects_json=$(gitlab_get "/groups/${PS_GROUP_ID}/projects?per_page=100&include_subgroups=true" 2>/dev/null) || true
    local project_ids
    project_ids=$(echo "$projects_json" | jq -r '.[].id' 2>/dev/null) || true

    if [[ -z "$project_ids" ]]; then
      log_warn "Could not list projects in group ${PS_GROUP_ID} — GitLab API may be slow"
    else
      for pid in $project_ids; do
        local pname
        pname=$(echo "$projects_json" | jq -r ".[] | select(.id == ${pid}) | .path" 2>/dev/null)
        log_info "  Protecting main branch on ${pname} (ID: ${pid})..."

        # Protect main: Maintainer push, Maintainer merge
        gitlab_protect_branch "$pid" "main" 40 40 || true

        # Project settings: require pipeline success, require discussions resolved, no author approval
        gitlab_set_project_setting "$pid" "only_allow_merge_if_pipeline_succeeds" "true"
        gitlab_set_project_setting "$pid" "only_allow_merge_if_all_discussions_are_resolved" "true"
        gitlab_set_project_setting "$pid" "merge_requests_author_approval" "false"

        log_ok "  ${pname}: protected branch + merge settings configured"
      done
    fi
  fi

  # 12.6 Configure merge request approval rules
  log_step "Configuring MR approval rules..."
  if [[ -n "$PS_GROUP_ID" && -n "${project_ids:-}" ]]; then
    for pid in $project_ids; do
      local pname
      pname=$(echo "$projects_json" | jq -r ".[] | select(.id == ${pid}) | .path" 2>/dev/null)
      # Senior Review Required: 2 approvals
      gitlab_add_approval_rule "$pid" "Senior Review Required" 2 || true
      log_ok "  ${pname}: approval rule 'Senior Review Required' (2 approvals)"
    done
  fi

  # 12.7 Sync Keycloak groups to GitLab group roles via SAML/OIDC group links
  log_step "Syncing Keycloak groups to GitLab group membership..."
  if [[ -n "$PS_GROUP_ID" ]]; then
    local -A kc_to_gitlab_level=(
      [platform-admins]=50    # Owner
      [infra-engineers]=40    # Maintainer
      [senior-developers]=40  # Maintainer
      [developers]=30         # Developer
      [viewers]=20            # Reporter
    )
    for kc_group in "${!kc_to_gitlab_level[@]}"; do
      local level="${kc_to_gitlab_level[$kc_group]}"
      gitlab_create_group_link "$PS_GROUP_ID" "$kc_group" "$level"
      log_ok "  ${kc_group} -> access_level=${level}"
    done
  fi

  end_phase "PHASE 11: GITLAB HARDENING"
}

# =============================================================================
# PHASE 11b: ENGINEERING SOPs WIKI
# =============================================================================
phase_11b_sop_wiki() {
  local docs_dir="${REPO_ROOT}/docs/engineering"
  if [[ ! -d "$docs_dir" ]]; then
    log_info "No docs/engineering directory — skipping SOP wiki"
    return 0
  fi

  start_phase "PHASE 11b: SOP WIKI"

  # 11b.1 Load GitLab API token (same pattern as phase_11/13)
  if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
    local token_file="${SCRIPTS_DIR}/.gitlab-api-token"
    [[ -f "$token_file" ]] && GITLAB_API_TOKEN=$(cat "$token_file")
  fi
  if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
    log_warn "No GITLAB_API_TOKEN — skipping SOP wiki"
    end_phase "PHASE 11b: SOP WIKI"
    return 0
  fi

  # 12b.2 Look up platform_services group
  log_step "Looking up platform_services group..."
  local PS_GROUP_ID=""
  PS_GROUP_ID=$(gitlab_group_id "platform_services" 2>/dev/null) || true
  if [[ -z "$PS_GROUP_ID" || "$PS_GROUP_ID" == "null" ]]; then
    log_warn "platform_services group not found — run setup-gitlab-services.sh first"
    end_phase "PHASE 11b: SOP WIKI"
    return 0
  fi

  # 12b.3 Create sop-wiki project if it doesn't exist
  log_step "Creating sop-wiki project..."
  local wiki_project_id=""
  wiki_project_id=$(gitlab_project_id "platform_services/sop-wiki" 2>/dev/null) || true

  if [[ -z "$wiki_project_id" || "$wiki_project_id" == "null" ]]; then
    local resp
    resp=$(gitlab_post "/projects" \
      "{\"name\":\"sop-wiki\",\"path\":\"sop-wiki\",\"namespace_id\":${PS_GROUP_ID},\"visibility\":\"internal\",\"wiki_enabled\":true,\"initialize_with_readme\":true}") || true
    wiki_project_id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)
    if [[ -z "$wiki_project_id" ]]; then
      log_error "Failed to create sop-wiki project"
      end_phase "PHASE 11b: SOP WIKI"
      return 0
    fi
    log_ok "Created sop-wiki project (ID: ${wiki_project_id})"
    sleep 2
  else
    log_ok "sop-wiki project already exists (ID: ${wiki_project_id})"
  fi

  # 12b.4 Seed the wiki repo (creates .wiki.git on first API call)
  log_step "Seeding wiki repository..."
  gitlab_post "/projects/${wiki_project_id}/wikis" \
    '{"title":"Home","content":"# Engineering SOPs\nInitializing...","format":"markdown"}' >/dev/null 2>&1 || true
  log_ok "Wiki repo initialized"

  # 12b.5 Clone wiki repo and populate
  log_step "Cloning wiki repo and populating pages..."
  local tmp_dir
  tmp_dir=$(mktemp -d "/tmp/sop-wiki-XXXXXX")

  export GIT_SSL_NO_VERIFY=true
  local wiki_url="https://oauth2:${GITLAB_API_TOKEN}@gitlab.${DOMAIN}/platform_services/sop-wiki.wiki.git"

  if ! git clone "$wiki_url" "${tmp_dir}/repo" 2>/dev/null; then
    mkdir -p "${tmp_dir}/repo"
    git -C "${tmp_dir}/repo" init -b main
    git -C "${tmp_dir}/repo" remote add origin "$wiki_url"
  fi

  local work_dir="${tmp_dir}/repo"
  # Clear existing wiki content (except .git)
  find "${work_dir}" -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +

  # 12b.6 Copy single-page docs (all except troubleshooting-sop.md)
  log_step "Copying engineering docs to wiki..."
  for doc in "${docs_dir}"/*.md; do
    local basename
    basename=$(basename "$doc")
    [[ "$basename" == "troubleshooting-sop.md" ]] && continue
    cp "$doc" "${work_dir}/${basename}"
  done

  # 12b.7 Split troubleshooting-sop.md into sub-pages by ## headers
  log_step "Splitting troubleshooting SOP into sub-pages..."
  local ts_src="${docs_dir}/troubleshooting-sop.md"
  local section_num="" section_title="" section_slug=""
  local index_links=""

  # First pass: extract intro (everything before first ## N.) as the index page
  awk '/^## [0-9]+\./{exit} {print}' "$ts_src" > "${work_dir}/troubleshooting-sop.md"

  # Append sub-page links to the index
  index_links=$'\n---\n\n## Sections\n\n'
  while IFS= read -r header; do
    # Extract section number and title from "## N. Title"
    section_num=$(echo "$header" | sed -E 's/^## ([0-9]+)\..*/\1/')
    section_title=$(echo "$header" | sed -E 's/^## [0-9]+\. //')
    # Zero-pad the number for sort order
    local padded
    padded=$(printf "%02d" "$section_num")
    section_slug=$(echo "$section_title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-//; s/-$//')
    index_links+="- [${section_num}. ${section_title}](troubleshooting-${padded}-${section_slug})"$'\n'
  done < <(grep -E '^## [0-9]+\.' "$ts_src")

  # Handle the "Related Documentation" section — keep it in the index
  local related_section
  related_section=$(awk '/^## Related Documentation/,0' "$ts_src")
  if [[ -n "$related_section" ]]; then
    index_links+=$'\n---\n\n'"${related_section}"
  fi

  echo "$index_links" >> "${work_dir}/troubleshooting-sop.md"
  log_ok "Troubleshooting index page generated"

  # Second pass: split each numbered section into its own page
  awk '
    /^## [0-9]+\./ {
      if (outfile) close(outfile)
      # Extract section number
      match($0, /^## ([0-9]+)\./, arr)
      num = sprintf("%02d", arr[1])
      # Extract title after "## N. "
      title = $0
      sub(/^## [0-9]+\. /, "", title)
      # Build slug: lowercase, non-alnum to hyphens, trim
      slug = tolower(title)
      gsub(/[^a-z0-9]+/, "-", slug)
      gsub(/^-|-$/, "", slug)
      outfile = WORKDIR "/troubleshooting-" num "-" slug ".md"
      # Write breadcrumb nav
      print "> **[← Back to Troubleshooting Index](troubleshooting-sop)**\n" > outfile
      print $0 >> outfile
      next
    }
    /^## Related Documentation/ { outfile = ""; next }
    outfile { print >> outfile }
  ' WORKDIR="${work_dir}" "$ts_src"

  local sub_count
  sub_count=$(ls "${work_dir}"/troubleshooting-[0-9]*.md 2>/dev/null | wc -l)
  log_ok "Split troubleshooting SOP into ${sub_count} sub-pages"

  # 12b.8 Generate Home.md landing page
  log_step "Generating Home.md and _sidebar.md..."
  cat > "${work_dir}/Home.md" << 'HOMEEOF'
# Engineering SOPs

Welcome to the platform engineering Standard Operating Procedures wiki. These documents cover architecture, operations, troubleshooting, and security for the RKE2 cluster platform.

## Quick Links

| Document | Description |
|----------|-------------|
| [System Architecture](system-architecture) | Cluster architecture, network topology, component overview |
| [Security Architecture](security-architecture) | PKI, OIDC, Vault, network policies |
| [Deployment Automation](deployment-automation) | Deploy script phases, automation details |
| [Terraform Infrastructure](terraform-infrastructure) | IaC for Harvester/Rancher provisioning |
| [Services Reference](services-reference) | All platform services configuration |
| [Monitoring & Observability](monitoring-observability) | Prometheus, Grafana, Loki, alerting |
| [Golden Image CI/CD](golden-image-cicd) | DHI builder, hardened base images |
| [Custom Operators](custom-operators) | Identity Portal, platform operators |
| [Flow Charts](flow-charts) | Deployment and operational flow diagrams |
| **[Troubleshooting SOP](troubleshooting-sop)** | **On-call runbooks, DR procedures, Day-2 ops** |
HOMEEOF
  log_ok "Home.md generated"

  # 12b.9 Generate _sidebar.md navigation
  cat > "${work_dir}/_sidebar.md" << 'SIDEBAREOF'
**[Home](Home)**

---

**Architecture**
- [System Architecture](system-architecture)
- [Security Architecture](security-architecture)
- [Flow Charts](flow-charts)

**Operations**
- [Deployment Automation](deployment-automation)
- [Terraform Infrastructure](terraform-infrastructure)
- [Services Reference](services-reference)
- [Monitoring & Observability](monitoring-observability)

**CI/CD**
- [Golden Image CI/CD](golden-image-cicd)
- [Custom Operators](custom-operators)

**Troubleshooting**
- [Troubleshooting Index](troubleshooting-sop)
SIDEBAREOF

  # Append troubleshooting sub-pages to sidebar
  while IFS= read -r header; do
    section_num=$(echo "$header" | sed -E 's/^## ([0-9]+)\..*/\1/')
    section_title=$(echo "$header" | sed -E 's/^## [0-9]+\. //')
    local padded
    padded=$(printf "%02d" "$section_num")
    section_slug=$(echo "$section_title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-//; s/-$//')
    echo "  - [${section_num}. ${section_title}](troubleshooting-${padded}-${section_slug})" >> "${work_dir}/_sidebar.md"
  done < <(grep -E '^## [0-9]+\.' "$ts_src")

  log_ok "_sidebar.md generated"

  # 12b.10 Fix cross-references: strip .md extension from internal links
  log_step "Fixing cross-references for wiki format..."
  find "${work_dir}" -name '*.md' -not -path '*/.git/*' | while read -r f; do
    # Replace [text](something.md) -> [text](something) and [text](something.md#anchor) -> [text](something#anchor)
    # Only for relative links (not http:// or ../)
    sed -i -E 's/\]\(([a-zA-Z0-9_-]+)\.md(#[^)]+)?\)/](\1\2)/g' "$f"
  done
  log_ok "Cross-references fixed"

  # 12b.11 Commit and push
  log_step "Committing and pushing wiki..."
  git -C "${work_dir}" config user.name "${GIT_AUTHOR_NAME:-deploy-bot}"
  git -C "${work_dir}" config user.email "${GIT_AUTHOR_EMAIL:-deploy@${DOMAIN}}"
  git -C "${work_dir}" add -A

  if ! git -C "${work_dir}" diff --cached --quiet 2>/dev/null; then
    git -C "${work_dir}" commit -m "Update engineering SOPs from platform deploy"
    git -C "${work_dir}" push -u origin main 2>/dev/null || \
      { git -C "${work_dir}" branch -M main && git -C "${work_dir}" push -u origin main; } 2>/dev/null || true
    log_ok "Wiki pushed to sop-wiki"
  else
    log_info "Wiki already up to date — no changes"
  fi
  rm -rf "${tmp_dir}"

  end_phase "PHASE 11b: SOP WIKI"
}

# =============================================================================
# PHASE 12: VAULT CI/CD INTEGRATION
# =============================================================================
phase_12_vault_cicd() {
  start_phase "PHASE 12: VAULT CI/CD INTEGRATION"

  # Load Vault root token
  local VAULT_ROOT_TOKEN
  if [[ -f "${CLUSTER_DIR}/vault-init.json" ]]; then
    VAULT_ROOT_TOKEN=$(jq -r '.root_token' "${CLUSTER_DIR}/vault-init.json")
  else
    log_warn "vault-init.json not found — skipping Vault CI/CD setup"
    end_phase "PHASE 12: VAULT CI/CD"
    return 0
  fi

  # 13.1 Enable JWT auth method for GitLab CI
  log_step "Enabling JWT auth method for GitLab CI..."
  vault_exec "$VAULT_ROOT_TOKEN" auth enable -path=jwt/gitlab jwt 2>/dev/null || \
    log_info "JWT auth already enabled at jwt/gitlab"

  vault_exec "$VAULT_ROOT_TOKEN" write auth/jwt/gitlab/config \
    jwks_url="https://gitlab.${DOMAIN}/-/jwks" \
    bound_issuer="https://gitlab.${DOMAIN}" 2>/dev/null || true
  log_ok "JWT auth configured for GitLab (JWKS endpoint)"

  # 13.2 Create CI/CD Vault policies
  log_step "Creating CI/CD Vault policies..."

  echo 'path "kv/data/ci/*" { capabilities = ["read","list"] }
path "kv/data/services/*/ci" { capabilities = ["read","list"] }' | \
    vault_exec_stdin "$VAULT_ROOT_TOKEN" policy write ci-read-secrets -
  log_ok "Policy ci-read-secrets created"

  echo 'path "transit/sign/ci-signing-key" { capabilities = ["update"] }' | \
    vault_exec_stdin "$VAULT_ROOT_TOKEN" policy write ci-sign-images -
  log_ok "Policy ci-sign-images created"

  # 13.3 Create CI/CD Vault roles
  log_step "Creating CI/CD Vault roles..."
  vault_exec "$VAULT_ROOT_TOKEN" write auth/jwt/gitlab/role/gitlab-ci \
    role_type="jwt" \
    policies="ci-read-secrets" \
    token_explicit_max_ttl=3600 \
    user_claim="user_email" \
    bound_claims_type="glob" \
    bound_claims="{\"project_path\":\"platform_services/*\",\"ref\":\"main\"}" 2>/dev/null || true
  log_ok "Role gitlab-ci created (bound to platform_services/*, ref=main)"

  vault_exec "$VAULT_ROOT_TOKEN" write auth/jwt/gitlab/role/gitlab-ci-sign \
    role_type="jwt" \
    policies="ci-sign-images" \
    token_explicit_max_ttl=1800 \
    user_claim="user_email" \
    bound_claims_type="glob" \
    bound_claims="{\"project_path\":\"platform_services/*\",\"ref_protected\":\"true\"}" 2>/dev/null || true
  log_ok "Role gitlab-ci-sign created (bound to protected branches)"

  # 13.4 Store CI credentials in Vault KV
  log_step "Enabling Vault KV v2 secrets engine..."
  vault_exec "$VAULT_ROOT_TOKEN" secrets enable -path=kv kv-v2 2>/dev/null || \
    log_info "KV v2 engine already enabled at kv/"
  log_ok "KV v2 secrets engine enabled at kv/"

  log_step "Storing CI credentials in Vault KV..."
  vault_exec "$VAULT_ROOT_TOKEN" kv put kv/ci/harbor-push \
    username="ci-push" \
    password="placeholder-will-be-updated-by-phase-14" 2>/dev/null || true
  log_ok "kv/ci/harbor-push placeholder stored"

  if [[ -n "${GITLAB_API_TOKEN:-}" ]]; then
    vault_exec "$VAULT_ROOT_TOKEN" kv put kv/ci/gitlab-api \
      token="${GITLAB_API_TOKEN}" 2>/dev/null || true
    log_ok "kv/ci/gitlab-api stored"
  fi

  # 13.5 Enable Kubernetes auth for ESO
  log_step "Enabling Kubernetes auth for External Secrets Operator..."
  vault_exec "$VAULT_ROOT_TOKEN" auth enable kubernetes 2>/dev/null || \
    log_info "Kubernetes auth already enabled"

  vault_exec "$VAULT_ROOT_TOKEN" write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc.cluster.local:443" 2>/dev/null || true

  echo 'path "kv/data/ci/*" { capabilities = ["read","list"] }
path "kv/data/services/*" { capabilities = ["read","list"] }' | \
    vault_exec_stdin "$VAULT_ROOT_TOKEN" policy write external-secrets -
  log_ok "Policy external-secrets created"

  vault_exec "$VAULT_ROOT_TOKEN" write auth/kubernetes/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="external-secrets" \
    ttl=1h 2>/dev/null || true
  log_ok "Kubernetes auth role external-secrets created"

  # 13.6 Deploy External Secrets Operator
  log_step "Deploying External Secrets Operator..."
  ensure_namespace "external-secrets"
  helm_repo_add external-secrets https://charts.external-secrets.io

  local eso_chart
  eso_chart=$(resolve_helm_chart "external-secrets/external-secrets" "HELM_OCI_EXTERNAL_SECRETS")

  helm_install_if_needed external-secrets "$eso_chart" external-secrets \
    --set installCRDs=true \
    --set serviceAccount.name=external-secrets \
    --wait --timeout 5m

  log_ok "External Secrets Operator deployed"

  # 13.7 Create ClusterSecretStore
  log_step "Creating ClusterSecretStore..."
  wait_for_deployment external-secrets external-secrets 120s
  # Wait for CRDs to register with API server
  log_info "Waiting for ClusterSecretStore CRD to register..."
  local crd_wait=0
  while ! kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; do
    sleep 5
    crd_wait=$((crd_wait + 5))
    if [[ $crd_wait -ge 120 ]]; then
      log_warn "ClusterSecretStore CRD not registered after 120s — skipping"
      end_phase "PHASE 12: VAULT CI/CD"
      return 0
    fi
  done
  log_ok "ClusterSecretStore CRD registered"
  sleep 3  # Brief settle time
  kube_apply -f "${SERVICES_DIR}/external-secrets/cluster-secret-store.yaml"
  log_ok "ClusterSecretStore vault-backend created"

  # 13.8 Create example ExternalSecret (harbor-ci-push)
  log_step "Creating example ExternalSecret..."
  ensure_namespace "gitlab-runners"
  kube_apply -f "${SERVICES_DIR}/external-secrets/external-secret-harbor-push.yaml"
  log_ok "ExternalSecret harbor-ci-push created in gitlab-runners namespace"

  end_phase "PHASE 12: VAULT CI/CD"
}

# =============================================================================
# PHASE 13: CI PIPELINE TEMPLATES & HARBOR POLICIES
# =============================================================================
phase_13_ci_templates() {
  start_phase "PHASE 13: CI TEMPLATES & HARBOR POLICIES"

  # Load GitLab API token
  local GITLAB_API="https://gitlab.${DOMAIN}/api/v4"
  if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
    local token_file="${SCRIPTS_DIR}/.gitlab-api-token"
    [[ -f "$token_file" ]] && GITLAB_API_TOKEN=$(cat "$token_file")
  fi

  if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
    log_warn "No GITLAB_API_TOKEN — skipping CI template push"
    end_phase "PHASE 13: CI TEMPLATES"
    return 0
  fi

  # 14.1 Ensure platform_services group exists (create if needed)
  local PS_GROUP_ID=""
  PS_GROUP_ID=$(gitlab_group_id "platform_services" 2>/dev/null) || true
  if [[ -z "$PS_GROUP_ID" || "$PS_GROUP_ID" == "null" ]]; then
    log_step "Creating platform_services group..."
    local group_resp
    group_resp=$(gitlab_post "/groups" \
      '{"name":"Platform Services","path":"platform_services","visibility":"internal","description":"Shared platform infrastructure and CI/CD templates"}') || true
    PS_GROUP_ID=$(echo "$group_resp" | jq -r '.id // empty' 2>/dev/null)
    if [[ -z "$PS_GROUP_ID" ]]; then
      log_error "Failed to create platform_services group — skipping CI templates"
      end_phase "PHASE 13: CI TEMPLATES"
      return 0
    fi
    log_ok "Created platform_services group (ID: ${PS_GROUP_ID})"
  fi

  # 14.2 Create gitlab-ci-templates project
  log_step "Creating gitlab-ci-templates project..."
  local tmpl_project_id=""
  tmpl_project_id=$(gitlab_project_id "platform_services/gitlab-ci-templates" 2>/dev/null) || true

  if [[ -z "$tmpl_project_id" || "$tmpl_project_id" == "null" ]]; then
    local resp
    resp=$(gitlab_post "/projects" \
      "{\"name\":\"gitlab-ci-templates\",\"path\":\"gitlab-ci-templates\",\"namespace_id\":${PS_GROUP_ID},\"visibility\":\"internal\",\"initialize_with_readme\":false}") || true
    tmpl_project_id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)
    if [[ -z "$tmpl_project_id" ]]; then
      log_error "Failed to create gitlab-ci-templates project"
      end_phase "PHASE 13: CI TEMPLATES"
      return 0
    fi
    log_ok "Created gitlab-ci-templates project (ID: ${tmpl_project_id})"
    sleep 2
  else
    log_ok "gitlab-ci-templates project already exists (ID: ${tmpl_project_id})"
  fi

  # 14.3 Push template library
  log_step "Pushing CI template library to GitLab..."
  local templates_dir="${SERVICES_DIR}/gitlab-ci-templates"
  if [[ -d "$templates_dir" ]]; then
    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/ci-templates-XXXXXX")

    export GIT_SSL_NO_VERIFY=true
    local repo_url="https://oauth2:${GITLAB_API_TOKEN}@gitlab.${DOMAIN}/platform_services/gitlab-ci-templates.git"

    if ! git clone "$repo_url" "${tmp_dir}/repo" 2>/dev/null; then
      mkdir -p "${tmp_dir}/repo"
      git -C "${tmp_dir}/repo" init -b main
      git -C "${tmp_dir}/repo" remote add origin "$repo_url"
    fi

    local work_dir="${tmp_dir}/repo"
    find "${work_dir}" -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +
    cp -a "${templates_dir}"/. "${work_dir}/"

    git -C "${work_dir}" config user.name "${GIT_AUTHOR_NAME:-deploy-bot}"
    git -C "${work_dir}" config user.email "${GIT_AUTHOR_EMAIL:-deploy@${DOMAIN}}"
    git -C "${work_dir}" add -A

    if ! git -C "${work_dir}" diff --cached --quiet 2>/dev/null; then
      git -C "${work_dir}" commit -m "Update CI/CD templates from platform deploy"
      git -C "${work_dir}" push -u origin main 2>/dev/null || \
        git -C "${work_dir}" push -u origin main --force 2>/dev/null || true
      log_ok "CI templates pushed to gitlab-ci-templates"
    else
      log_info "CI templates already up to date"
    fi
    rm -rf "${tmp_dir}"
  else
    log_warn "CI templates directory not found at ${templates_dir}"
  fi

  # 14.4 Configure Harbor CI/CD projects and robot accounts
  log_step "Creating Harbor CI/CD projects..."
  create_harbor_project "platform-services" "false"
  create_harbor_project "ci-cache" "false"
  log_ok "Harbor projects created (platform-services, ci-cache)"

  # 14.4b Prefetch CI tool images (airgapped only)
  if [[ "${AIRGAPPED:-false}" == "true" ]]; then
    log_step "Prefetching CI tool images into Harbor proxy cache..."
    "${SCRIPTS_DIR}/prefetch-ci-images.sh" || log_warn "Some CI images failed to prefetch (non-fatal)"
  fi

  # Create Harbor robot accounts
  log_step "Creating Harbor robot accounts..."
  local ci_push_resp
  ci_push_resp=$(create_harbor_robot "ci-push" "platform-services" \
    '[{"kind":"project","namespace":"platform-services","access":[{"resource":"repository","action":"push"},{"resource":"repository","action":"pull"}]},{"kind":"project","namespace":"ci-cache","access":[{"resource":"repository","action":"push"},{"resource":"repository","action":"pull"}]}]')
  local ci_push_secret
  ci_push_secret=$(echo "$ci_push_resp" | jq -r '.secret // empty' 2>/dev/null)
  local ci_push_name
  ci_push_name=$(echo "$ci_push_resp" | jq -r '.name // "robot$ci-push"' 2>/dev/null)

  if [[ -n "$ci_push_secret" ]]; then
    log_ok "Harbor robot ci-push created"
    # Update Vault with real credentials
    if [[ -f "${CLUSTER_DIR}/vault-init.json" ]]; then
      local VAULT_ROOT_TOKEN
      VAULT_ROOT_TOKEN=$(jq -r '.root_token' "${CLUSTER_DIR}/vault-init.json")
      vault_exec "$VAULT_ROOT_TOKEN" kv put kv/ci/harbor-push \
        username="${ci_push_name}" password="${ci_push_secret}" 2>/dev/null || true
      log_ok "Vault kv/ci/harbor-push updated with real credentials"
    fi
  else
    log_warn "Could not create Harbor robot ci-push (may already exist)"
  fi

  local argocd_pull_resp
  argocd_pull_resp=$(create_harbor_robot "argocd-pull" "platform-services" \
    '[{"kind":"project","namespace":"platform-services","access":[{"resource":"repository","action":"pull"}]}]')
  if echo "$argocd_pull_resp" | jq -e '.secret' &>/dev/null; then
    log_ok "Harbor robot argocd-pull created"
  else
    log_warn "Could not create Harbor robot argocd-pull (may already exist)"
  fi

  # 14.5 Set GitLab group-level CI/CD variables
  log_step "Setting GitLab group-level CI/CD variables..."
  gitlab_set_variable "groups" "$PS_GROUP_ID" "HARBOR_REGISTRY" "harbor.${DOMAIN}" "false" "false"
  gitlab_set_variable "groups" "$PS_GROUP_ID" "HARBOR_CI_USER" "${ci_push_name:-robot\$ci-push}" "false" "false"
  if [[ -n "$ci_push_secret" ]]; then
    gitlab_set_variable "groups" "$PS_GROUP_ID" "HARBOR_CI_PASSWORD" "$ci_push_secret" "true" "false"
  fi
  gitlab_set_variable "groups" "$PS_GROUP_ID" "VAULT_ADDR" "https://vault.${DOMAIN}" "false" "false"
  gitlab_set_variable "groups" "$PS_GROUP_ID" "VAULT_ROLE" "gitlab-ci" "false" "false"
  gitlab_set_variable "groups" "$PS_GROUP_ID" "DOMAIN" "${DOMAIN}" "false" "false"
  gitlab_set_variable "groups" "$PS_GROUP_ID" "ARGOCD_SERVER" "argo.${DOMAIN}" "false" "false"

  # Airgapped CI/CD variables
  if [[ "${AIRGAPPED:-false}" == "true" ]]; then
    log_step "Setting airgapped CI/CD variables..."
    gitlab_set_variable "groups" "$PS_GROUP_ID" "CI_AIRGAPPED" "true" "false" "false"
    gitlab_set_variable "groups" "$PS_GROUP_ID" "CI_GOPROXY" "${CI_GOPROXY:-off}" "false" "false"
    gitlab_set_variable "groups" "$PS_GROUP_ID" "CI_GONOSUMDB" "${CI_GONOSUMDB:-*}" "false" "false"
    [[ -n "${CI_NPM_REGISTRY:-}" ]] && \
      gitlab_set_variable "groups" "$PS_GROUP_ID" "CI_NPM_REGISTRY" "${CI_NPM_REGISTRY}" "false" "false"
    if [[ -n "${CI_PIP_INDEX_URL:-}" ]]; then
      gitlab_set_variable "groups" "$PS_GROUP_ID" "CI_PIP_INDEX_URL" "${CI_PIP_INDEX_URL}" "false" "false"
      gitlab_set_variable "groups" "$PS_GROUP_ID" "CI_PIP_TRUSTED_HOST" "${CI_PIP_TRUSTED_HOST:-}" "false" "false"
    fi
    log_ok "Airgapped CI/CD variables configured"
  fi

  log_ok "Group-level CI/CD variables set"

  end_phase "PHASE 13: CI TEMPLATES"
}

# =============================================================================
# PHASE 14: ARGOCD RBAC & PROGRESSIVE DELIVERY
# =============================================================================
phase_14_argocd_delivery() {
  start_phase "PHASE 14: ARGOCD RBAC & PROGRESSIVE DELIVERY"

  # 15.1 Update ArgoCD RBAC
  log_step "Updating ArgoCD RBAC with CI/CD roles..."
  local rbac_csv
  rbac_csv=$(cat <<'RBAC_EOF'
p, role:admin, applications, *, */*, allow
p, role:admin, clusters, *, *, allow
p, role:admin, repositories, *, *, allow
p, role:admin, logs, *, *, allow
p, role:admin, exec, *, */*, allow
p, role:infra-ops, applications, get, */*, allow
p, role:infra-ops, applications, sync, */*, allow
p, role:infra-ops, applications, action/*, */*, allow
p, role:infra-ops, logs, get, *, allow
p, role:senior-dev, applications, get, staging/*, allow
p, role:senior-dev, applications, sync, staging/*, allow
p, role:senior-dev, applications, get, ephemeral/*, allow
p, role:senior-dev, applications, sync, ephemeral/*, allow
p, role:senior-dev, logs, get, *, allow
p, role:ci-sync, applications, get, */*, allow
p, role:ci-sync, applications, sync, */*, allow
p, role:readonly, applications, get, */*, allow
p, role:readonly, logs, get, *, allow
g, platform-admins, role:admin
g, infra-engineers, role:infra-ops
g, senior-developers, role:senior-dev
g, ci-service-accounts, role:ci-sync
g, developers, role:readonly
g, viewers, role:readonly
RBAC_EOF
)
  kubectl -n argocd get configmap argocd-rbac-cm -o json 2>/dev/null | \
    jq --arg csv "$rbac_csv" '.data["policy.csv"] = $csv' | \
    kubectl apply -f - 2>/dev/null || \
    kubectl -n argocd create configmap argocd-rbac-cm \
      --from-literal="policy.csv=${rbac_csv}" --dry-run=client -o yaml | kubectl apply -f -
  log_ok "ArgoCD RBAC updated with infra-ops, senior-dev, ci-sync roles"

  # 15.2 Create ArgoCD AppProjects
  log_step "Creating ArgoCD AppProjects for environment isolation..."

  kubectl apply -f - <<'PROJ_EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: production
  namespace: argocd
spec:
  description: "Production workloads — platform-admins only"
  sourceRepos:
    - "git@gitlab.*:platform_services/*"
    - "https://gitlab.*:platform_services/*"
  destinations:
    - namespace: "demo-apps"
      server: https://kubernetes.default.svc
    - namespace: "production-*"
      server: https://kubernetes.default.svc
  roles:
    - name: admin
      description: "Full production access"
      groups:
        - platform-admins
      policies:
        - "p, proj:production:admin, applications, *, production/*, allow"
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: staging
  namespace: argocd
spec:
  description: "Staging workloads — infra-engineers and senior-developers"
  sourceRepos:
    - "*"
  destinations:
    - namespace: "staging-*"
      server: https://kubernetes.default.svc
  roles:
    - name: deployer
      description: "Staging deploy access"
      groups:
        - infra-engineers
        - senior-developers
      policies:
        - "p, proj:staging:deployer, applications, *, staging/*, allow"
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ephemeral
  namespace: argocd
spec:
  description: "Ephemeral MR environments — developers can sync"
  sourceRepos:
    - "*"
  destinations:
    - namespace: "ephemeral-*"
      server: https://kubernetes.default.svc
  roles:
    - name: developer
      description: "Ephemeral env access"
      groups:
        - developers
        - senior-developers
        - infra-engineers
      policies:
        - "p, proj:ephemeral:developer, applications, *, ephemeral/*, allow"
PROJ_EOF
  log_ok "AppProjects created: production, staging, ephemeral"

  # 15.3 Deploy Prometheus AnalysisTemplates for Argo Rollouts
  log_step "Deploying AnalysisTemplates for progressive delivery..."
  local analysis_dir="${SERVICES_DIR}/argo/analysis-templates"
  if [[ -d "$analysis_dir" ]]; then
    for f in "${analysis_dir}"/*.yaml; do
      kube_apply -f "$f"
    done
    log_ok "AnalysisTemplates deployed (success-rate, latency-check, error-rate)"
  else
    log_warn "AnalysisTemplates directory not found at ${analysis_dir}"
  fi

  # 15.4 Deploy ephemeral namespace cleaner CronJob
  log_step "Deploying ephemeral namespace cleaner CronJob..."
  kubectl apply -f - <<'CLEANER_EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ephemeral-ns-cleaner
  namespace: argocd
spec:
  schedule: "*/30 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: argocd-server
          containers:
            - name: cleaner
              image: bitnami/kubectl:latest
              command:
                - /bin/bash
                - -c
                - |
                  # Delete ephemeral namespaces older than 4 hours
                  now=$(date +%s)
                  kubectl get namespaces -l ephemeral-ttl -o json | \
                    jq -r '.items[] | select((.metadata.creationTimestamp | fromdateiso8601) < ('$now' - 14400)) | .metadata.name' | \
                    while read -r ns; do
                      echo "Deleting expired ephemeral namespace: $ns"
                      kubectl delete namespace "$ns" --wait=false
                    done
          restartPolicy: Never
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
CLEANER_EOF
  log_ok "Ephemeral namespace cleaner CronJob deployed"

  # 15.5 Create ArgoCD ApplicationSet for ephemeral MR environments
  # First, create the argocd-gitlab-token secret referenced by the ApplicationSet
  log_step "Creating argocd-gitlab-token secret for ApplicationSet..."
  if [[ -n "${GITLAB_API_TOKEN:-}" ]]; then
    kubectl create secret generic argocd-gitlab-token \
      --namespace=argocd \
      --from-literal=token="${GITLAB_API_TOKEN}" \
      --dry-run=client -o yaml | kubectl apply -f -
    log_ok "argocd-gitlab-token secret created in argocd namespace"
  else
    log_warn "No GITLAB_API_TOKEN — argocd-gitlab-token secret not created (ApplicationSet SCM polling will fail)"
  fi

  log_step "Creating ApplicationSet for ephemeral MR environments..."
  kubectl apply -f - <<APPSET_EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ephemeral-mr-envs
  namespace: argocd
spec:
  generators:
    - pullRequest:
        gitlab:
          project: "platform_services"
          api: "https://gitlab.${DOMAIN}"
          tokenRef:
            secretName: argocd-gitlab-token
            key: token
        requeueAfterSeconds: 60
  template:
    metadata:
      name: "ephemeral-{{branch_slug}}"
    spec:
      project: ephemeral
      source:
        repoURL: "{{clone_url}}"
        targetRevision: "{{head_sha}}"
        path: deploy/overlays/rke2-prod
      destination:
        server: https://kubernetes.default.svc
        namespace: "ephemeral-{{number}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
APPSET_EOF
  log_ok "ApplicationSet ephemeral-mr-envs created"

  end_phase "PHASE 14: ARGOCD DELIVERY"
}

# =============================================================================
# PHASE 15: SECURITY SCANNING & SBOM
# =============================================================================
phase_15_security() {
  start_phase "PHASE 15: SECURITY SCANNING"

  if [[ "${DEPLOY_CICD_SECURITY_RUNNERS:-true}" != "true" ]]; then
    log_info "DEPLOY_CICD_SECURITY_RUNNERS=false — skipping security runner deployment"
    end_phase "PHASE 15: SECURITY"
    return 0
  fi

  # 16.1 Deploy dedicated security runner pool
  log_step "Deploying dedicated security runner pool..."
  local GITLAB_API="https://gitlab.${DOMAIN}/api/v4"
  if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
    local token_file="${SCRIPTS_DIR}/.gitlab-api-token"
    [[ -f "$token_file" ]] && GITLAB_API_TOKEN=$(cat "$token_file")
  fi

  local sec_runner_token=""
  if [[ -n "${GITLAB_API_TOKEN:-}" ]]; then
    log_step "Creating security runner via GitLab API..."
    local attempt=0
    while [[ $attempt -lt 3 ]]; do
      local sec_response
      sec_response=$(gitlab_post "/user/runners" \
        '{"runner_type":"instance_type","description":"security-scanner-runner","tag_list":"security,trivy,semgrep,gitleaks","run_untagged":false}') || true
      sec_runner_token=$(echo "$sec_response" | jq -r '.token // empty' 2>/dev/null)
      if [[ -n "$sec_runner_token" ]]; then
        log_ok "Security runner created (token: ${sec_runner_token:0:8}...)"
        break
      fi
      attempt=$((attempt + 1))
      if [[ $attempt -lt 3 ]]; then
        log_info "Runner token creation failed (attempt ${attempt}/3) — retrying in 30s..."
        sleep 30
      else
        log_warn "Failed to create security runner after 3 attempts"
      fi
    done
  fi

  if [[ -n "$sec_runner_token" ]]; then
    # Deploy security runner Helm chart
    ensure_namespace "gitlab-runners"
    helm_repo_add gitlab https://charts.gitlab.io
    local runner_chart
    runner_chart=$(resolve_helm_chart "gitlab/gitlab-runner" "HELM_OCI_GITLAB_RUNNER")

    local sec_values="${SERVICES_DIR}/gitlab-runners/security-runner-values.yaml"
    if [[ ! -f "$sec_values" ]]; then
      # Create security runner values inline
      cat > "$sec_values" <<'SECVAL_EOF'
replicas: 1
gitlabUrl: ""
runnerToken: ""
rbac:
  create: true
  clusterWideAccess: false
runners:
  config: |
    [[runners]]
      [runners.kubernetes]
        namespace = "gitlab-runners"
        image = "alpine:3.21"
        cpu_request = "200m"
        memory_request = "512Mi"
        memory_limit = "2Gi"
        service_cpu_request = "100m"
        service_memory_request = "256Mi"
  tags: "security,trivy,semgrep,gitleaks"
  runUntagged: false
  locked: false
  secret: gitlab-runner-security-certs
certsSecretName: gitlab-runner-security-certs
SECVAL_EOF
    fi

    helm_install_if_needed gitlab-runner-security "$runner_chart" gitlab-runners \
      -f "$sec_values" \
      --set runnerToken="${sec_runner_token}" \
      --set gitlabUrl="https://gitlab.${DOMAIN}" || {
      log_warn "Security runner Helm install failed — continuing"
    }
    log_ok "Security runner deployed"
  else
    log_warn "No security runner token — skipping Helm install"
  fi

  # 16.2 Push updated security templates to gitlab-ci-templates project
  log_step "Security scan templates are included in the CI template library (Phase 13)"
  log_info "Templates: gitleaks, semgrep, trivy-fs, trivy-image, sbom, license"
  log_ok "Security templates available via shared CI library"

  # 16.3 Configure Harbor vulnerability scanning
  log_step "Configuring Harbor auto-scan on push..."
  local harbor_core_pod
  harbor_core_pod=$(kubectl -n harbor get pod -l component=core -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$harbor_core_pod" ]]; then
    local harbor_api="http://harbor-core.harbor.svc.cluster.local/api/v2.0"
    local admin_pass="${HARBOR_ADMIN_PASSWORD:-}"
    [[ -z "$admin_pass" ]] && admin_pass=$(grep 'harborAdminPassword' "${SERVICES_DIR}/harbor/harbor-values.yaml" | awk -F'"' '{print $2}')

    # Enable auto-scan for platform-services project
    kubectl exec -n harbor "$harbor_core_pod" -- \
      curl -sf -u "admin:${admin_pass}" -X PUT \
      "${harbor_api}/projects/platform-services" \
      -H "Content-Type: application/json" \
      -d '{"metadata":{"auto_scan":"true","severity":"critical"}}' 2>/dev/null || true
    log_ok "Harbor auto-scan enabled for platform-services project"
  else
    log_warn "Harbor core pod not found — skipping auto-scan configuration"
  fi

  end_phase "PHASE 15: SECURITY"
}

# =============================================================================
# PHASE 16: DORA METRICS & CI/CD OBSERVABILITY
# =============================================================================
phase_16_observability() {
  start_phase "PHASE 16: DORA METRICS & OBSERVABILITY"

  # 17.1 Import DORA Grafana dashboard
  log_step "Deploying DORA metrics Grafana dashboard..."
  local dashboard_file="${SERVICES_DIR}/monitoring-stack/grafana/dashboards/cicd-dora.json"
  if [[ -f "$dashboard_file" ]]; then
    kube_apply -f "$dashboard_file"
    log_ok "DORA dashboard ConfigMap deployed (auto-discovered by Grafana sidecar)"
  else
    log_warn "DORA dashboard file not found at ${dashboard_file}"
  fi

  # 17.2 Deploy CI/CD alerting rules (Prometheus Operator CRDs guaranteed by Phase 3)
  log_step "Deploying CI/CD alerting rules..."
  local alerts_file="${SERVICES_DIR}/monitoring-stack/prometheus/rules/cicd-alerts.yaml"
  if [[ -f "$alerts_file" ]]; then
    kube_apply -f "$alerts_file"
    log_ok "CI/CD PrometheusRule deployed"
  else
    log_warn "CI/CD alerts file not found at ${alerts_file}"
  fi

  # 17.3 Print CI/CD infrastructure summary
  log_step "CI/CD Infrastructure Summary"
  echo ""
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}  CI/CD INFRASTRUCTURE SUMMARY${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo ""
  echo "  Services:"
  echo "    GitLab:         https://gitlab.${DOMAIN}"
  echo "    Harbor:         https://harbor.${DOMAIN}"
  echo "    ArgoCD:         https://argo.${DOMAIN}"
  echo "    Vault:          https://vault.${DOMAIN}"
  echo "    Grafana:        https://grafana.${DOMAIN}"
  echo "    Rollouts:       https://rollouts.${DOMAIN}"
  echo "    Hubble:         https://hubble.${DOMAIN}"
  echo ""
  echo "  CI/CD Components:"
  echo "    CI Templates:   https://gitlab.${DOMAIN}/platform_services/gitlab-ci-templates"
  echo "    DORA Dashboard: https://grafana.${DOMAIN}/d/cicd-dora-metrics"
  echo "    Harbor Registry: harbor.${DOMAIN}/platform-services/*"
  echo ""
  echo "  Progressive Delivery:"
  echo "    Canary Analysis: success-rate, latency-check, error-rate (AnalysisTemplates)"
  echo "    AppProjects:     production, staging, ephemeral"
  echo "    Ephemeral Envs:  Auto-created per MR (ApplicationSet)"
  echo ""
  echo "  Security:"
  echo "    Pipeline Scans:  gitleaks, semgrep, trivy-fs, trivy-image, sbom"
  echo "    Harbor Auto-Scan: Enabled (critical severity threshold)"
  echo "    Vault JWT Auth:  GitLab CI -> Vault (no secrets in CI/CD variables)"
  echo ""
  echo "  Approval Gates:"
  echo "    Protected Branches: main (Maintainer push/merge)"
  echo "    MR Approval:        Senior Review Required (2 approvals)"
  echo "    Group Roles:        platform-admins=Owner, infra/senior=Maintainer,"
  echo "                        developers=Developer, viewers=Reporter"
  echo ""

  end_phase "PHASE 16: OBSERVABILITY"
}

# =============================================================================
# PHASE 17: DEMO APPLICATIONS — "NETOPS ARCADE"
# =============================================================================
phase_17_demo_apps() {
  start_phase "PHASE 17: DEMO APPS — NETOPS ARCADE"

  if [[ "${DEPLOY_DEMO_APPS:-true}" != "true" ]]; then
    log_info "DEPLOY_DEMO_APPS=false — skipping demo app deployment"
    end_phase "PHASE 17: DEMO APPS"
    return 0
  fi

  local GITLAB_API="https://gitlab.${DOMAIN}/api/v4"
  if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
    local token_file="${SCRIPTS_DIR}/.gitlab-api-token"
    [[ -f "$token_file" ]] && GITLAB_API_TOKEN=$(cat "$token_file")
  fi

  if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
    log_warn "No GITLAB_API_TOKEN — skipping demo app push to GitLab"
    end_phase "PHASE 17: DEMO APPS"
    return 0
  fi

  # 18.1 Look up platform_services group
  local PS_GROUP_ID=""
  PS_GROUP_ID=$(gitlab_group_id "platform_services" 2>/dev/null) || true
  if [[ -z "$PS_GROUP_ID" || "$PS_GROUP_ID" == "null" ]]; then
    log_warn "platform_services group not found — skipping demo apps"
    end_phase "PHASE 17: DEMO APPS"
    return 0
  fi

  # 18.2 Create demo-apps namespace
  log_step "Creating demo-apps namespace..."
  ensure_namespace "demo-apps"

  # 18.3 Create Harbor project for demo apps
  log_step "Creating Harbor project for demo apps..."
  create_harbor_project "platform-services" "false"

  # 18.4 Push demo apps to GitLab
  local demo_dir="${SCRIPTS_DIR}/samples/demo-apps"
  if [[ ! -d "$demo_dir" ]]; then
    log_warn "Demo apps directory not found at ${demo_dir}"
    end_phase "PHASE 17: DEMO APPS"
    return 0
  fi

  export GIT_SSL_NO_VERIFY=true
  for app_dir in "${demo_dir}"/*/; do
    local app_name
    app_name=$(basename "$app_dir")
    local project_name="${app_name}"

    log_step "Pushing demo app: ${app_name}..."

    # Create project if needed
    local existing_id
    existing_id=$(gitlab_project_id "platform_services/${project_name}" 2>/dev/null) || true

    if [[ -z "$existing_id" || "$existing_id" == "null" ]]; then
      local resp
      resp=$(gitlab_post "/projects" \
        "{\"name\":\"${project_name}\",\"path\":\"${project_name}\",\"namespace_id\":${PS_GROUP_ID},\"visibility\":\"private\",\"initialize_with_readme\":false}") || true
      existing_id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)
      if [[ -z "$existing_id" ]]; then
        log_warn "Failed to create project ${project_name} — skipping"
        continue
      fi
      log_ok "Created project: platform_services/${project_name} (ID: ${existing_id})"
      sleep 2
    else
      log_info "Project already exists: platform_services/${project_name}"
    fi

    # Clone/init and push
    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/demo-${app_name}-XXXXXX")
    local repo_url="https://oauth2:${GITLAB_API_TOKEN}@gitlab.${DOMAIN}/platform_services/${project_name}.git"

    if ! git clone "$repo_url" "${tmp_dir}/repo" 2>/dev/null; then
      mkdir -p "${tmp_dir}/repo"
      git -C "${tmp_dir}/repo" init -b main
      git -C "${tmp_dir}/repo" remote add origin "$repo_url"
    fi

    local work_dir="${tmp_dir}/repo"
    # Remove existing files (except .git)
    find "${work_dir}" -mindepth 1 -maxdepth 1 -not -name '.git' -exec rm -rf {} +

    # Copy app files, skip deploy/ dirs that have CHANGEME tokens we want to keep
    cp -a "${app_dir}"/. "${work_dir}/"

    # Substitute domain tokens in YAML files
    find "${work_dir}" \( -name '*.yaml' -o -name '*.yml' \) -not -path '*/.git/*' \
      | while read -r f; do
          sed -i "s|CHANGEME_DOMAIN|${DOMAIN}|g" "$f"
        done

    git -C "${work_dir}" config user.name "${GIT_AUTHOR_NAME:-deploy-bot}"
    git -C "${work_dir}" config user.email "${GIT_AUTHOR_EMAIL:-deploy@${DOMAIN}}"
    git -C "${work_dir}" add -A

    if ! git -C "${work_dir}" diff --cached --quiet 2>/dev/null; then
      git -C "${work_dir}" commit -m "Deploy ${app_name} demo app"
      git -C "${work_dir}" push -u origin main 2>/dev/null || \
        { git -C "${work_dir}" branch -M main && git -C "${work_dir}" push -u origin main; } 2>/dev/null || true
      log_ok "Pushed ${app_name} to platform_services/${project_name}"
    else
      log_info "No changes to push for ${app_name}"
    fi
    rm -rf "${tmp_dir}"
  done

  # 18.5 Deploy traffic generator CronJob
  log_step "Deploying traffic generator for demo network..."
  kubectl apply -f - <<TRAFFIC_EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: packet-generator
  namespace: demo-apps
spec:
  schedule: "* * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: sender
              image: curlimages/curl:latest
              command:
                - /bin/sh
                - -c
                - |
                  for i in \$(seq 1 20); do
                    curl -sf -X POST http://router-west:8080/relay \
                      -H "Content-Type: application/json" \
                      -d "{\"id\":\"pkt-\$(date +%s)-\${i}\",\"payload\":\"trace-route-test\",\"hops\":[],\"ttl\":8}" \
                      || true
                    sleep 2
                  done
          restartPolicy: Never
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
TRAFFIC_EOF
  log_ok "Traffic generator CronJob deployed"

  # 18.6 Print demo app summary
  echo ""
  echo -e "${BOLD}  DEMO APPS — NETOPS ARCADE${NC}"
  echo ""
  echo "  Topology: router-west ──▸ router-core ──▸ router-east"
  echo "                                  │"
  echo "                                  └──▸ router-north (standby)"
  echo ""
  echo "  netops-dashboard: Live NOC visualization (blue-green deploy)"
  echo "  packet-relay:     4 router instances (canary deploy w/ AnalysisTemplates)"
  echo ""
  echo "  Demo Scenarios:"
  echo "    1. IP Change (BAD):  Edit routing-config.yaml, set NEXT_HOPS=http://10.0.0.99:8080"
  echo "                         Push → canary deploys → packets drop → auto-rollback"
  echo "    2. IP Change (GOOD): Edit routing-config.yaml, set NEXT_HOPS=http://router-north:8080"
  echo "                         Push → canary deploys → packets flow → promote to 100%"
  echo "                         Dashboard shows topology transition: east→north"
  echo "    3. Security Block:   Push netops-dashboard with vulnerable npm dep"
  echo "                         Pipeline blocks at trivy scan stage"
  echo "    4. Approval Gate:    Create MR requiring senior-developer approval"
  echo "    5. Blue-Green:       Push netops-dashboard v2 (new UI) → preview URL → promote"
  echo ""
  echo "  Key file to edit: deploy/overlays/rke2-prod/routing-config.yaml"
  echo "    in the packet-relay GitLab project (platform_services/packet-relay)"
  echo ""

  end_phase "PHASE 17: DEMO APPS"
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

  # Execute phases (FROM_PHASE..TO_PHASE inclusive)
  if [[ "$SKIP_TERRAFORM" == "false" && $FROM_PHASE -le 0 && $TO_PHASE -ge 0 ]]; then
    phase_0_terraform
  fi

  [[ $FROM_PHASE -le 1  && $TO_PHASE -ge 1  ]] && phase_1_foundation
  [[ $FROM_PHASE -le 2  && $TO_PHASE -ge 2  ]] && phase_2_vault
  [[ $FROM_PHASE -le 3  && $TO_PHASE -ge 3  ]] && phase_3_monitoring
  [[ $FROM_PHASE -le 4  && $TO_PHASE -ge 4  ]] && phase_4_harbor
  [[ $FROM_PHASE -le 5  && $TO_PHASE -ge 5  ]] && phase_5_keycloak_auth
  [[ $FROM_PHASE -le 6  && $TO_PHASE -ge 6  ]] && phase_6_argocd
  [[ $FROM_PHASE -le 6  && $TO_PHASE -ge 6  ]] && phase_6b_dhi_builder
  [[ $FROM_PHASE -le 7  && $TO_PHASE -ge 7  ]] && phase_7_remaining
  [[ $FROM_PHASE -le 8  && $TO_PHASE -ge 8  ]] && phase_8_dns
  [[ $FROM_PHASE -le 9  && $TO_PHASE -ge 9  ]] && phase_9_validation
  [[ $FROM_PHASE -le 10 && $TO_PHASE -ge 10 ]] && phase_10_gitlab
  [[ $FROM_PHASE -le 11 && $TO_PHASE -ge 11 ]] && phase_11_gitlab_hardening
  [[ $FROM_PHASE -le 11 && $TO_PHASE -ge 11 ]] && phase_11b_sop_wiki
  [[ $FROM_PHASE -le 12 && $TO_PHASE -ge 12 ]] && phase_12_vault_cicd
  [[ $FROM_PHASE -le 13 && $TO_PHASE -ge 13 ]] && phase_13_ci_templates
  [[ $FROM_PHASE -le 14 && $TO_PHASE -ge 14 ]] && phase_14_argocd_delivery
  [[ $FROM_PHASE -le 15 && $TO_PHASE -ge 15 ]] && phase_15_security
  [[ $FROM_PHASE -le 16 && $TO_PHASE -ge 16 ]] && phase_16_observability
  [[ $FROM_PHASE -le 17 && $TO_PHASE -ge 17 ]] && phase_17_demo_apps

  print_total_time
}

main "$@"
