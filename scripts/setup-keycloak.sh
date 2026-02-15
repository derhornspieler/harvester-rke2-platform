#!/usr/bin/env bash
# =============================================================================
# setup-keycloak.sh — Keycloak Realm, OIDC Clients, Service Bindings
# =============================================================================
# Run AFTER deploy-cluster.sh completes successfully.
#
# This script:
#   1. Creates the realm (derived from DOMAIN) with admin user + TOTP
#   2. Creates OIDC clients for every service (incl. kubernetes + oauth2-proxy)
#   3. Binds each service to Keycloak for SSO
#   4. Creates user groups with role mappings (7 groups)
#
# Prerequisites:
#   - Keycloak running (keycloak.<DOMAIN>)
#   - All services deployed and accessible
#   - KUBECONFIG set to RKE2 cluster
#
# Usage:
#   export KUBECONFIG=/path/to/kubeconfig-rke2.yaml
#   ./scripts/setup-keycloak.sh
#   ./scripts/setup-keycloak.sh --from 2   # Resume from phase 2
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
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Load domain configuration from .env (if available)
generate_or_load_env

# Output file for generated client secrets
OIDC_SECRETS_FILE="${SCRIPTS_DIR}/oidc-client-secrets.json"

# Keycloak connection details
KC_URL="https://keycloak.${DOMAIN}"
: "${KC_REALM:=${DOMAIN%%.*}}"
KC_PORT_FORWARD_PID=""

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

# Cleanup port-forward on exit
_kc_cleanup() {
  if [[ -n "$KC_PORT_FORWARD_PID" ]]; then
    kill "$KC_PORT_FORWARD_PID" 2>/dev/null || true
  fi
}
trap _kc_cleanup EXIT

# Generated passwords for realm users
REALM_ADMIN_PASS=$(openssl rand -base64 24)
REALM_USER_PASS=$(openssl rand -base64 24)

# -----------------------------------------------------------------------------
# Keycloak CLI Helpers
# -----------------------------------------------------------------------------

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

# Create an OIDC client and return the generated secret
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
    # Fetch full client representation, patch redirectUris, PUT back
    local client_json
    client_json=$(kc_api GET "/realms/${KC_REALM}/clients/${existing_id}" 2>/dev/null || echo "{}")
    if [[ -n "$client_json" && "$client_json" != "{}" ]]; then
      local updated_json
      updated_json=$(echo "$client_json" | jq \
        --arg uri "$redirect_uri" \
        '.redirectUris = [$uri] | .webOrigins = ["+"] | .attributes["post.logout.redirect.uris"] = "+"')
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
      \"redirectUris\": [\"${redirect_uri}\"],
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

# =============================================================================
# PHASE 1: REALM + ADMIN SETUP
# =============================================================================
phase_1_realm() {
  start_phase "PHASE 1: REALM + ADMIN SETUP"

  # Verify Keycloak is accessible (auto-fallback to port-forward if needed)
  log_step "Verifying Keycloak connectivity..."
  _kc_ensure_connectivity
  local retries=0
  while ! kc_get_token &>/dev/null && [[ $retries -lt 10 ]]; do
    sleep 5
    retries=$((retries + 1))
  done
  [[ $retries -lt 10 ]] || die "Cannot authenticate to Keycloak at ${KC_URL}"
  log_ok "Keycloak authenticated via bootstrap client credentials"

  # Create realm
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
        \"ssoSessionIdleTimeout\": 1800,
        \"ssoSessionMaxLifespan\": 36000
      }"
    log_ok "Realm '${KC_REALM}' created"
  fi

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

    # Get realm-management client UUID
    local rm_client_id
    rm_client_id=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=realm-management" | jq -r '.[0].id')

    # Get realm-admin role
    local realm_admin_role
    realm_admin_role=$(kc_api GET "/realms/${KC_REALM}/clients/${rm_client_id}/roles/realm-admin")

    # Assign role
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
        \"credentials\": [{
          \"type\": \"password\",
          \"value\": \"${REALM_USER_PASS}\",
          \"temporary\": false
        }]
      }"
    log_ok "General user created"
  fi

  # Enable TOTP as required action
  log_step "Enabling TOTP 2FA..."
  kc_api PUT "/realms/${KC_REALM}" \
    -d "{
      \"realm\": \"${KC_REALM}\",
      \"otpPolicyType\": \"totp\",
      \"otpPolicyAlgorithm\": \"HmacSHA1\",
      \"otpPolicyDigits\": 6,
      \"otpPolicyPeriod\": 30
    }" 2>/dev/null || true
  log_ok "TOTP policy configured"

  echo ""
  log_ok "Realm credentials:"
  echo "  URL:      ${KC_URL}/realms/${KC_REALM}/account"
  echo ""
  echo "  Admin User:"
  echo "    Username: admin"
  echo "    Password: ${REALM_ADMIN_PASS}"
  echo ""
  echo "  General User:"
  echo "    Username: user"
  echo "    Password: ${REALM_USER_PASS}"
  echo ""

  end_phase "PHASE 1: REALM + USERS"
}

# =============================================================================
# PHASE 2: OIDC CLIENT CREATION
# =============================================================================
phase_2_clients() {
  start_phase "PHASE 2: OIDC CLIENT CREATION"

  # Initialize secrets JSON
  echo "{}" > "$OIDC_SECRETS_FILE"

  local secret

  # 2.1 Grafana
  secret=$(kc_create_client "grafana" "https://grafana.${DOMAIN}/*" "Grafana")
  jq --arg s "$secret" '.grafana = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  # 2.2 ArgoCD
  secret=$(kc_create_client "argocd" "https://argo.${DOMAIN}/auth/callback" "ArgoCD")
  jq --arg s "$secret" '.argocd = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  # 2.3 Harbor
  secret=$(kc_create_client "harbor" "https://harbor.${DOMAIN}/c/oidc/callback" "Harbor Registry")
  jq --arg s "$secret" '.harbor = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  # 2.4 Vault
  secret=$(kc_create_client "vault" "https://vault.${DOMAIN}/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" "Vault")
  jq --arg s "$secret" '.vault = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  # 2.5 Mattermost
  secret=$(kc_create_client "mattermost" "https://mattermost.${DOMAIN}/signup/openid/complete" "Mattermost")
  jq --arg s "$secret" '.mattermost = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  # 2.6 Kasm
  secret=$(kc_create_client "kasm" "https://kasm.${DOMAIN}/api/oidc_callback" "Kasm Workspaces")
  jq --arg s "$secret" '.kasm = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  # 2.7 GitLab
  secret=$(kc_create_client "gitlab" "https://gitlab.${DOMAIN}/users/auth/openid_connect/callback" "GitLab")
  jq --arg s "$secret" '.gitlab = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  # 2.8 Kubernetes (public client for kubelogin — no secret)
  log_info "Creating OIDC client: kubernetes (public)"
  local k8s_existing
  k8s_existing=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=kubernetes" 2>/dev/null || echo "[]")
  local k8s_existing_id
  k8s_existing_id=$(echo "$k8s_existing" | jq -r '.[0].id // empty')
  if [[ -n "$k8s_existing_id" ]]; then
    log_info "  Client 'kubernetes' already exists (id: ${k8s_existing_id})"
  else
    kc_api POST "/realms/${KC_REALM}/clients" \
      -d "{
        \"clientId\": \"kubernetes\",
        \"name\": \"Kubernetes (kubelogin)\",
        \"enabled\": true,
        \"protocol\": \"openid-connect\",
        \"publicClient\": true,
        \"standardFlowEnabled\": true,
        \"directAccessGrantsEnabled\": false,
        \"redirectUris\": [\"http://localhost:8000\", \"http://localhost:18000\"],
        \"webOrigins\": [\"+\"],
        \"attributes\": {
          \"post.logout.redirect.uris\": \"+\"
        }
      }"
    log_ok "  Client 'kubernetes' created (public — no secret)"
  fi

  # 2.9 OAuth2 Proxy (confidential — for ForwardAuth)
  secret=$(kc_create_client "oauth2-proxy" "https://auth.${DOMAIN}/oauth2/callback" "OAuth2 Proxy")
  jq --arg s "$secret" '.["oauth2-proxy"] = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  log_ok "All OIDC clients created. Secrets saved to: ${OIDC_SECRETS_FILE}"

  end_phase "PHASE 2: OIDC CLIENTS"
}

# =============================================================================
# PHASE 3: BIND SERVICES TO KEYCLOAK
# =============================================================================
phase_3_bindings() {
  start_phase "PHASE 3: SERVICE BINDINGS"

  # Always use the external FQDN for OIDC issuer — services (Vault, Grafana, etc.)
  # need to reach Keycloak via the real URL, not the port-forward used for API calls.
  local oidc_issuer="https://keycloak.${DOMAIN}/realms/${KC_REALM}"

  # 3.1 Grafana
  log_step "Binding Grafana to Keycloak..."
  local grafana_secret
  grafana_secret=$(jq -r '.grafana' "$OIDC_SECRETS_FILE")

  # Patch the Grafana deployment with OIDC env vars
  kubectl -n monitoring set env deployment/grafana \
    GF_AUTH_GENERIC_OAUTH_ENABLED="true" \
    GF_AUTH_GENERIC_OAUTH_NAME="Keycloak" \
    GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP="true" \
    GF_AUTH_GENERIC_OAUTH_CLIENT_ID="grafana" \
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="${grafana_secret}" \
    GF_AUTH_GENERIC_OAUTH_SCOPES="openid profile email" \
    GF_AUTH_GENERIC_OAUTH_AUTH_URL="${oidc_issuer}/protocol/openid-connect/auth" \
    GF_AUTH_GENERIC_OAUTH_TOKEN_URL="${oidc_issuer}/protocol/openid-connect/token" \
    GF_AUTH_GENERIC_OAUTH_API_URL="${oidc_issuer}/protocol/openid-connect/userinfo" \
    GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH="contains(groups[*], 'platform-admins') && 'Admin' || contains(groups[*], 'infra-engineers') && 'Admin' || contains(groups[*], 'senior-developers') && 'Editor' || contains(groups[*], 'developers') && 'Editor' || 'Viewer'" \
    GF_AUTH_SIGNOUT_REDIRECT_URL="${oidc_issuer}/protocol/openid-connect/logout?post_logout_redirect_uri=https%3A%2F%2Fgrafana.${DOMAIN}%2Flogin" \
    GF_AUTH_GENERIC_OAUTH_TLS_CLIENT_CA="/etc/ssl/certs/vault-root-ca.pem" \
    2>/dev/null || log_warn "Grafana OIDC binding may need manual configuration"
  log_ok "Grafana OIDC configured"

  # 3.2 ArgoCD
  log_step "Binding ArgoCD to Keycloak..."
  local argocd_secret
  argocd_secret=$(jq -r '.argocd' "$OIDC_SECRETS_FILE")

  # Extract Root CA for ArgoCD OIDC config
  local argocd_root_ca
  argocd_root_ca=$(extract_root_ca)

  # Build OIDC config YAML, then JSON-encode it safely with jq
  local oidc_yaml
  oidc_yaml="name: Keycloak
issuer: ${oidc_issuer}
clientID: argocd
clientSecret: \"${argocd_secret}\"
requestedScopes:
  - openid
  - profile
  - email
  - groups"

  # Append rootCA if available (ArgoCD natively supports inline CA PEM)
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

  # Patch argocd-rbac-cm with group mappings
  kubectl -n argocd patch configmap argocd-rbac-cm --type merge -p "{
    \"data\": {
      \"policy.csv\": \"g, platform-admins, role:admin\ng, developers, role:readonly\np, role:developer, applications, sync, */*, allow\np, role:developer, applications, get, */*, allow\ng, developers, role:developer\n\",
      \"policy.default\": \"role:readonly\"
    }
  }" 2>/dev/null || true

  kubectl -n argocd rollout restart deployment/argocd-server 2>/dev/null || true
  log_ok "ArgoCD OIDC configured"

  # 3.3 Harbor (via API)
  log_step "Binding Harbor to Keycloak..."
  local harbor_secret harbor_admin_pass harbor_core_pod
  harbor_secret=$(jq -r '.harbor' "$OIDC_SECRETS_FILE")
  harbor_admin_pass=$(grep 'harborAdminPassword' "${SERVICES_DIR}/harbor/harbor-values.yaml" | awk -F'"' '{print $2}')
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

    # Mount Root CA in harbor-core for OIDC TLS verification
    kubectl -n harbor set env deployment/harbor-core \
      SSL_CERT_FILE="/etc/ssl/certs/vault-root-ca.pem" 2>/dev/null || true

    # Add volume + volumeMount for vault-root-ca ConfigMap
    kubectl -n harbor patch deployment harbor-core --type=json -p '[
      {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "vault-root-ca", "configMap": {"name": "vault-root-ca"}}},
      {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {"name": "vault-root-ca", "mountPath": "/etc/ssl/certs/vault-root-ca.pem", "subPath": "ca.crt", "readOnly": true}}
    ]' 2>/dev/null || log_warn "Could not patch harbor-core with Root CA volume (may already exist)"

    log_ok "Harbor OIDC configured"
  else
    log_warn "Harbor core pod not found, configure OIDC manually"
  fi

  # 3.4 Vault
  log_step "Binding Vault to Keycloak..."
  local vault_secret vault_init_file root_token
  vault_secret=$(jq -r '.vault' "$OIDC_SECRETS_FILE")
  vault_init_file="${CLUSTER_DIR}/vault-init.json"

  if [[ -f "$vault_init_file" ]]; then
    root_token=$(jq -r '.root_token' "$vault_init_file")

    vault_exec "$root_token" auth enable oidc 2>/dev/null || log_info "OIDC auth already enabled"

    # Extract Root CA PEM so Vault trusts our private PKI certs on Keycloak
    local root_ca_pem
    root_ca_pem=$(extract_root_ca)
    if [[ -n "$root_ca_pem" ]]; then
      # Write CA to temp file and copy into Vault pod (avoids newline issues in args)
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

    # Vault CLI treats duplicate keys as overwrite — write via JSON for array values
    kubectl exec -n vault vault-0 -- env \
      VAULT_ADDR=http://127.0.0.1:8200 \
      VAULT_TOKEN="$root_token" \
      VAULT_DOMAIN="${DOMAIN}" \
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
  else
    log_warn "vault-init.json not found, configure Vault OIDC manually"
  fi

  # 3.5 Mattermost
  log_step "Binding Mattermost to Keycloak..."
  local mm_secret
  mm_secret=$(jq -r '.mattermost' "$OIDC_SECRETS_FILE")

  kubectl -n mattermost set env deployment/mattermost \
    MM_OPENIDSETTINGS_ENABLE="true" \
    MM_OPENIDSETTINGS_SECRET="${mm_secret}" \
    MM_OPENIDSETTINGS_ID="mattermost" \
    MM_OPENIDSETTINGS_DISCOVERYENDPOINT="${oidc_issuer}/.well-known/openid-configuration" \
    SSL_CERT_FILE="/etc/ssl/certs/vault-root-ca.pem" \
    2>/dev/null || log_warn "Mattermost OIDC binding may need manual configuration"

  # Mount Root CA in Mattermost for OIDC TLS verification (Go respects SSL_CERT_FILE)
  kubectl -n mattermost patch deployment mattermost --type=json -p '[
    {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "vault-root-ca", "configMap": {"name": "vault-root-ca"}}},
    {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {"name": "vault-root-ca", "mountPath": "/etc/ssl/certs/vault-root-ca.pem", "subPath": "ca.crt", "readOnly": true}}
  ]' 2>/dev/null || log_warn "Could not patch mattermost with Root CA volume (may already exist)"

  log_ok "Mattermost OIDC configured"

  # 3.6 Kasm — must be configured via Admin UI API
  log_step "Kasm OIDC..."
  log_warn "Kasm OIDC must be configured via Admin UI > Authentication > OpenID"
  log_info "  Client ID:     kasm"
  log_info "  Client Secret: $(jq -r '.kasm' "$OIDC_SECRETS_FILE")"
  log_info "  Discovery URL: ${oidc_issuer}/.well-known/openid-configuration"

  # 3.7 GitLab
  log_step "GitLab OIDC..."
  log_warn "GitLab OIDC must be configured in GitLab Helm values or omnibus.rb:"
  log_info "  Client ID:     gitlab"
  log_info "  Client Secret: $(jq -r '.gitlab' "$OIDC_SECRETS_FILE")"
  log_info "  Issuer:        ${oidc_issuer}"

  end_phase "PHASE 3: SERVICE BINDINGS"
}

# =============================================================================
# PHASE 4: USER GROUPS + ROLE MAPPING
# =============================================================================
phase_4_groups() {
  start_phase "PHASE 4: GROUPS + ROLE MAPPING"

  local groups=("platform-admins" "harvester-admins" "rancher-admins" "infra-engineers" "senior-developers" "developers" "viewers")

  for group in "${groups[@]}"; do
    log_step "Creating group: ${group}"
    local existing
    existing=$(kc_api GET "/realms/${KC_REALM}/groups?search=${group}" 2>/dev/null | jq -r '.[0].name // empty' || echo "")

    if [[ "$existing" == "$group" ]]; then
      log_info "  Group '${group}' already exists"
    else
      kc_api POST "/realms/${KC_REALM}/groups" \
        -d "{\"name\": \"${group}\"}"
      log_ok "  Group '${group}' created"
    fi
  done

  # Add realm admin to platform-admins group
  log_step "Adding admin user to platform-admins group..."
  local admin_id group_id
  admin_id=$(kc_api GET "/realms/${KC_REALM}/users?username=admin" | jq -r '.[0].id')
  group_id=$(kc_api GET "/realms/${KC_REALM}/groups?search=platform-admins" | jq -r '.[0].id')

  if [[ -n "$admin_id" && -n "$group_id" ]]; then
    kc_api PUT "/realms/${KC_REALM}/users/${admin_id}/groups/${group_id}" 2>/dev/null || true
    log_ok "Admin user added to platform-admins"
  fi

  # Add general user to developers group
  log_step "Adding general user to developers group..."
  local user_id dev_group_id
  user_id=$(kc_api GET "/realms/${KC_REALM}/users?username=user" 2>/dev/null | jq -r '.[0].id // empty' || echo "")
  dev_group_id=$(kc_api GET "/realms/${KC_REALM}/groups?search=developers" 2>/dev/null | jq -r '.[0].id // empty' || echo "")

  if [[ -n "$user_id" && -n "$dev_group_id" ]]; then
    kc_api PUT "/realms/${KC_REALM}/users/${user_id}/groups/${dev_group_id}" 2>/dev/null || true
    log_ok "General user added to developers"
  fi

  # Configure group mapper for clients that need it
  log_step "Configuring group claim mappers..."
  local clients
  clients=$(kc_api GET "/realms/${KC_REALM}/clients?max=100" 2>/dev/null || echo "[]")

  local our_clients=("grafana" "argocd" "harbor" "vault" "mattermost" "kasm" "gitlab" "kubernetes" "oauth2-proxy")
  for client_id_name in "${our_clients[@]}"; do
    local internal_id
    internal_id=$(echo "$clients" | jq -r ".[] | select(.clientId==\"${client_id_name}\") | .id" 2>/dev/null || echo "")

    if [[ -n "$internal_id" ]]; then
      # Add group membership mapper
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
      log_ok "  Group mapper added to ${client_id_name}"
    fi
  done

  end_phase "PHASE 4: GROUPS + ROLE MAPPING"
}

# =============================================================================
# PHASE 5: VALIDATION
# =============================================================================
phase_5_validation() {
  start_phase "PHASE 5: KEYCLOAK VALIDATION"

  echo ""
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}  KEYCLOAK SETUP SUMMARY${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo ""
  echo "  Realm:     ${KC_REALM}"
  echo "  Admin URL: ${KC_URL}/admin/${KC_REALM}/console"
  echo "  Account:   ${KC_URL}/realms/${KC_REALM}/account"
  echo ""
  echo "  Realm Admin:"
  echo "    Username: admin"
  echo "    Password: ${REALM_ADMIN_PASS}"
  echo "    (TOTP will be required on first login)"
  echo ""
  echo "  General User:"
  echo "    Username: user"
  echo "    Password: ${REALM_USER_PASS}"
  echo "    (TOTP will be required on first login)"
  echo ""
  echo "  OIDC Clients Created:"
  echo "    grafana, argocd, harbor, vault, mattermost, kasm, gitlab, kubernetes (public), oauth2-proxy"
  echo ""
  echo "  Client secrets saved to:"
  echo "    ${OIDC_SECRETS_FILE}"
  echo ""
  echo "  Groups: platform-admins, harvester-admins, rancher-admins, infra-engineers, senior-developers, developers, viewers"
  echo ""
  echo -e "${YELLOW}  Manual steps remaining:${NC}"
  echo "    1. Configure Kasm OIDC via Admin UI"
  echo "    2. Configure GitLab OIDC in Helm values / omnibus.rb"
  echo "    3. ForwardAuth (oauth2-proxy) is deployed automatically after this script"
  echo ""

  # Append Keycloak credentials to credentials.txt
  local creds_file="${CLUSTER_DIR}/credentials.txt"
  if [[ -f "$creds_file" ]]; then
    cat >> "$creds_file" <<EOF

# Keycloak OIDC (setup-keycloak.sh — $(date -u +%Y-%m-%dT%H:%M:%SZ))
Keycloak Realm  https://keycloak.${DOMAIN}/admin/${KC_REALM}/console
  Realm Admin:   admin / ${REALM_ADMIN_PASS}  (TOTP required on first login)
  General User:  user / ${REALM_USER_PASS}  (TOTP required on first login)

OIDC Client Secrets:
$(jq -r 'to_entries[] | "  \(.key): \(.value)"' "$OIDC_SECRETS_FILE" 2>/dev/null || echo "  (see ${OIDC_SECRETS_FILE})")
EOF
    log_ok "Keycloak credentials appended to ${creds_file}"
  else
    log_warn "credentials.txt not found at ${creds_file} — skipping append"
  fi

  print_total_time
  end_phase "PHASE 5: VALIDATION"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo -e "${BOLD}${BLUE}"
  echo "  Keycloak Setup — OIDC + Service Bindings"
  echo -e "${NC}"

  DEPLOY_START_TIME=$(date +%s)
  export DEPLOY_START_TIME

  check_prerequisites

  [[ $FROM_PHASE -le 1 ]] && phase_1_realm
  [[ $FROM_PHASE -le 2 ]] && phase_2_clients
  [[ $FROM_PHASE -le 3 ]] && phase_3_bindings
  [[ $FROM_PHASE -le 4 ]] && phase_4_groups
  [[ $FROM_PHASE -le 5 ]] && phase_5_validation
}

main "$@"
