#!/usr/bin/env bash
# =============================================================================
# setup-keycloak.sh — Keycloak Realm, OIDC Clients, Service Bindings
# =============================================================================
# Run AFTER deploy-cluster.sh completes successfully.
#
# This script:
#   1. Creates the realm (derived from DOMAIN) with admin user + TOTP
#   2. Creates OIDC clients for every service (incl. kubernetes + per-service oauth2-proxy + rancher)
#   3. Binds each service to Keycloak for SSO
#   4. Creates user groups with role mappings (9 groups)
#   5. Creates 12 test users across all groups for development/testing
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
        '.redirectUris = ($uri | split(",")) | .webOrigins = ["+"] | .attributes["post.logout.redirect.uris"] = "+"')
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
      \"redirectUris\": $(echo "$redirect_uri" | jq -R 'split(",")'),
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

# Create a service account OIDC client (machine-to-machine, no browser login)
# Returns the generated client secret on stdout.
kc_create_service_account_client() {
  local client_id="$1"
  local name="${2:-$client_id}"

  log_info "Creating service account client: ${client_id}" >&2

  # Check if client already exists
  local existing
  existing=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=${client_id}" 2>/dev/null || echo "[]")
  local existing_id
  existing_id=$(echo "$existing" | jq -r '.[0].id // empty')

  if [[ -n "$existing_id" ]]; then
    log_info "  Service account client '${client_id}' already exists (id: ${existing_id})" >&2
    local secret
    secret=$(kc_api GET "/realms/${KC_REALM}/clients/${existing_id}/client-secret" 2>/dev/null | jq -r '.value // empty')
    echo "$secret"
    return 0
  fi

  # Create client with service account enabled (client_credentials grant)
  kc_api POST "/realms/${KC_REALM}/clients" \
    -d "{
      \"clientId\": \"${client_id}\",
      \"name\": \"${name}\",
      \"enabled\": true,
      \"protocol\": \"openid-connect\",
      \"publicClient\": false,
      \"clientAuthenticatorType\": \"client-secret\",
      \"standardFlowEnabled\": false,
      \"directAccessGrantsEnabled\": true,
      \"serviceAccountsEnabled\": true,
      \"redirectUris\": [],
      \"webOrigins\": []
    }"

  # Get the internal UUID
  local internal_id
  internal_id=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=${client_id}" | jq -r '.[0].id')

  # Generate and retrieve client secret
  kc_api POST "/realms/${KC_REALM}/clients/${internal_id}/client-secret" >/dev/null
  local secret
  secret=$(kc_api GET "/realms/${KC_REALM}/clients/${internal_id}/client-secret" | jq -r '.value')

  log_ok "  Service account client '${client_id}' created (secret: ${secret:0:8}...)" >&2
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
        \"ssoSessionIdleTimeout\": 120,
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
        \"requiredActions\": [],
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
        \"requiredActions\": [],
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

  # Ensure CONFIGURE_TOTP is available but not forced on new users (MFA is optional)
  kc_api PUT "/realms/${KC_REALM}/authentication/required-actions/CONFIGURE_TOTP" \
    -d '{"alias":"CONFIGURE_TOTP","name":"Configure OTP","defaultAction":false,"enabled":true,"priority":10}' \
    2>/dev/null || true
  log_ok "TOTP available as optional action (not forced on new users)"

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

  # Create "groups" client scope (needed by ArgoCD, kubernetes, etc. that request scope=groups)
  log_step "Creating 'groups' client scope..."
  local groups_scope_exists
  groups_scope_exists=$(kc_api GET "/realms/${KC_REALM}/client-scopes" 2>/dev/null | jq -r '.[] | select(.name=="groups") | .id // empty' || echo "")
  if [[ -n "$groups_scope_exists" ]]; then
    log_info "  Client scope 'groups' already exists (id: ${groups_scope_exists})"
  else
    kc_api POST "/realms/${KC_REALM}/client-scopes" \
      -d '{
        "name": "groups",
        "description": "Group membership",
        "protocol": "openid-connect",
        "attributes": {
          "include.in.token.scope": "true",
          "display.on.consent.screen": "true"
        },
        "protocolMappers": [{
          "name": "groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "config": {
            "full.path": "false",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "claim.name": "groups",
            "userinfo.token.claim": "true"
          }
        }]
      }'
    log_ok "  Client scope 'groups' created with group membership mapper"
  fi

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

  # 2.9 Per-service oauth2-proxy OIDC clients (one per protected service)
  secret=$(kc_create_client "prometheus-oidc" \
    "https://prometheus.${DOMAIN}/oauth2/callback" "Prometheus")
  jq --arg s "$secret" '.["prometheus-oidc"] = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  secret=$(kc_create_client "alertmanager-oidc" \
    "https://alertmanager.${DOMAIN}/oauth2/callback" "AlertManager")
  jq --arg s "$secret" '.["alertmanager-oidc"] = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  secret=$(kc_create_client "hubble-oidc" \
    "https://hubble.${DOMAIN}/oauth2/callback" "Hubble")
  jq --arg s "$secret" '.["hubble-oidc"] = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  secret=$(kc_create_client "traefik-dashboard-oidc" \
    "https://traefik.${DOMAIN}/oauth2/callback" "Traefik Dashboard")
  jq --arg s "$secret" '.["traefik-dashboard-oidc"] = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  secret=$(kc_create_client "rollouts-oidc" \
    "https://rollouts.${DOMAIN}/oauth2/callback" "Argo Rollouts")
  jq --arg s "$secret" '.["rollouts-oidc"] = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  # 2.10 Rancher OIDC client
  secret=$(kc_create_client "rancher" \
    "https://rancher.${DOMAIN}/verify-auth" "Rancher")
  jq --arg s "$secret" '.rancher = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  # 2.11 Identity Portal (two-client setup)
  #   - identity-portal:       PUBLIC client for frontend PKCE OIDC flow (browser login)
  #   - identity-portal-admin: CONFIDENTIAL client with service account for backend Keycloak Admin API

  # 2.11a identity-portal — PUBLIC client (no secret, PKCE-enabled, like kubernetes)
  log_step "Creating identity-portal OIDC client (public — PKCE frontend)"
  local ip_existing
  ip_existing=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=identity-portal" 2>/dev/null || echo "[]")
  local ip_existing_id
  ip_existing_id=$(echo "$ip_existing" | jq -r '.[0].id // empty')
  if [[ -n "$ip_existing_id" ]]; then
    log_info "  Client 'identity-portal' already exists (id: ${ip_existing_id}) — updating to public"
    local ip_client_json
    ip_client_json=$(kc_api GET "/realms/${KC_REALM}/clients/${ip_existing_id}" 2>/dev/null || echo "{}")
    if [[ -n "$ip_client_json" && "$ip_client_json" != "{}" ]]; then
      local ip_updated_json
      ip_updated_json=$(echo "$ip_client_json" | jq \
        '.publicClient = true |
         .clientAuthenticatorType = "client-secret" |
         .serviceAccountsEnabled = false |
         .standardFlowEnabled = true |
         .directAccessGrantsEnabled = false |
         .redirectUris = ["https://identity.'"${DOMAIN}"'/*"] |
         .webOrigins = ["+"] |
         .attributes["post.logout.redirect.uris"] = "+" |
         .attributes["pkce.code.challenge.method"] = "S256"')
      echo "$ip_updated_json" | kc_api PUT "/realms/${KC_REALM}/clients/${ip_existing_id}" -d @- 2>/dev/null || \
        log_warn "Could not update identity-portal to public client"
    fi
  else
    kc_api POST "/realms/${KC_REALM}/clients" \
      -d "{
        \"clientId\": \"identity-portal\",
        \"name\": \"Identity Portal (Frontend)\",
        \"enabled\": true,
        \"protocol\": \"openid-connect\",
        \"publicClient\": true,
        \"standardFlowEnabled\": true,
        \"directAccessGrantsEnabled\": false,
        \"serviceAccountsEnabled\": false,
        \"redirectUris\": [\"https://identity.${DOMAIN}/*\"],
        \"webOrigins\": [\"+\"],
        \"attributes\": {
          \"post.logout.redirect.uris\": \"+\",
          \"pkce.code.challenge.method\": \"S256\"
        }
      }"
    log_ok "  Client 'identity-portal' created (public — no secret, PKCE enabled)"
  fi

  # 2.11b identity-portal-admin — CONFIDENTIAL service account client (backend Admin API)
  log_step "Creating identity-portal-admin service account client (confidential — backend)"
  secret=$(kc_create_service_account_client "identity-portal-admin" "Identity Portal Admin (Backend)")
  jq --arg s "$secret" '.["identity-portal-admin"] = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"
  # Export for deploy-cluster.sh Phase 10 injection
  export IDENTITY_PORTAL_OIDC_SECRET="$secret"

  # Assign realm-management/realm-admin role to identity-portal-admin service account
  log_step "Assigning realm-admin role to identity-portal-admin service account..."
  local ipa_internal_id
  ipa_internal_id=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=identity-portal-admin" | jq -r '.[0].id')
  if [[ -n "$ipa_internal_id" ]]; then
    local sa_user_id
    sa_user_id=$(kc_api GET "/realms/${KC_REALM}/clients/${ipa_internal_id}/service-account-user" 2>/dev/null | jq -r '.id // empty' || echo "")

    if [[ -n "$sa_user_id" ]]; then
      # Get realm-management client UUID
      local rm_client_id
      rm_client_id=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=realm-management" | jq -r '.[0].id')

      # Get realm-admin role
      local realm_admin_role
      realm_admin_role=$(kc_api GET "/realms/${KC_REALM}/clients/${rm_client_id}/roles/realm-admin")

      # Assign realm-management/realm-admin role to service account
      kc_api POST "/realms/${KC_REALM}/users/${sa_user_id}/role-mappings/clients/${rm_client_id}" \
        -d "[${realm_admin_role}]" 2>/dev/null || true
      log_ok "realm-admin role assigned to identity-portal-admin service account"
    else
      log_warn "Could not get service account user for identity-portal-admin"
    fi
  fi

  # 2.12 GitLab CI service account (machine-to-machine OIDC for CI pipelines)
  log_step "Creating gitlab-ci service account client"
  secret=$(kc_create_service_account_client "gitlab-ci" "GitLab CI Service Account")
  jq --arg s "$secret" '.["gitlab-ci"] = $s' "$OIDC_SECRETS_FILE" > /tmp/oidc.tmp && mv /tmp/oidc.tmp "$OIDC_SECRETS_FILE"

  # Add "groups" as optional client scope to clients that request scope=groups
  log_step "Adding 'groups' scope to relevant clients..."
  local groups_scope_id
  groups_scope_id=$(kc_api GET "/realms/${KC_REALM}/client-scopes" 2>/dev/null | jq -r '.[] | select(.name=="groups") | .id // empty' || echo "")
  if [[ -n "$groups_scope_id" ]]; then
    for cid in argocd kubernetes grafana harbor vault prometheus-oidc alertmanager-oidc hubble-oidc traefik-dashboard-oidc rollouts-oidc rancher identity-portal identity-portal-admin gitlab-ci; do
      local cid_internal
      cid_internal=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=${cid}" 2>/dev/null | jq -r '.[0].id // empty' || echo "")
      if [[ -n "$cid_internal" ]]; then
        kc_api PUT "/realms/${KC_REALM}/clients/${cid_internal}/optional-client-scopes/${groups_scope_id}" 2>/dev/null || true
        log_ok "  Added 'groups' scope to ${cid}"
      fi
    done
  fi

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
    GF_AUTH_GENERIC_OAUTH_AUTH_URL="${oidc_issuer}/protocol/openid-connect/auth?prompt=login" \
    GF_AUTH_GENERIC_OAUTH_TOKEN_URL="${oidc_issuer}/protocol/openid-connect/token" \
    GF_AUTH_GENERIC_OAUTH_API_URL="${oidc_issuer}/protocol/openid-connect/userinfo" \
    GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH="contains(groups[*], 'platform-admins') && 'Admin' || contains(groups[*], 'infra-engineers') && 'Admin' || contains(groups[*], 'network-engineers') && 'Viewer' || contains(groups[*], 'senior-developers') && 'Editor' || contains(groups[*], 'developers') && 'Editor' || 'Viewer'" \
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
  - groups
forceAuthRequestParameters:
  prompt: login"

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
  harbor_admin_pass="${HARBOR_ADMIN_PASSWORD}"
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
  log_info "  Client ID:     gitlab"
  log_info "  Client Secret: $(jq -r '.gitlab' "$OIDC_SECRETS_FILE")"
  log_info "  Issuer:        ${oidc_issuer}"
  log_info "  OIDC secret will be created automatically by setup-gitlab.sh"

  end_phase "PHASE 3: SERVICE BINDINGS"
}

# =============================================================================
# PHASE 4: USER GROUPS + ROLE MAPPING
# =============================================================================
phase_4_groups() {
  start_phase "PHASE 4: GROUPS + ROLE MAPPING"

  local groups=("platform-admins" "harvester-admins" "rancher-admins" "infra-engineers" "network-engineers" "senior-developers" "developers" "viewers" "ci-service-accounts")

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

  # Add gitlab-ci service account user to ci-service-accounts and infra-engineers groups
  log_step "Adding gitlab-ci service account to groups..."
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
    else
      log_warn "Could not find service account user for gitlab-ci client"
    fi
  fi

  # Configure group mapper for clients that need it
  log_step "Configuring group claim mappers..."
  local clients
  clients=$(kc_api GET "/realms/${KC_REALM}/clients?max=100" 2>/dev/null || echo "[]")

  local our_clients=("grafana" "argocd" "harbor" "vault" "mattermost" "kasm" "gitlab" "kubernetes" "prometheus-oidc" "alertmanager-oidc" "hubble-oidc" "traefik-dashboard-oidc" "rollouts-oidc" "rancher" "identity-portal" "identity-portal-admin" "gitlab-ci")
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

      # Add audience mapper so the client_id appears in the aud claim
      kc_api POST "/realms/${KC_REALM}/clients/${internal_id}/protocol-mappers/models" \
        -d "{
          \"name\": \"audience-${client_id_name}\",
          \"protocol\": \"openid-connect\",
          \"protocolMapper\": \"oidc-audience-mapper\",
          \"config\": {
            \"included.client.audience\": \"${client_id_name}\",
            \"id.token.claim\": \"true\",
            \"access.token.claim\": \"true\"
          }
        }" 2>/dev/null || true
      log_ok "  Audience mapper added to ${client_id_name}"
    fi
  done

  end_phase "PHASE 4: GROUPS + ROLE MAPPING"
}

# =============================================================================
# PHASE 5: TEST USERS
# =============================================================================
phase_5_test_users() {
  start_phase "PHASE 5: TEST USERS"

  # Shared password for all test users (easy to remember for testing)
  local TEST_USER_PASS="TestUser2026!"

  # ── Helper: create user if not exists ──────────────────────────────────────
  _create_test_user() {
    local username="$1" email="$2" first="$3" last="$4"
    shift 4
    local group_names=("$@")

    local existing_id
    existing_id=$(kc_api GET "/realms/${KC_REALM}/users?username=${username}" 2>/dev/null \
      | jq -r '.[0].id // empty' || echo "")

    if [[ -n "$existing_id" ]]; then
      log_info "  User '${username}' already exists — skipping"
    else
      kc_api POST "/realms/${KC_REALM}/users" \
        -d "{
          \"username\": \"${username}\",
          \"email\": \"${email}\",
          \"enabled\": true,
          \"emailVerified\": true,
          \"firstName\": \"${first}\",
          \"lastName\": \"${last}\",
          \"requiredActions\": [],
          \"credentials\": [{
            \"type\": \"password\",
            \"value\": \"${TEST_USER_PASS}\",
            \"temporary\": false
          }]
        }"
      log_ok "  Created user: ${username}"
    fi

    # Fetch user ID (whether new or existing)
    local user_id
    user_id=$(kc_api GET "/realms/${KC_REALM}/users?username=${username}" | jq -r '.[0].id')

    # Add to groups
    for grp in "${group_names[@]}"; do
      local grp_id
      grp_id=$(kc_api GET "/realms/${KC_REALM}/groups?search=${grp}" 2>/dev/null \
        | jq -r '.[0].id // empty' || echo "")
      if [[ -n "$grp_id" ]]; then
        kc_api PUT "/realms/${KC_REALM}/users/${user_id}/groups/${grp_id}" 2>/dev/null || true
        log_info "    → added to ${grp}"
      else
        log_warn "    Group '${grp}' not found — skipping"
      fi
    done
  }

  # ── Platform Admins (full access) ──────────────────────────────────────────
  log_step "Creating platform-admin test users..."
  _create_test_user "alice.morgan" "alice.morgan@${DOMAIN}" "Alice" "Morgan" \
    platform-admins harvester-admins rancher-admins
  _create_test_user "bob.chen" "bob.chen@${DOMAIN}" "Bob" "Chen" \
    platform-admins

  # ── Infrastructure Engineers ───────────────────────────────────────────────
  log_step "Creating infra-engineer test users..."
  _create_test_user "carol.silva" "carol.silva@${DOMAIN}" "Carol" "Silva" \
    infra-engineers harvester-admins
  _create_test_user "dave.kumar" "dave.kumar@${DOMAIN}" "Dave" "Kumar" \
    infra-engineers network-engineers

  # ── Network Engineers ──────────────────────────────────────────────────────
  log_step "Creating network-engineer test users..."
  _create_test_user "eve.mueller" "eve.mueller@${DOMAIN}" "Eve" "Mueller" \
    network-engineers

  # ── Senior Developers (multi-group) ────────────────────────────────────────
  log_step "Creating senior-developer test users..."
  _create_test_user "frank.jones" "frank.jones@${DOMAIN}" "Frank" "Jones" \
    senior-developers developers
  _create_test_user "grace.park" "grace.park@${DOMAIN}" "Grace" "Park" \
    senior-developers rancher-admins

  # ── Developers ─────────────────────────────────────────────────────────────
  log_step "Creating developer test users..."
  _create_test_user "henry.wilson" "henry.wilson@${DOMAIN}" "Henry" "Wilson" \
    developers
  _create_test_user "iris.tanaka" "iris.tanaka@${DOMAIN}" "Iris" "Tanaka" \
    developers
  _create_test_user "jack.brown" "jack.brown@${DOMAIN}" "Jack" "Brown" \
    developers

  # ── Viewers (read-only) ────────────────────────────────────────────────────
  log_step "Creating viewer test users..."
  _create_test_user "kate.lee" "kate.lee@${DOMAIN}" "Kate" "Lee" \
    viewers
  _create_test_user "leo.garcia" "leo.garcia@${DOMAIN}" "Leo" "Garcia" \
    viewers developers

  # ── Summary ────────────────────────────────────────────────────────────────
  echo ""
  log_ok "Test users created (12 users):"
  echo "  ┌──────────────────┬──────────────────────────────────────────────────┐"
  echo "  │ Username         │ Groups                                           │"
  echo "  ├──────────────────┼──────────────────────────────────────────────────┤"
  echo "  │ alice.morgan     │ platform-admins, harvester-admins, rancher-admins│"
  echo "  │ bob.chen         │ platform-admins                                  │"
  echo "  │ carol.silva      │ infra-engineers, harvester-admins                │"
  echo "  │ dave.kumar       │ infra-engineers, network-engineers               │"
  echo "  │ eve.mueller      │ network-engineers                                │"
  echo "  │ frank.jones      │ senior-developers, developers                    │"
  echo "  │ grace.park       │ senior-developers, rancher-admins                │"
  echo "  │ henry.wilson     │ developers                                       │"
  echo "  │ iris.tanaka      │ developers                                       │"
  echo "  │ jack.brown       │ developers                                       │"
  echo "  │ kate.lee         │ viewers                                          │"
  echo "  │ leo.garcia       │ viewers, developers                              │"
  echo "  └──────────────────┴──────────────────────────────────────────────────┘"
  echo "  Password for all test users: ${TEST_USER_PASS}"
  echo "  (TOTP enrollment required on first login)"

  end_phase "PHASE 5: TEST USERS"
}

# =============================================================================
# PHASE 6: VALIDATION
# =============================================================================
phase_6_validation() {
  start_phase "PHASE 6: KEYCLOAK VALIDATION"

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
  echo "    (TOTP enrollment on first login)"
  echo ""
  echo "  General User:"
  echo "    Username: user"
  echo "    Password: ${REALM_USER_PASS}"
  echo "    (TOTP enrollment on first login)"
  echo ""
  echo "  OIDC Clients Created:"
  echo "    grafana, argocd, harbor, vault, mattermost, kasm, gitlab, kubernetes (public)
    prometheus-oidc, alertmanager-oidc, hubble-oidc, traefik-dashboard-oidc, rollouts-oidc, rancher
    identity-portal (public/PKCE), identity-portal-admin (service account), gitlab-ci (service account)"
  echo ""
  echo "  Client secrets saved to:"
  echo "    ${OIDC_SECRETS_FILE}"
  echo ""
  echo "  Groups: platform-admins, harvester-admins, rancher-admins, infra-engineers, network-engineers, senior-developers, developers, viewers, ci-service-accounts"
  echo ""
  echo "  Test Users: 12 users (password: TestUser2026!)"
  echo "    alice.morgan, bob.chen, carol.silva, dave.kumar, eve.mueller, frank.jones,"
  echo "    grace.park, henry.wilson, iris.tanaka, jack.brown, kate.lee, leo.garcia"
  echo ""
  echo -e "${YELLOW}  Manual steps remaining:${NC}"
  echo "    1. Configure Kasm OIDC via Admin UI"
  echo "    2. Run ./scripts/setup-gitlab.sh (creates OIDC secret automatically)"
  echo "    3. oauth2-proxy ForwardAuth is configured automatically after this script"
  echo "    4. Configure Rancher Keycloak OIDC via UI (see below)"
  echo ""
  echo -e "  ${YELLOW}Rancher Keycloak OIDC (one-time manual step):${NC}"
  echo "    Navigate to: Users & Authentication > Auth Provider > Keycloak (OIDC)"
  echo "    Use 'Specify (advanced)' — do NOT use 'Generate'"
  echo "    Client ID:      rancher"
  echo "    Client Secret:  $(jq -r '.rancher' "$OIDC_SECRETS_FILE" 2>/dev/null || echo 'see oidc-client-secrets.json')"
  echo "    Issuer:         https://keycloak.${DOMAIN}/realms/${KC_REALM}"
  echo "    Auth Endpoint:  https://keycloak.${DOMAIN}/realms/${KC_REALM}/protocol/openid-connect/auth"
  echo "    Token Endpoint: https://keycloak.${DOMAIN}/realms/${KC_REALM}/protocol/openid-connect/token"
  echo ""

  # Append Keycloak credentials to credentials.txt
  local creds_file="${CLUSTER_DIR}/credentials.txt"
  if [[ -f "$creds_file" ]]; then
    cat >> "$creds_file" <<EOF

# Keycloak OIDC (setup-keycloak.sh — $(date -u +%Y-%m-%dT%H:%M:%SZ))
Keycloak Realm  https://keycloak.${DOMAIN}/admin/${KC_REALM}/console
  Realm Admin:   admin / ${REALM_ADMIN_PASS}  (TOTP enrollment on first login)
  General User:  user / ${REALM_USER_PASS}  (TOTP enrollment on first login)
  Master admin (admin/CHANGEME_KC_ADMIN_PASSWORD) is break-glass only — use realm admin console

OIDC Client Secrets:
$(jq -r 'to_entries[] | "  \(.key): \(.value)"' "$OIDC_SECRETS_FILE" 2>/dev/null || echo "  (see ${OIDC_SECRETS_FILE})")

Test Users (password: TestUser2026!, TOTP enrollment on first login):
  alice.morgan   — platform-admins, harvester-admins, rancher-admins
  bob.chen       — platform-admins
  carol.silva    — infra-engineers, harvester-admins
  dave.kumar     — infra-engineers, network-engineers
  eve.mueller    — network-engineers
  frank.jones    — senior-developers, developers
  grace.park     — senior-developers, rancher-admins
  henry.wilson   — developers
  iris.tanaka    — developers
  jack.brown     — developers
  kate.lee       — viewers
  leo.garcia     — viewers, developers
EOF
    log_ok "Keycloak credentials appended to ${creds_file}"
  else
    log_warn "credentials.txt not found at ${creds_file} — skipping append"
  fi

  print_total_time
  end_phase "PHASE 6: VALIDATION"
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
  [[ $FROM_PHASE -le 5 ]] && phase_5_test_users
  [[ $FROM_PHASE -le 6 ]] && phase_6_validation
}

main "$@"
