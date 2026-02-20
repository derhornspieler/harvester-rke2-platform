#!/usr/bin/env bash
# =============================================================================
# precheck.sh — Pre-flight checks for RKE2 cluster deployment
# =============================================================================
# Validates all prerequisites before running deploy-cluster.sh.
# Default: report-only (prints pass/fail/warn for each check, summary at end)
# --fix:        interactively offer to remediate fixable issues
# --fetch-list: print all external dependencies (helm charts, images, binaries)
#
# Usage:
#   ./scripts/precheck.sh                          # Report only
#   ./scripts/precheck.sh --fix                    # Offer fixes for failures
#   ./scripts/precheck.sh --fetch-list             # Print fetch list
#   ./scripts/precheck.sh --fetch-list > list.txt  # Save to file
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source lib.sh but override set -e so we can collect all failures
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  echo "[ERROR] Failed to source lib.sh from ${SCRIPT_DIR}"
  exit 1
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------
FIX_MODE=false
FETCH_LIST=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix)        FIX_MODE=true; shift ;;
    --fetch-list) FETCH_LIST=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--fix] [--fetch-list]"
      echo "  --fix         Interactively offer to remediate fixable issues"
      echo "  --fetch-list  Print all external dependencies (helm charts, images, binaries)"
      echo "                Pipe to a file: $0 --fetch-list > fetch-list.txt"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# -----------------------------------------------------------------------------
# Counters
# -----------------------------------------------------------------------------
PASSED=0
FAILED=0
WARNINGS=0

pass()  { PASSED=$((PASSED + 1));   echo -e "${GREEN}  [PASS]${NC}  $*"; }
fail()  { FAILED=$((FAILED + 1));   echo -e "${RED}  [FAIL]${NC}  $*"; }
warn()  { WARNINGS=$((WARNINGS + 1)); echo -e "${YELLOW}  [WARN]${NC}  $*"; }

# Prompt user for a yes/no fix action. Only runs in --fix mode.
# Returns 0 if user said yes, 1 otherwise.
ask_fix() {
  if [[ "$FIX_MODE" != "true" ]]; then
    return 1
  fi
  local prompt="$1"
  echo -en "${CYAN}  [FIX?]${NC} ${prompt} [y/N] "
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

# =============================================================================
# CHECK 1: Required Tools
# =============================================================================
install_terraform() {
  # Add HashiCorp repo if not present, then install
  if ! dnf repolist 2>/dev/null | grep -q hashicorp; then
    sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
  fi
  sudo dnf install -y terraform
}

install_kubectl() {
  local ver
  ver=$(curl -sSL https://dl.k8s.io/release/stable.txt)
  curl -sSL -o /tmp/kubectl "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl" \
    && sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && rm -f /tmp/kubectl
}

install_helm() {
  curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

install_crane() {
  local tmp; tmp=$(mktemp -d)
  curl -sSL -o "${tmp}/crane.tar.gz" \
    "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_x86_64.tar.gz" \
    && tar -xzf "${tmp}/crane.tar.gz" -C "$tmp" crane \
    && sudo mv "${tmp}/crane" /usr/local/bin/crane \
    && sudo chmod +x /usr/local/bin/crane
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

check_tools() {
  echo ""
  echo -e "${BOLD}1. Required Tools${NC}"

  # tool | install_method | argument
  #   dnf = dnf package name
  #   cmd = installer function name
  local tool_defs=(
    "terraform|cmd|install_terraform"
    "kubectl|cmd|install_kubectl"
    "helm|cmd|install_helm"
    "jq|dnf|jq"
    "openssl|dnf|openssl"
    "curl|dnf|curl"
    "htpasswd|dnf|httpd-tools"
    "python3|dnf|python3"
    "crane|cmd|install_crane"
  )

  for entry in "${tool_defs[@]}"; do
    IFS='|' read -r tool method arg <<< "$entry"
    if command -v "$tool" &>/dev/null; then
      pass "$tool ($(command -v "$tool"))"
      continue
    fi

    fail "$tool not found"
    case "$method" in
      dnf)
        echo "       Install: sudo dnf install -y ${arg}"
        if ask_fix "Run: sudo dnf install -y ${arg}"; then
          if sudo dnf install -y "$arg" &>/dev/null; then
            command -v "$tool" &>/dev/null && pass "$tool installed" \
              || fail "$tool still not found after installing ${arg}"
          else
            fail "$tool installation failed (dnf returned error)"
          fi
        fi
        ;;
      cmd)
        echo "       Install: auto-install available via --fix"
        if ask_fix "Download and install ${tool}?"; then
          if $arg; then
            command -v "$tool" &>/dev/null && pass "$tool installed ($(command -v "$tool"))" \
              || fail "$tool still not found after install"
          else
            fail "$tool installation failed"
          fi
        fi
        ;;
    esac
  done
}

# =============================================================================
# CHECK 2: Harvester Kubeconfig Context
# =============================================================================
check_harvester_context() {
  echo ""
  echo -e "${BOLD}2. Harvester Kubeconfig${NC}"

  local harvester_kc="${CLUSTER_DIR}/kubeconfig-harvester.yaml"

  # First check if the local kubeconfig file exists and works
  if [[ -f "$harvester_kc" ]]; then
    if kubectl --kubeconfig="$harvester_kc" get nodes --no-headers &>/dev/null; then
      pass "Harvester kubeconfig valid: ${harvester_kc}"
      return
    else
      fail "Harvester kubeconfig exists but cannot reach cluster: ${harvester_kc}"
    fi
  fi

  # Check HARVESTER_CONTEXT in ~/.kube/config
  local ctx="${HARVESTER_CONTEXT:-harvester}"
  if kubectl config get-contexts "$ctx" &>/dev/null; then
    if kubectl --context="$ctx" get nodes --no-headers &>/dev/null; then
      pass "Harvester context '${ctx}' exists and is reachable"
    else
      fail "Harvester context '${ctx}' exists but cannot reach cluster"
    fi
  else
    fail "No Harvester kubeconfig at ${harvester_kc} and no context '${ctx}' in ~/.kube/config"
    echo "       Obtain kubeconfig from Rancher UI: Virtualization Management > Harvester > Download KubeConfig"
    echo "       Or deploy-cluster.sh will auto-generate it from Rancher API if terraform.tfvars is configured."
  fi
}

# =============================================================================
# CHECK 3: Harvester Namespace State
# =============================================================================
check_harvester_namespace() {
  echo ""
  echo -e "${BOLD}3. Harvester Namespace State${NC}"

  local harvester_kc="${CLUSTER_DIR}/kubeconfig-harvester.yaml"
  if [[ ! -f "$harvester_kc" ]]; then
    warn "Skipping — no Harvester kubeconfig available"
    return
  fi

  local hkctl="kubectl --kubeconfig=${harvester_kc}"

  # Determine target namespace from tfvars
  local vm_ns
  vm_ns=$(get_vm_namespace 2>/dev/null) || vm_ns="rke2-prod"

  local ns_json
  ns_json=$($hkctl get ns "$vm_ns" -o json 2>/dev/null) || {
    pass "Namespace '${vm_ns}' does not exist (clean slate)"
    return
  }

  local phase
  phase=$(echo "$ns_json" | jq -r '.status.phase')
  if [[ "$phase" == "Terminating" ]]; then
    fail "Namespace '${vm_ns}' is stuck in Terminating state"

    # Check for blocking resources
    local blocking_pvcs
    blocking_pvcs=$($hkctl get pvc -n "$vm_ns" --no-headers 2>/dev/null || true)
    if [[ -n "$blocking_pvcs" ]]; then
      echo "       Blocking PVCs:"
      echo "$blocking_pvcs" | sed 's/^/         /'
      if ask_fix "Delete all PVCs in ${vm_ns} and remove finalizers?"; then
        $hkctl delete pvc --all -n "$vm_ns" --wait=false 2>/dev/null || true
        # Remove finalizers on PVCs
        for pvc in $($hkctl get pvc -n "$vm_ns" --no-headers -o name 2>/dev/null); do
          $hkctl patch "$pvc" -n "$vm_ns" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
        done
        echo "       PVCs deleted. Namespace may take a minute to terminate."
      fi
    fi

    local blocking_vms
    blocking_vms=$($hkctl get virtualmachines.kubevirt.io -n "$vm_ns" --no-headers 2>/dev/null || true)
    if [[ -n "$blocking_vms" ]]; then
      echo "       Blocking VMs:"
      echo "$blocking_vms" | sed 's/^/         /'
      if ask_fix "Remove finalizers on VMs in ${vm_ns}?"; then
        for vm in $($hkctl get virtualmachines.kubevirt.io -n "$vm_ns" --no-headers -o name 2>/dev/null); do
          $hkctl patch "$vm" -n "$vm_ns" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
        done
      fi
    fi
  elif [[ "$phase" == "Active" ]]; then
    # Check for lingering VMs
    local vm_count
    vm_count=$($hkctl get virtualmachines.kubevirt.io -n "$vm_ns" --no-headers 2>/dev/null | wc -l)
    if [[ "$vm_count" -gt 0 ]]; then
      warn "Namespace '${vm_ns}' is Active with ${vm_count} VM(s) — previous cluster may still exist"
    else
      pass "Namespace '${vm_ns}' is Active (no VMs)"
    fi
  fi
}

# =============================================================================
# CHECK 4: terraform.tfvars
# =============================================================================
check_tfvars_file() {
  echo ""
  echo -e "${BOLD}4. Terraform Variables (cluster/terraform.tfvars)${NC}"

  local tfvars="${CLUSTER_DIR}/terraform.tfvars"
  local tfvars_example="${CLUSTER_DIR}/terraform.tfvars.example"

  if [[ ! -f "$tfvars" ]]; then
    fail "terraform.tfvars not found"
    if [[ -f "$tfvars_example" ]]; then
      if ask_fix "Copy terraform.tfvars.example to terraform.tfvars?"; then
        cp "$tfvars_example" "$tfvars"
        chmod 600 "$tfvars"
        pass "Copied terraform.tfvars.example — edit it before deploying"
      fi
    fi
    return
  fi

  pass "terraform.tfvars exists"

  # Check for required variables (no defaults in variables.tf)
  local required_vars=(rancher_url rancher_token harvester_kubeconfig_path
    harvester_cluster_id vm_namespace harvester_network_name
    harvester_network_namespace harvester_cloud_credential_name
    harvester_cloud_provider_kubeconfig_path cluster_name domain
    keycloak_realm ssh_authorized_keys)
  local missing=()

  for var in "${required_vars[@]}"; do
    if ! grep -q "^${var}\s*=" "$tfvars"; then
      missing+=("$var")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing required variables: ${missing[*]}"
  else
    pass "All required variables present"
  fi

  # Check for placeholder values (skip commented lines)
  if grep -v '^\s*#' "$tfvars" | grep -q 'example\.com\|xxxxx\|AAAA\.\.\.' ; then
    fail "terraform.tfvars contains example/placeholder values"
    echo "       Lines with placeholders:"
    grep -n 'example\.com\|xxxxx\|AAAA\.\.\.' "$tfvars" | grep -v '^\s*[0-9]*:\s*#' | sed 's/^/         /'
  else
    pass "No placeholder values detected"
  fi

  # Check golden image availability (informational)
  local use_golden
  use_golden=$(grep '^use_golden_image' "$tfvars" 2>/dev/null | grep -o 'true' || echo "false")
  if [[ "$use_golden" == "true" ]]; then
    local golden_name
    golden_name=$(_get_tfvar golden_image_name)
    if [[ -z "$golden_name" ]]; then
      warn "use_golden_image=true but golden_image_name is not set (deploy will generate a default)"
    else
      local harvester_kc="${CLUSTER_DIR}/kubeconfig-harvester.yaml"
      if [[ -f "$harvester_kc" ]]; then
        local hkctl="kubectl --kubeconfig=${harvester_kc}"
        local vm_ns
        vm_ns=$(get_vm_namespace 2>/dev/null) || vm_ns="rke2-prod"
        if $hkctl get virtualmachineimages.harvesterhci.io "${golden_name}" -n "${vm_ns}" &>/dev/null; then
          pass "Golden image '${golden_name}' exists in Harvester"
        else
          warn "Golden image '${golden_name}' not found in namespace '${vm_ns}' — deploy will prompt to build"
        fi
      else
        warn "Cannot verify golden image — no Harvester kubeconfig"
      fi
    fi
  fi
}

# =============================================================================
# CHECK 5: scripts/.env
# =============================================================================
check_env_file() {
  echo ""
  echo -e "${BOLD}5. Environment File (scripts/.env)${NC}"

  local env_file="${SCRIPTS_DIR}/.env"
  local env_example="${SCRIPTS_DIR}/.env.example"

  if [[ ! -f "$env_file" ]]; then
    warn ".env not found — deploy-cluster.sh will auto-generate one with random credentials"
    if [[ -f "$env_example" ]] && ask_fix "Copy .env.example to .env for manual editing?"; then
      cp "$env_example" "$env_file"
      chmod 600 "$env_file"
      pass "Copied .env.example — edit it before deploying or leave blank for auto-generation"
    fi
    return
  fi

  pass ".env exists"

  # Check DOMAIN
  # shellcheck disable=SC1090
  local env_domain
  env_domain=$(grep '^DOMAIN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
  if [[ -z "$env_domain" || "$env_domain" == "example.com" ]]; then
    warn "DOMAIN is '${env_domain:-<empty>}' (default) — change if deploying for a different domain"
  else
    pass "DOMAIN=${env_domain}"
  fi
}

# =============================================================================
# CHECK 6: Stale Resources from Previous Cluster
# =============================================================================
check_stale_resources() {
  echo ""
  echo -e "${BOLD}6. Stale Resources from Previous Cluster${NC}"

  local stale_files=()

  [[ -f "${CLUSTER_DIR}/vault-init.json" ]] && stale_files+=("cluster/vault-init.json")
  [[ -f "${CLUSTER_DIR}/errored.tfstate" ]] && stale_files+=("cluster/errored.tfstate")
  [[ -f "${CLUSTER_DIR}/rke2-prod.tfplan" ]] && stale_files+=("cluster/rke2-prod.tfplan")

  # Check for timestamped tfplan files
  local tfplan_count=0
  for f in "${CLUSTER_DIR}"/tfplan_*; do
    [[ -f "$f" ]] || continue
    stale_files+=("cluster/$(basename "$f")")
    tfplan_count=$((tfplan_count + 1))
  done

  if [[ ${#stale_files[@]} -eq 0 ]]; then
    pass "No stale files found"
    return
  fi

  fail "Found ${#stale_files[@]} stale file(s) from previous cluster"
  if [[ $tfplan_count -gt 3 ]]; then
    echo "       cluster/vault-init.json, cluster/errored.tfstate, cluster/rke2-prod.tfplan (if present)"
    echo "       + ${tfplan_count} old tfplan_* files"
  else
    for f in "${stale_files[@]}"; do
      echo "       ${f}"
    done
  fi

  if ask_fix "Remove all stale files?"; then
    for f in "${stale_files[@]}"; do
      rm -f "${REPO_ROOT}/${f}"
    done
    pass "Removed ${#stale_files[@]} stale file(s)"
  fi
}

# =============================================================================
# CHECK 7: Terraform State (informational)
# =============================================================================
check_terraform_state() {
  echo ""
  echo -e "${BOLD}7. Terraform State (Harvester secrets)${NC}"

  local harvester_kc="${CLUSTER_DIR}/kubeconfig-harvester.yaml"
  if [[ ! -f "$harvester_kc" ]]; then
    warn "Skipping — no Harvester kubeconfig available"
    return
  fi

  local hkctl="kubectl --kubeconfig=${harvester_kc}"

  if ! $hkctl get ns terraform-state &>/dev/null; then
    warn "terraform-state namespace does not exist on Harvester (will be created on first deploy)"
    return
  fi

  pass "terraform-state namespace exists"

  local secrets
  secrets=$($hkctl get secrets -n terraform-state --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
  if [[ -z "$secrets" ]]; then
    echo "       (no secrets stored)"
  else
    echo "       Stored secrets:"
    echo "$secrets" | sed 's/^/         /'
  fi

  # Check for stale terraform state lock
  local leases
  leases=$($hkctl get leases -n terraform-state --no-headers 2>/dev/null || true)
  if [[ -n "$leases" ]]; then
    local lock_name lock_holder
    lock_name=$(echo "$leases" | awk '{print $1}' | head -1)
    lock_holder=$(echo "$leases" | awk '{print $2}' | head -1)
    fail "Terraform state lock exists (stale from a killed run)"
    echo "       Lease: ${lock_name}  Holder: ${lock_holder}"
    echo "       Fix: cd cluster && terraform force-unlock -force ${lock_holder}"
    if ask_fix "Delete stale terraform state lock?"; then
      $hkctl delete lease "$lock_name" -n terraform-state && pass "State lock cleared"
    fi
  fi

  # Flag stale secrets
  if echo "$secrets" | grep -q "^vault-init$"; then
    warn "vault-init secret exists — stale from previous cluster"
    if ask_fix "Delete vault-init secret from terraform-state?"; then
      $hkctl delete secret vault-init -n terraform-state && pass "Deleted vault-init secret"
    fi
  fi
  if echo "$secrets" | grep -q "^tfstate-default-rke2-cluster$"; then
    warn "tfstate-default-rke2-cluster exists — stale Terraform state"
    if ask_fix "Delete tfstate-default-rke2-cluster secret?"; then
      $hkctl delete secret tfstate-default-rke2-cluster -n terraform-state && pass "Deleted tfstate-default-rke2-cluster"
    fi
  fi
}

# =============================================================================
# CHECK 8: Airgapped Mode (conditional)
# =============================================================================
check_airgapped() {
  echo ""
  echo -e "${BOLD}8. Airgapped Mode${NC}"

  local env_file="${SCRIPTS_DIR}/.env"
  local airgapped="false"
  if [[ -f "$env_file" ]]; then
    airgapped=$(grep '^AIRGAPPED=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || echo "false")
  fi

  if [[ "$airgapped" != "true" ]]; then
    pass "Airgapped mode is disabled (standard deployment)"
    return
  fi

  echo "       Airgapped mode is ENABLED — validating OCI chart variables..."

  local required_oci_vars=(
    HELM_OCI_CERT_MANAGER HELM_OCI_CNPG HELM_OCI_CLUSTER_AUTOSCALER
    HELM_OCI_REDIS_OPERATOR HELM_OCI_VAULT HELM_OCI_HARBOR
    HELM_OCI_ARGOCD HELM_OCI_ARGO_ROLLOUTS HELM_OCI_ARGO_WORKFLOWS HELM_OCI_ARGO_EVENTS
    HELM_OCI_KASM HELM_OCI_KPS
  )

  # Source env to check variable values
  # shellcheck disable=SC1090
  source "$env_file" 2>/dev/null || true

  local missing_oci=()
  for var in "${required_oci_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      missing_oci+=("$var")
    fi
  done

  if [[ -z "${UPSTREAM_PROXY_REGISTRY:-}" ]]; then
    fail "UPSTREAM_PROXY_REGISTRY is not set"
  else
    pass "UPSTREAM_PROXY_REGISTRY=${UPSTREAM_PROXY_REGISTRY}"
  fi

  if [[ -z "${GIT_BASE_URL:-}" ]]; then
    fail "GIT_BASE_URL is not set"
  else
    pass "GIT_BASE_URL=${GIT_BASE_URL}"
  fi

  if [[ ${#missing_oci[@]} -eq 0 ]]; then
    pass "All HELM_OCI_* variables are set"
  else
    fail "Missing ${#missing_oci[@]} HELM_OCI_* variable(s): ${missing_oci[*]}"
  fi
}

# =============================================================================
# CHECK 9: Network Dependency Audit
# =============================================================================
# Enumerates every external host the deployment would contact and reports
# whether each is reachable (standard mode) or overridden (airgapped mode).
# =============================================================================
check_network_dependencies() {
  echo ""
  echo -e "${BOLD}9. Network Dependency Audit${NC}"

  # Load .env if present (non-destructive — just for reading config)
  local env_file="${SCRIPTS_DIR}/.env"
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file" 2>/dev/null || true
  fi
  local airgapped="${AIRGAPPED:-false}"

  if [[ "$airgapped" == "true" ]]; then
    echo -e "       Mode: ${RED}AIRGAPPED${NC} — checking that nothing escapes to the internet"
  else
    echo -e "       Mode: ${CYAN}ONLINE${NC} — listing external hosts that will be contacted"
  fi

  # -------------------------------------------------------------------------
  # 9a. Helm chart repositories (https:// URLs used by helm_repo_add)
  # -------------------------------------------------------------------------
  echo ""
  echo -e "  ${BOLD}9a. Helm Chart Repositories${NC}"
  #  name | upstream_url | oci_override_var (empty = no override exists)
  local helm_repos=(
    "jetstack|https://charts.jetstack.io|HELM_OCI_CERT_MANAGER"
    "cnpg|https://cloudnative-pg.github.io/charts|HELM_OCI_CNPG"
    "autoscaler|https://kubernetes.github.io/autoscaler|HELM_OCI_CLUSTER_AUTOSCALER"
    "ot-helm|https://ot-container-kit.github.io/helm-charts/|HELM_OCI_REDIS_OPERATOR"
    "mariadb-operator|https://mariadb-operator.github.io/mariadb-operator|HELM_OCI_MARIADB_OPERATOR"
    "hashicorp|https://helm.releases.hashicorp.com|HELM_OCI_VAULT"
    "prometheus-community|https://prometheus-community.github.io/helm-charts|HELM_OCI_KPS"
    "goharbor|https://helm.goharbor.io|HELM_OCI_HARBOR"
    "kasmtech|https://helm.kasmweb.com/|HELM_OCI_KASM"
    "external-secrets|https://charts.external-secrets.io|HELM_OCI_EXTERNAL_SECRETS"
    "gitlab|https://charts.gitlab.io|HELM_OCI_GITLAB_RUNNER"
  )

  # OCI-based charts (ghcr.io)
  local oci_charts=(
    "argo-cd|oci://ghcr.io/argoproj/argo-helm/argo-cd|HELM_OCI_ARGOCD"
    "argo-rollouts|oci://ghcr.io/argoproj/argo-helm/argo-rollouts|HELM_OCI_ARGO_ROLLOUTS"
    "argo-workflows|oci://ghcr.io/argoproj/argo-helm/argo-workflows|HELM_OCI_ARGO_WORKFLOWS"
    "argo-events|oci://ghcr.io/argoproj/argo-helm/argo-events|HELM_OCI_ARGO_EVENTS"
  )

  for entry in "${helm_repos[@]}"; do
    IFS='|' read -r name url oci_var <<< "$entry"
    local host; host=$(echo "$url" | sed 's|https\?://||;s|/.*||')
    if [[ "$airgapped" == "true" ]]; then
      local override="${!oci_var:-}"
      if [[ -n "$override" ]]; then
        pass "${name}: overridden via ${oci_var}"
      else
        fail "${name}: would fetch from ${host} — set ${oci_var}"
      fi
    else
      if curl -sf --connect-timeout 3 --max-time 5 "${url}/index.yaml" -o /dev/null 2>/dev/null \
         || curl -sf --connect-timeout 3 --max-time 5 "${url}" -o /dev/null 2>/dev/null; then
        pass "${name}: ${host} reachable"
      else
        warn "${name}: ${host} not reachable (may just need deploy-time access)"
      fi
    fi
  done

  for entry in "${oci_charts[@]}"; do
    IFS='|' read -r name url oci_var <<< "$entry"
    if [[ "$airgapped" == "true" ]]; then
      local override="${!oci_var:-}"
      if [[ -n "$override" ]]; then
        pass "${name}: overridden via ${oci_var}"
      else
        fail "${name}: would fetch from ghcr.io — set ${oci_var}"
      fi
    else
      pass "${name}: ghcr.io (OCI)"
    fi
  done

  # -------------------------------------------------------------------------
  # 9b. Container image registries
  # -------------------------------------------------------------------------
  echo ""
  echo -e "  ${BOLD}9b. Container Image Registries${NC}"
  echo "       Cluster nodes pull images directly from these registries during Phases 0-5."
  echo "       After Phase 6, Harbor proxy-cache handles pulls. All must be reachable from nodes."

  local registries=(
    "docker.io|registry-1.docker.io|Docker Hub"
    "quay.io|quay.io|Quay.io"
    "ghcr.io|ghcr.io|GitHub Container Registry"
    "gcr.io|gcr.io|Google Container Registry"
    "registry.k8s.io|registry.k8s.io|Kubernetes Registry"
    "docker.elastic.co|docker.elastic.co|Elastic"
  )

  if [[ "$airgapped" == "true" ]]; then
    if [[ -n "${UPSTREAM_PROXY_REGISTRY:-}" ]]; then
      pass "Proxy registries routed through ${UPSTREAM_PROXY_REGISTRY}"
    else
      fail "UPSTREAM_PROXY_REGISTRY not set — Harbor proxy-cache will hit upstream directly"
    fi
  else
    for entry in "${registries[@]}"; do
      IFS='|' read -r project host desc <<< "$entry"
      # Registry /v2/ endpoints require auth (return 401), so check DNS + TCP instead
      if curl -sf --connect-timeout 3 --max-time 5 -o /dev/null "https://${host}/v2/" 2>/dev/null; then
        pass "${desc} (${host}): reachable"
      elif curl -sI --connect-timeout 3 --max-time 5 "https://${host}/v2/" 2>/dev/null | head -1 | grep -qE "HTTP/[0-9.]+ [2345]"; then
        pass "${desc} (${host}): reachable (auth required)"
      else
        warn "${desc} (${host}): not reachable from this host (must be reachable from cluster nodes)"
      fi
    done
  fi

  # Count external images referenced in services/
  local ext_images
  ext_images=$(grep -rh '^\s*image:' "${SERVICES_DIR}/" 2>/dev/null \
    | grep -v '#' \
    | sed 's/.*image:\s*//' | tr -d '"' | tr -d "'" \
    | xargs -n1 2>/dev/null \
    | grep -E '^[a-z].*[:/]' \
    | grep -v 'CHANGEME\|harbor\.' \
    | sort -u || true)
  local img_count
  img_count=$(echo "$ext_images" | grep -c . 2>/dev/null || echo 0)
  echo ""
  echo "       ${img_count} unique external container images in services/ manifests:"
  echo "$ext_images" | sed 's/^/         /' | head -30
  if [[ $img_count -gt 30 ]]; then
    echo "         ... ($(( img_count - 30 )) more)"
  fi

  # -------------------------------------------------------------------------
  # 9c. Binary/CRD downloads from GitHub
  # -------------------------------------------------------------------------
  echo ""
  echo -e "  ${BOLD}9c. GitHub Downloads (binaries, CRDs, plugins)${NC}"

  # name | current_url | env_var_name | local_cache_path
  local github_downloads=(
    "Gateway API CRDs|${GATEWAY_API_CRD_URL:-https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml}|GATEWAY_API_CRD_URL|crds/gateway-api-v1.3.0-standard-install.yaml"
    "Argo Rollouts GW plugin|${ARGO_ROLLOUTS_PLUGIN_URL:-https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.5.0/gateway-api-plugin-linux-amd64}|ARGO_ROLLOUTS_PLUGIN_URL|"
    "ArgoCD CLI (runner)|${BINARY_URL_ARGOCD_CLI:-https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64}|BINARY_URL_ARGOCD_CLI|"
    "Kustomize (runner)|${BINARY_URL_KUSTOMIZE:-https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v5.6.0/kustomize_v5.6.0_linux_amd64.tar.gz}|BINARY_URL_KUSTOMIZE|"
    "kubeconform (runner)|${BINARY_URL_KUBECONFORM:-https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz}|BINARY_URL_KUBECONFORM|"
    "CRD schemas (runner)|${CRD_SCHEMA_BASE_URL:-https://raw.githubusercontent.com/datreeio/CRDs-catalog/main}|CRD_SCHEMA_BASE_URL|"
  )

  for entry in "${github_downloads[@]}"; do
    IFS='|' read -r name url var_name local_cache <<< "$entry"
    if [[ "$airgapped" == "true" ]]; then
      if [[ -n "$local_cache" && -f "${REPO_ROOT}/${local_cache}" ]]; then
        pass "${name}: cached locally at ${local_cache}"
      elif [[ "$url" == *"github.com"* || "$url" == *"githubusercontent.com"* ]]; then
        fail "${name}: still points to github.com — set ${var_name} in .env"
      else
        pass "${name}: overridden to ${url%%//*}/..."
      fi
    else
      if [[ "$url" == *"github.com"* || "$url" == *"githubusercontent.com"* ]]; then
        warn "${name}: downloads from github.com (override: ${var_name})"
      else
        pass "${name}: ${url%%//*}/... (overridden via ${var_name})"
      fi
    fi
  done

  # -------------------------------------------------------------------------
  # 9d. Rocky Linux VM image
  # -------------------------------------------------------------------------
  echo ""
  echo -e "  ${BOLD}9d. Rocky Linux VM Image${NC}"

  local rocky_url="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
  # Check if golden image is configured (avoids download)
  local use_golden="false"
  if [[ -f "${CLUSTER_DIR}/terraform.tfvars" ]]; then
    use_golden=$(grep '^use_golden_image' "${CLUSTER_DIR}/terraform.tfvars" 2>/dev/null \
      | grep -o 'true' || echo "false")
  fi

  if [[ "$use_golden" == "true" ]]; then
    pass "Using golden image (no Rocky download needed)"
  elif [[ "$airgapped" == "true" ]]; then
    fail "Standard mode downloads Rocky 9 qcow2 from dl.rockylinux.org — use golden image or pre-upload"
  else
    if curl -sf --connect-timeout 3 --max-time 5 -I "$rocky_url" -o /dev/null 2>/dev/null; then
      pass "dl.rockylinux.org: reachable"
    else
      warn "dl.rockylinux.org: not reachable — Terraform image upload may fail"
    fi
  fi

  # -------------------------------------------------------------------------
  # 9e. CI pipeline images (runners pull these at job time)
  # -------------------------------------------------------------------------
  echo ""
  echo -e "  ${BOLD}9e. CI Pipeline Images (pulled by runners via Harbor proxy-cache)${NC}"

  local ci_images=(
    "golang:1.23-alpine"
    "node:22-alpine"
    "python:3.12-slim"
    "gcr.io/kaniko-project/executor:v1.23.2-debug"
    "argoproj/argocd:v2.14.0"
    "bitnami/git:latest"
    "gcr.io/go-containerregistry/crane:debug"
    "zricethezav/gitleaks:latest"
    "semgrep/semgrep:latest"
    "aquasec/trivy:latest"
    "anchore/syft:latest"
    "hadolint/hadolint:latest-alpine"
    "cytopia/yamllint:latest"
    "koalaman/shellcheck-alpine:stable"
    "bitnami/kubectl:latest"
    "alpine:3.21"
  )

  echo "       ${#ci_images[@]} images used by CI pipelines (pulled through Harbor proxy-cache):"
  for img in "${ci_images[@]}"; do
    echo "         ${img}"
  done

  if [[ "$airgapped" == "true" ]]; then
    warn "CI images must be pre-cached in Harbor or available through UPSTREAM_PROXY_REGISTRY"
    echo "       Run: ./scripts/prefetch-ci-images.sh (after Harbor is up) to warm the proxy cache"
  else
    pass "CI images will be pulled through Harbor proxy-cache (requires internet during first pull)"
  fi

  # -------------------------------------------------------------------------
  # 9f. Summary of unique external hostnames
  # -------------------------------------------------------------------------
  echo ""
  echo -e "  ${BOLD}9f. Firewall Allowlist (all external hostnames)${NC}"
  local hostnames=(
    "charts.jetstack.io"
    "cloudnative-pg.github.io"
    "kubernetes.github.io"
    "ot-container-kit.github.io"
    "mariadb-operator.github.io"
    "helm.releases.hashicorp.com"
    "prometheus-community.github.io"
    "helm.goharbor.io"
    "helm.kasmweb.com"
    "charts.external-secrets.io"
    "charts.gitlab.io"
    "ghcr.io"
    "registry-1.docker.io"
    "auth.docker.io"
    "production.cloudflare.docker.com"
    "quay.io"
    "gcr.io"
    "registry.k8s.io"
    "docker.elastic.co"
    "github.com"
    "objects.githubusercontent.com"
    "raw.githubusercontent.com"
    "dl.rockylinux.org"
  )

  if [[ "$airgapped" == "true" ]]; then
    echo "       In airgapped mode, NONE of these should be reachable from the cluster."
    echo "       All traffic must route through internal mirrors."
    local leaks=0
    for host in "${hostnames[@]}"; do
      if curl -sf --connect-timeout 2 --max-time 3 "https://${host}" -o /dev/null 2>/dev/null; then
        fail "${host} is reachable (should be blocked in airgapped mode)"
        leaks=$((leaks + 1))
      fi
    done
    if [[ $leaks -eq 0 ]]; then
      pass "No external hosts reachable — airgap looks solid"
    fi
  else
    echo "       Ensure these hosts are allowed through your firewall (HTTPS/443):"
    for host in "${hostnames[@]}"; do
      echo "         ${host}"
    done
    pass "${#hostnames[@]} external hostnames required for standard deployment"
  fi
}

# =============================================================================
# FETCH LIST — Consolidated shopping list of all external dependencies
# =============================================================================
print_fetch_list() {
  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BOLD}${BLUE}  Fetch List — Everything to download for offline/airgapped${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo ""
  echo "Pipe to a file:  ./scripts/precheck.sh --fetch-list > fetch-list.txt"

  # Load .env if present
  local env_file="${SCRIPTS_DIR}/.env"
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file" 2>/dev/null || true
  fi

  # --- Helm Charts ---
  echo ""
  echo -e "${BOLD}--- Helm Chart Repositories ---${NC}"
  echo "# Add these repos, then 'helm pull' each chart you need:"
  echo "helm repo add jetstack https://charts.jetstack.io"
  echo "helm repo add cnpg https://cloudnative-pg.github.io/charts"
  echo "helm repo add autoscaler https://kubernetes.github.io/autoscaler"
  echo "helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/"
  echo "helm repo add mariadb-operator https://mariadb-operator.github.io/mariadb-operator"
  echo "helm repo add hashicorp https://helm.releases.hashicorp.com"
  echo "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
  echo "helm repo add goharbor https://helm.goharbor.io"
  echo "helm repo add kasmtech https://helm.kasmweb.com/"
  echo "helm repo add external-secrets https://charts.external-secrets.io"
  echo "helm repo add gitlab https://charts.gitlab.io"
  echo ""
  echo "# OCI charts (helm pull directly):"
  echo "helm pull oci://ghcr.io/argoproj/argo-helm/argo-cd"
  echo "helm pull oci://ghcr.io/argoproj/argo-helm/argo-rollouts"
  echo "helm pull oci://ghcr.io/argoproj/argo-helm/argo-workflows"
  echo "helm pull oci://ghcr.io/argoproj/argo-helm/argo-events"

  # --- Binary Downloads ---
  echo ""
  echo -e "${BOLD}--- Binary / CRD Downloads ---${NC}"
  echo "# Download these and host on your internal mirror (GitLab generic packages, Nexus, etc.)"
  echo "# Then set the corresponding variable in scripts/.env"
  echo ""
  echo "# GATEWAY_API_CRD_URL (or save to crds/gateway-api-v1.3.0-standard-install.yaml)"
  echo "curl -sSLO https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml"
  echo ""
  echo "# ARGO_ROLLOUTS_PLUGIN_URL"
  echo "curl -sSLO https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.5.0/gateway-api-plugin-linux-amd64"
  echo ""
  echo "# BINARY_URL_ARGOCD_CLI"
  echo "curl -sSLO https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64"
  echo ""
  echo "# BINARY_URL_KUSTOMIZE"
  echo "curl -sSLO https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v5.6.0/kustomize_v5.6.0_linux_amd64.tar.gz"
  echo ""
  echo "# BINARY_URL_KUBECONFORM"
  echo "curl -sSLO https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz"
  echo ""
  echo "# CRD_SCHEMA_BASE_URL — mirror the datreeio/CRDs-catalog repo"
  echo "# git clone https://github.com/datreeio/CRDs-catalog.git"

  # --- Container Images ---
  echo ""
  echo -e "${BOLD}--- Container Images (services/) ---${NC}"
  echo "# Pull these and push to your internal Harbor/registry."
  echo "# After Harbor is up, these are served via proxy-cache projects."
  echo "# Use: crane pull <image> <tarball> && crane push <tarball> harbor.DOMAIN/proxy/<image>"
  echo ""

  local ext_images
  ext_images=$(grep -rh '^\s*image:' "${SERVICES_DIR}/" 2>/dev/null \
    | grep -v '#' \
    | sed 's/.*image:\s*//' | tr -d '"' | tr -d "'" \
    | xargs -n1 2>/dev/null \
    | grep -E '^[a-z].*[:/]' \
    | grep -v 'CHANGEME\|harbor\.' \
    | sort -u || true)
  echo "$ext_images"

  # --- CI Pipeline Images ---
  echo ""
  echo -e "${BOLD}--- CI Pipeline Images (pulled by GitLab runners) ---${NC}"
  echo "# Pre-cache in Harbor: ./scripts/prefetch-ci-images.sh (after Harbor is up)"
  echo ""
  local ci_images=(
    "docker.io/library/golang:1.23-alpine"
    "docker.io/library/node:22-alpine"
    "docker.io/library/python:3.12-slim"
    "gcr.io/kaniko-project/executor:v1.23.2-debug"
    "docker.io/argoproj/argocd:v2.14.0"
    "docker.io/bitnami/git:latest"
    "gcr.io/go-containerregistry/crane:debug"
    "docker.io/zricethezav/gitleaks:latest"
    "docker.io/semgrep/semgrep:latest"
    "docker.io/aquasec/trivy:latest"
    "docker.io/anchore/syft:latest"
    "docker.io/hadolint/hadolint:latest-alpine"
    "docker.io/cytopia/yamllint:latest"
    "docker.io/koalaman/shellcheck-alpine:stable"
    "docker.io/bitnami/kubectl:latest"
    "docker.io/library/alpine:3.21"
  )
  for img in "${ci_images[@]}"; do
    echo "$img"
  done

  # --- .env Override Variables ---
  echo ""
  echo -e "${BOLD}--- .env Variables for Airgapped Overrides ---${NC}"
  echo "# Set these in scripts/.env to point at your internal mirrors:"
  echo ""
  echo "AIRGAPPED=\"true\""
  echo "UPSTREAM_PROXY_REGISTRY=\"harbor.example.com\"  # Harbor proxy-cache upstream"
  echo ""
  echo "# Helm chart OCI overrides (push charts to your Harbor OCI registry):"
  echo "HELM_OCI_CERT_MANAGER=\"oci://harbor.example.com/charts/cert-manager\""
  echo "HELM_OCI_CNPG=\"oci://harbor.example.com/charts/cloudnative-pg\""
  echo "HELM_OCI_CLUSTER_AUTOSCALER=\"oci://harbor.example.com/charts/cluster-autoscaler\""
  echo "HELM_OCI_REDIS_OPERATOR=\"oci://harbor.example.com/charts/redis-operator\""
  echo "HELM_OCI_VAULT=\"oci://harbor.example.com/charts/vault\""
  echo "HELM_OCI_HARBOR=\"oci://harbor.example.com/charts/harbor\""
  echo "HELM_OCI_ARGOCD=\"oci://harbor.example.com/charts/argo-cd\""
  echo "HELM_OCI_ARGO_ROLLOUTS=\"oci://harbor.example.com/charts/argo-rollouts\""
  echo "HELM_OCI_ARGO_WORKFLOWS=\"oci://harbor.example.com/charts/argo-workflows\""
  echo "HELM_OCI_ARGO_EVENTS=\"oci://harbor.example.com/charts/argo-events\""
  echo "HELM_OCI_KASM=\"oci://harbor.example.com/charts/kasm\""
  echo "HELM_OCI_KPS=\"oci://harbor.example.com/charts/kube-prometheus-stack\""
  echo "HELM_OCI_EXTERNAL_SECRETS=\"oci://harbor.example.com/charts/external-secrets\""
  echo "HELM_OCI_GITLAB_RUNNER=\"oci://harbor.example.com/charts/gitlab-runner\""
  echo ""
  echo "# Binary/CRD download overrides (host on GitLab generic packages, Nexus, etc.):"
  echo "BINARY_URL_ARGOCD_CLI=\"https://gitlab.example.com/api/v4/projects/42/packages/generic/argocd/v2.14.0/argocd-linux-amd64\""
  echo "BINARY_URL_KUSTOMIZE=\"https://gitlab.example.com/api/v4/projects/42/packages/generic/kustomize/v5.6.0/kustomize_v5.6.0_linux_amd64.tar.gz\""
  echo "BINARY_URL_KUBECONFORM=\"https://gitlab.example.com/api/v4/projects/42/packages/generic/kubeconform/v0.6.7/kubeconform-linux-amd64.tar.gz\""
  echo "CRD_SCHEMA_BASE_URL=\"https://gitlab.example.com/infra/crd-schemas/-/raw/main\""
  echo "GATEWAY_API_CRD_URL=\"https://gitlab.example.com/api/v4/projects/42/packages/generic/gateway-api/v1.3.0/standard-install.yaml\""
  echo "ARGO_ROLLOUTS_PLUGIN_URL=\"https://gitlab.example.com/api/v4/projects/42/packages/generic/argo-rollouts-plugin/v0.5.0/gateway-api-plugin-linux-amd64\""
  echo ""
}

# =============================================================================
# RUN ALL CHECKS
# =============================================================================
main() {
  # Handle --fetch-list before running checks
  if [[ "$FETCH_LIST" == "true" ]]; then
    print_fetch_list
    exit 0
  fi

  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BOLD}${BLUE}  RKE2 Cluster Deployment — Pre-flight Checks${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  if [[ "$FIX_MODE" == "true" ]]; then
    echo -e "  Mode: ${CYAN}Interactive Fix${NC}"
  else
    echo -e "  Mode: ${CYAN}Report Only${NC} (use --fix for interactive remediation)"
  fi

  check_tools
  check_harvester_context
  check_harvester_namespace
  check_tfvars_file
  check_env_file
  check_stale_resources
  check_terraform_state
  check_airgapped
  check_network_dependencies

  # Summary
  echo ""
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}  Summary: ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}, ${YELLOW}${WARNINGS} warnings${NC}"
  echo -e "${BOLD}============================================================${NC}"

  if [[ $FAILED -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}Ready to deploy!${NC} Run: ./scripts/deploy-cluster.sh"
    echo ""
    exit 0
  else
    echo ""
    echo -e "${RED}Fix the above failures before deploying.${NC}"
    if [[ "$FIX_MODE" != "true" ]]; then
      echo "Run with --fix to interactively remediate fixable issues."
    fi
    echo ""
    echo -e "Run ${CYAN}./scripts/precheck.sh --fetch-list${NC} to see all external dependencies."
    echo ""
    exit 1
  fi
}

main
