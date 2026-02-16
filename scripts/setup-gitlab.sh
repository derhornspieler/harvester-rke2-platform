#!/usr/bin/env bash
# =============================================================================
# setup-gitlab.sh — Deploy GitLab to RKE2 Cluster
# =============================================================================
# Deploys GitLab EE using the upstream Helm chart with:
#   - Gateway API (Traefik) instead of standard Ingress
#   - OpsTree Redis Operator (RedisReplication + RedisSentinel)
#   - CloudNativePG PostgreSQL
#   - Vault CA trust + Keycloak OIDC
#
# Prerequisites:
#   - RKE2 cluster deployed (deploy-cluster.sh completed)
#   - KUBECONFIG set to RKE2 cluster
#   - CNPG operator running in cnpg-system
#   - OpsTree Redis operator running in redis-operator-system
#   - Keycloak OIDC setup completed (setup-keycloak.sh)
#   - GitLab chart checkout at GITLAB_CHART_PATH (default: /home/rocky/data/gitlab)
#
# Usage:
#   export KUBECONFIG=/path/to/kubeconfig-rke2.yaml
#   ./scripts/setup-gitlab.sh              # Full deployment
#   ./scripts/setup-gitlab.sh --from 3     # Resume from phase 3
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# -----------------------------------------------------------------------------
# CLI Arguments
# -----------------------------------------------------------------------------
FROM_PHASE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM_PHASE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--from PHASE_NUMBER]"
      echo "  --from N     Resume from phase N (1-7)"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Load credentials from .env
generate_or_load_env

# OIDC secrets file (created by setup-keycloak.sh)
OIDC_SECRETS_FILE="${SCRIPTS_DIR}/oidc-client-secrets.json"

# =============================================================================
# PHASE 1: PREREQUISITES
# =============================================================================
phase_1_prerequisites() {
  start_phase "PHASE 1: PREREQUISITES"

  log_step "Verifying required operators..."

  # Verify CNPG operator
  if ! kubectl get deployment -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg --no-headers 2>/dev/null | grep -q .; then
    die "CloudNativePG operator not found in cnpg-system. Install it first."
  fi
  log_ok "CNPG operator running"

  # Verify OpsTree Redis operator
  if ! kubectl get deployment -n redis-operator-system --no-headers 2>/dev/null | grep -q .; then
    die "OpsTree Redis operator not found in redis-operator-system. Install it first."
  fi
  log_ok "Redis operator running"

  # Verify GitLab chart path
  if [[ ! -f "${GITLAB_CHART_PATH}/Chart.yaml" ]]; then
    die "GitLab chart not found at ${GITLAB_CHART_PATH}. Set GITLAB_CHART_PATH in .env"
  fi
  log_ok "GitLab chart found at ${GITLAB_CHART_PATH}"

  log_step "Creating namespaces..."
  ensure_namespace gitlab
  ensure_namespace database

  log_step "Labeling unlabeled nodes..."
  label_unlabeled_nodes

  log_step "Distributing Root CA to gitlab namespace..."
  local root_ca
  root_ca=$(extract_root_ca)
  if [[ -n "$root_ca" ]]; then
    kubectl create configmap vault-root-ca \
      --from-literal=ca.crt="$root_ca" \
      -n gitlab --dry-run=client -o yaml | kubectl apply -f -
    log_ok "vault-root-ca ConfigMap in gitlab"
  else
    log_warn "Could not extract Root CA — gitlab pods may have TLS issues"
  fi

  end_phase "PHASE 1: PREREQUISITES"
}

# =============================================================================
# PHASE 2: DEPLOY CNPG POSTGRESQL
# =============================================================================
phase_2_postgresql() {
  start_phase "PHASE 2: DEPLOY CNPG POSTGRESQL"

  # Check if cluster already exists
  if kubectl get cluster gitlab-postgresql -n database &>/dev/null; then
    log_info "CNPG cluster gitlab-postgresql already exists"
  else
    log_step "Deploying CNPG PostgreSQL cluster..."
    kube_apply -f "${SERVICES_DIR}/gitlab/cloudnativepg-cluster.yaml"
  fi

  log_step "Waiting for CNPG primary..."
  wait_for_cnpg_primary database gitlab-postgresql 600

  end_phase "PHASE 2: DEPLOY CNPG POSTGRESQL"
}

# =============================================================================
# PHASE 3: CREATE SECRETS
# =============================================================================
phase_3_secrets() {
  start_phase "PHASE 3: CREATE SECRETS"

  # 3.1 Copy CNPG app secret cross-namespace: database → gitlab
  log_step "Copying CNPG app secret to gitlab namespace..."
  if kubectl get secret gitlab-postgresql-app -n gitlab &>/dev/null; then
    log_info "Secret gitlab-postgresql-app already exists in gitlab namespace"
  else
    kubectl get secret gitlab-postgresql-app -n database -o json | \
      python3 -c "import sys,json; s=json.load(sys.stdin); \
      s['metadata']={'name':s['metadata']['name'],'namespace':'gitlab'}; \
      json.dump(s,sys.stdout)" | kubectl apply -f -
    log_ok "Copied gitlab-postgresql-app to gitlab namespace"
  fi

  # 3.2 Create Praefect DB user and database
  log_step "Creating Praefect database user..."
  local primary_pod
  primary_pod=$(kubectl -n database get pods \
    -l "cnpg.io/cluster=gitlab-postgresql,cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$primary_pod" ]]; then
    die "Could not find CNPG primary pod"
  fi

  # Idempotent: ALTER USER to set password (works whether user exists or not from bootstrap)
  kubectl exec -n database "$primary_pod" -- psql -U postgres -c \
    "DO \$\$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'praefect') THEN
        CREATE USER praefect WITH PASSWORD '${GITLAB_PRAEFECT_DB_PASSWORD}';
      ELSE
        ALTER USER praefect WITH PASSWORD '${GITLAB_PRAEFECT_DB_PASSWORD}';
      END IF;
    END \$\$;" 2>/dev/null
  log_ok "Praefect user configured"

  # Create praefect database if not exists
  local db_exists
  db_exists=$(kubectl exec -n database "$primary_pod" -- psql -U postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = 'praefect'" 2>/dev/null || echo "")
  if [[ "$db_exists" != "1" ]]; then
    kubectl exec -n database "$primary_pod" -- psql -U postgres -c \
      "CREATE DATABASE praefect OWNER praefect;" 2>/dev/null
    log_ok "Praefect database created"
  else
    log_info "Praefect database already exists"
  fi

  # 3.3 Create K8s secrets in gitlab namespace (all idempotent)
  log_step "Creating GitLab K8s secrets..."

  # Praefect DB secret
  if ! kubectl get secret gitlab-praefect-dbsecret -n gitlab &>/dev/null; then
    kubectl create secret generic gitlab-praefect-dbsecret \
      --from-literal=secret="${GITLAB_PRAEFECT_DB_PASSWORD}" -n gitlab
    log_ok "Created gitlab-praefect-dbsecret"
  else
    log_info "Secret gitlab-praefect-dbsecret already exists"
  fi

  # Praefect token
  if ! kubectl get secret gitlab-praefect-secret -n gitlab &>/dev/null; then
    kubectl create secret generic gitlab-praefect-secret \
      --from-literal=token="${GITLAB_PRAEFECT_TOKEN}" -n gitlab
    log_ok "Created gitlab-praefect-secret"
  else
    log_info "Secret gitlab-praefect-secret already exists"
  fi

  # Gitaly auth token
  if ! kubectl get secret gitlab-gitaly-secret -n gitlab &>/dev/null; then
    kubectl create secret generic gitlab-gitaly-secret \
      --from-literal=token="${GITLAB_GITALY_TOKEN}" -n gitlab
    log_ok "Created gitlab-gitaly-secret"
  else
    log_info "Secret gitlab-gitaly-secret already exists"
  fi

  # GitLab root password
  if ! kubectl get secret gitlab-gitlab-initial-root-password -n gitlab &>/dev/null; then
    kubectl create secret generic gitlab-gitlab-initial-root-password \
      --from-literal=password="${GITLAB_ROOT_PASSWORD}" -n gitlab
    log_ok "Created gitlab-gitlab-initial-root-password"
  else
    log_info "Secret gitlab-gitlab-initial-root-password already exists"
  fi

  # Root CA as Secret (for chart's global.certificates.customCAs)
  log_step "Creating Root CA secret for GitLab..."
  local root_ca
  root_ca=$(extract_root_ca)
  if [[ -n "$root_ca" ]]; then
    kubectl create secret generic gitlab-root-ca \
      --from-literal=gitlab-root-ca.crt="$root_ca" \
      -n gitlab --dry-run=client -o yaml | kubectl apply -f -
    log_ok "Created gitlab-root-ca secret"
  else
    log_warn "Could not extract Root CA — skipping gitlab-root-ca secret"
  fi

  # OIDC provider secret (for OmniAuth)
  log_step "Creating GitLab OIDC secret..."
  if ! kubectl get secret gitlab-oidc-secret -n gitlab &>/dev/null; then
    local gitlab_oidc_client_secret=""
    if [[ -f "$OIDC_SECRETS_FILE" ]]; then
      gitlab_oidc_client_secret=$(jq -r '.gitlab // empty' "$OIDC_SECRETS_FILE")
    fi
    if [[ -z "$gitlab_oidc_client_secret" ]]; then
      log_warn "GitLab OIDC client secret not found in ${OIDC_SECRETS_FILE}"
      log_warn "Run setup-keycloak.sh first, then re-run this script from phase 3"
      log_warn "Skipping OIDC secret creation"
    else
      local oidc_issuer="https://keycloak.${DOMAIN}/realms/${KC_REALM}"
      local provider_json
      provider_json=$(cat <<OIDCEOF
{
  "name": "openid_connect",
  "label": "Keycloak",
  "args": {
    "name": "openid_connect",
    "scope": ["openid", "profile", "email"],
    "response_type": "code",
    "issuer": "${oidc_issuer}",
    "discovery": true,
    "client_auth_method": "query",
    "uid_field": "preferred_username",
    "pkce": true,
    "client_options": {
      "identifier": "gitlab",
      "secret": "${gitlab_oidc_client_secret}",
      "redirect_uri": "https://gitlab.${DOMAIN}/users/auth/openid_connect/callback"
    }
  }
}
OIDCEOF
)
      kubectl create secret generic gitlab-oidc-secret \
        --from-literal=provider="$provider_json" -n gitlab
      log_ok "Created gitlab-oidc-secret"
    fi
  else
    log_info "Secret gitlab-oidc-secret already exists"
  fi

  end_phase "PHASE 3: CREATE SECRETS"
}

# =============================================================================
# PHASE 4: DEPLOY OPSTREE REDIS
# =============================================================================
phase_4_redis() {
  start_phase "PHASE 4: DEPLOY OPSTREE REDIS"

  log_step "Deploying Redis credentials secret..."
  kube_apply_subst "${SERVICES_DIR}/gitlab/redis/secret.yaml"

  log_step "Deploying RedisReplication..."
  kube_apply -f "${SERVICES_DIR}/gitlab/redis/replication.yaml"

  log_step "Deploying RedisSentinel..."
  kube_apply -f "${SERVICES_DIR}/gitlab/redis/sentinel.yaml"

  log_step "Waiting for Redis replication pods..."
  wait_for_pods_ready gitlab "app=gitlab-redis" 300

  log_step "Waiting for Redis sentinel pods..."
  wait_for_pods_ready gitlab "app=gitlab-redis-sentinel" 300

  end_phase "PHASE 4: DEPLOY OPSTREE REDIS"
}

# =============================================================================
# PHASE 5: DEPLOY GATEWAY
# =============================================================================
phase_5_gateway() {
  start_phase "PHASE 5: DEPLOY GATEWAY"

  log_step "Deploying GitLab Gateway (cert-manager + Traefik)..."
  kube_apply_subst "${SERVICES_DIR}/gitlab/gateway.yaml"

  log_ok "Gateway deployed — cert-manager will issue TLS certificates"

  end_phase "PHASE 5: DEPLOY GATEWAY"
}

# =============================================================================
# PHASE 6: INSTALL GITLAB VIA HELM
# =============================================================================
phase_6_helm_install() {
  start_phase "PHASE 6: INSTALL GITLAB VIA HELM"

  # Build dependencies if charts/ is stale or missing
  log_step "Building Helm chart dependencies..."
  if [[ ! -d "${GITLAB_CHART_PATH}/charts" ]] || \
     [[ "${GITLAB_CHART_PATH}/Chart.lock" -nt "${GITLAB_CHART_PATH}/charts" ]]; then
    helm dependency build "${GITLAB_CHART_PATH}" 2>/dev/null || \
      log_warn "helm dependency build had warnings (may be OK if charts/ already populated)"
  else
    log_info "Chart dependencies already built"
  fi

  # Preprocess values with domain/credential substitution
  log_step "Preprocessing values file..."
  local processed_values
  processed_values=$(mktemp /tmp/gitlab-values-XXXXXX.yaml)
  _subst_changeme < "${SERVICES_DIR}/gitlab/values-rke2-prod.yaml" > "$processed_values"

  # Install or upgrade
  log_step "Installing GitLab via Helm..."
  if helm status gitlab -n gitlab &>/dev/null; then
    log_info "Helm release 'gitlab' already exists, upgrading..."
    helm upgrade gitlab "${GITLAB_CHART_PATH}" \
      -f "$processed_values" \
      -n gitlab \
      --timeout 15m
  else
    helm install gitlab "${GITLAB_CHART_PATH}" \
      -f "$processed_values" \
      -n gitlab \
      --timeout 15m
  fi
  rm -f "$processed_values"

  # Wait for key deployments
  log_step "Waiting for GitLab deployments..."
  local deployments=(gitlab-webservice-default gitlab-sidekiq-all-in-1-v2 gitlab-kas)
  for dep in "${deployments[@]}"; do
    wait_for_deployment gitlab "$dep" 600s || log_warn "Deployment ${dep} not ready yet"
  done

  # Wait for gitlab-shell (may be a deployment or part of the chart)
  wait_for_pods_ready gitlab "app=gitlab-shell" 300 || log_warn "gitlab-shell pods not ready yet"

  end_phase "PHASE 6: INSTALL GITLAB VIA HELM"
}

# =============================================================================
# PHASE 7: VALIDATION
# =============================================================================
phase_7_validation() {
  start_phase "PHASE 7: VALIDATION"

  local errors=0

  # Check TLS certificates
  log_step "Checking TLS certificates..."
  local certs=("gitlab-example-com-tls" "registry-example-com-tls" "kas-example-com-tls" "minio-example-com-tls")
  for cert_name in "${certs[@]}"; do
    # Replace example-com with actual domain-dashed
    local actual_cert="${cert_name//example-com/${DOMAIN_DASHED}}"
    if kubectl get certificate "$actual_cert" -n gitlab &>/dev/null; then
      local ready
      ready=$(kubectl get certificate "$actual_cert" -n gitlab -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
      if [[ "$ready" == "True" ]]; then
        log_ok "Certificate ${actual_cert} is Ready"
      else
        log_warn "Certificate ${actual_cert} not Ready yet (cert-manager may still be issuing)"
      fi
    else
      log_warn "Certificate ${actual_cert} not found (Gateway may need time)"
    fi
  done

  # HTTPS connectivity check
  log_step "Checking HTTPS connectivity..."
  deploy_check_pod
  check_https "gitlab.${DOMAIN}" || errors=$((errors + 1))
  cleanup_check_pod

  # Print credentials summary
  log_step "GitLab deployment summary:"
  echo ""
  echo -e "${BOLD}${GREEN}  GitLab deployed successfully!${NC}"
  echo ""
  echo "  URLs:"
  echo "    GitLab:   https://gitlab.${DOMAIN}"
  echo "    Registry: https://registry.${DOMAIN}"
  echo "    KAS:      https://kas.${DOMAIN}"
  echo "    MinIO:    https://minio.${DOMAIN}"
  echo ""
  echo "  Credentials:"
  echo "    Root user: root / ${GITLAB_ROOT_PASSWORD}"
  echo "    OIDC:      Keycloak SSO (openid_connect)"
  echo ""

  # Append to credentials.txt if it exists
  local creds_file="${CLUSTER_DIR}/credentials.txt"
  if [[ -f "$creds_file" ]]; then
    # Check if GitLab entry already exists
    if ! grep -q "gitlab.${DOMAIN}" "$creds_file" 2>/dev/null; then
      cat >> "$creds_file" <<CREDEOF
GitLab         https://gitlab.${DOMAIN}         root / ${GITLAB_ROOT_PASSWORD}
GitLab Reg     https://registry.${DOMAIN}       (docker login registry.${DOMAIN})
CREDEOF
      log_ok "Credentials appended to ${creds_file}"
    fi
  fi

  if [[ $errors -gt 0 ]]; then
    log_warn "Validation completed with ${errors} warning(s). GitLab may need more time to start."
  else
    log_ok "All validation checks passed!"
  fi

  end_phase "PHASE 7: VALIDATION"
}

# =============================================================================
# MAIN — Execute Phases
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}================================================================${NC}"
echo -e "${BOLD}${CYAN}  GitLab Deployment — RKE2 Cluster${NC}"
echo -e "${BOLD}${CYAN}================================================================${NC}"
echo ""
echo "  Chart path:  ${GITLAB_CHART_PATH}"
echo "  Domain:      ${DOMAIN}"
echo "  Namespace:   gitlab"
echo ""

[[ $FROM_PHASE -le 1 ]] && phase_1_prerequisites
[[ $FROM_PHASE -le 2 ]] && phase_2_postgresql
[[ $FROM_PHASE -le 3 ]] && phase_3_secrets
[[ $FROM_PHASE -le 4 ]] && phase_4_redis
[[ $FROM_PHASE -le 5 ]] && phase_5_gateway
[[ $FROM_PHASE -le 6 ]] && phase_6_helm_install
[[ $FROM_PHASE -le 7 ]] && phase_7_validation

print_total_time

echo ""
echo -e "${BOLD}${GREEN}  GitLab deployment complete!${NC}"
echo ""
