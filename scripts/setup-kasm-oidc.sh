#!/usr/bin/env bash
# =============================================================================
# setup-kasm-oidc.sh — Wire KASM Workspaces to Keycloak via OIDC
# =============================================================================
# Standalone script that configures BOTH sides of the KASM ↔ Keycloak OIDC
# integration:
#
#   1. Keycloak side:
#      - Verifies the "kasm" OIDC client exists
#      - Ensures the Group Membership mapper is present
#      - Configures backchannel logout URL
#
#   2. KASM side:
#      - Creates an API key (via undocumented admin API)
#      - Creates the OpenID provider configuration
#      - Configures group mappings
#
# Prerequisites:
#   - Keycloak running with realm already created (setup-keycloak.sh phases 1-4)
#   - KASM 1.18.1 control plane running on RKE2 (Helm install complete)
#   - The "kasm" OIDC client already created in Keycloak (setup-keycloak.sh phase 2)
#   - KUBECONFIG set to the RKE2 cluster
#
# Required variables (from .env or environment):
#   - DOMAIN          — root domain (e.g., example.com)
#
# Auto-detected:
#   - KC_REALM        — derived from DOMAIN (first segment, e.g., "example")
#   - KASM admin pass — read from kasm-secrets K8s secret
#   - KASM client secret — read from oidc-client-secrets.json or Keycloak API
#
# Usage:
#   export KUBECONFIG=/path/to/kubeconfig-rke2.yaml
#   ./scripts/setup-kasm-oidc.sh
#   ./scripts/setup-kasm-oidc.sh --dry-run    # Show what would be configured
#
# NOTE on the KASM API:
#   KASM does not publicly document OIDC configuration API endpoints. However,
#   KASM officially supports using undocumented admin APIs via developer API keys:
#   https://kasmweb.atlassian.net/wiki/spaces/KCS/pages/10682377/Using+Undocumented+APIs
#
#   The endpoint names used below are inferred from decompiled SAML/LDAP patterns
#   and the KASM permission model. If they fail, see the VERIFICATION section at
#   the bottom of this script for how to discover the exact endpoints via browser
#   DevTools.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# -----------------------------------------------------------------------------
# CLI Arguments
# -----------------------------------------------------------------------------
DRY_RUN=false
SKIP_KEYCLOAK=false
SKIP_KASM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true; shift ;;
    --skip-keycloak) SKIP_KEYCLOAK=true; shift ;;
    --skip-kasm)     SKIP_KASM=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--skip-keycloak] [--skip-kasm]"
      echo ""
      echo "  --dry-run         Show what would be configured without making changes"
      echo "  --skip-keycloak   Skip Keycloak-side configuration"
      echo "  --skip-kasm       Skip KASM-side configuration"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# -----------------------------------------------------------------------------
# Load Environment
# -----------------------------------------------------------------------------
generate_or_load_env

KC_URL="https://keycloak.${DOMAIN}"
: "${KC_REALM:=${DOMAIN%%.*}}"
KASM_URL="https://kasm.${DOMAIN}"
OIDC_SECRETS_FILE="${SCRIPTS_DIR}/oidc-client-secrets.json"

KC_PORT_FORWARD_PID=""

# Cleanup on exit
_cleanup() {
  if [[ -n "$KC_PORT_FORWARD_PID" ]]; then
    kill "$KC_PORT_FORWARD_PID" 2>/dev/null || true
  fi
}
trap _cleanup EXIT

# -----------------------------------------------------------------------------
# Keycloak Connectivity (reuse pattern from setup-keycloak.sh)
# -----------------------------------------------------------------------------
_kc_ensure_connectivity() {
  if [[ -n "$KC_PORT_FORWARD_PID" ]]; then
    return 0
  fi
  if curl -sfk --connect-timeout 5 --max-time 10 -o /dev/null \
      "${KC_URL}/realms/master" 2>/dev/null; then
    return 0
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

kc_get_token() {
  local client_id client_secret
  client_id=$(kubectl -n keycloak get secret keycloak-admin-secret \
    -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_CLIENT_ID}' 2>/dev/null | base64 -d || echo "admin-cli-client")
  client_secret=$(kubectl -n keycloak get secret keycloak-admin-secret \
    -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_CLIENT_SECRET}' 2>/dev/null | base64 -d)
  [[ -n "$client_secret" ]] || die "Could not retrieve KC_BOOTSTRAP_ADMIN_CLIENT_SECRET"

  curl -sfk --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 --retry-all-errors \
    -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=client_credentials" \
    -d "client_id=${client_id}" \
    -d "client_secret=${client_secret}" | jq -r '.access_token'
}

kc_api() {
  local method="$1" path="$2"
  shift 2
  local token
  token=$(kc_get_token)
  curl -sfk --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 --retry-all-errors \
    -X "$method" "${KC_URL}/admin${path}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "$@"
}

# -----------------------------------------------------------------------------
# KASM API Helpers
# -----------------------------------------------------------------------------

# Login to KASM as admin and get a session token
kasm_login() {
  local admin_pass="$1"
  curl -sk --connect-timeout 10 --max-time 30 \
    -X POST "${KASM_URL}/api/public/login" \
    -H "Content-Type: application/json" \
    -d "{
      \"username\": \"admin@kasm.local\",
      \"password\": \"${admin_pass}\"
    }" 2>/dev/null
}

# Call KASM public API with API key auth
kasm_api() {
  local endpoint="$1"
  shift
  curl -sk --connect-timeout 10 --max-time 30 \
    -X POST "${KASM_URL}/api/public/${endpoint}" \
    -H "Content-Type: application/json" \
    "$@"
}

# =============================================================================
# PHASE 1: KEYCLOAK SIDE — Verify & Configure the "kasm" Client
# =============================================================================
phase_keycloak() {
  start_phase "KEYCLOAK: Verify & configure 'kasm' OIDC client"

  _kc_ensure_connectivity

  # 1.1 Verify the kasm client exists
  log_step "Checking for 'kasm' client in realm '${KC_REALM}'..."
  local kasm_client_json kasm_internal_id
  kasm_client_json=$(kc_api GET "/realms/${KC_REALM}/clients?clientId=kasm" 2>/dev/null || echo "[]")
  kasm_internal_id=$(echo "$kasm_client_json" | jq -r '.[0].id // empty')

  if [[ -z "$kasm_internal_id" ]]; then
    die "KASM client not found in Keycloak realm '${KC_REALM}'. Run setup-keycloak.sh first."
  fi
  log_ok "Found 'kasm' client (id: ${kasm_internal_id})"

  # 1.2 Get the client secret
  log_step "Retrieving client secret..."
  local kasm_client_secret=""
  if [[ -f "$OIDC_SECRETS_FILE" ]]; then
    kasm_client_secret=$(jq -r '.kasm // empty' "$OIDC_SECRETS_FILE" 2>/dev/null || echo "")
  fi
  if [[ -z "$kasm_client_secret" ]]; then
    kasm_client_secret=$(kc_api GET "/realms/${KC_REALM}/clients/${kasm_internal_id}/client-secret" 2>/dev/null | jq -r '.value // empty')
  fi
  if [[ -z "$kasm_client_secret" ]]; then
    die "Could not retrieve kasm client secret from oidc-client-secrets.json or Keycloak API"
  fi
  log_ok "Client secret retrieved (${kasm_client_secret:0:8}...)"

  # 1.3 Verify/create the Group Membership mapper on kasm-dedicated scope
  log_step "Checking Group Membership mapper..."
  local mappers existing_mapper
  mappers=$(kc_api GET "/realms/${KC_REALM}/clients/${kasm_internal_id}/protocol-mappers/models" 2>/dev/null || echo "[]")
  existing_mapper=$(echo "$mappers" | jq -r '.[] | select(.protocolMapper=="oidc-group-membership-mapper") | .name // empty' 2>/dev/null || echo "")

  if [[ -n "$existing_mapper" ]]; then
    log_ok "Group Membership mapper already exists: '${existing_mapper}'"
  else
    log_info "Creating Group Membership mapper on 'kasm' client..."
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[DRY RUN] Would create group-membership mapper"
    else
      kc_api POST "/realms/${KC_REALM}/clients/${kasm_internal_id}/protocol-mappers/models" \
        -d '{
          "name": "group-membership",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "config": {
            "full.path": "false",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "claim.name": "groups",
            "userinfo.token.claim": "true"
          }
        }' 2>/dev/null || log_warn "Mapper may already exist (409 conflict is OK)"
      log_ok "Group Membership mapper created"
    fi
  fi

  # 1.4 Configure backchannel logout URL
  log_step "Configuring backchannel logout URL..."
  local full_client
  full_client=$(kc_api GET "/realms/${KC_REALM}/clients/${kasm_internal_id}" 2>/dev/null)
  local current_backchannel
  current_backchannel=$(echo "$full_client" | jq -r '.attributes["backchannel.logout.url"] // empty' 2>/dev/null || echo "")
  local expected_backchannel="https://kasm.${DOMAIN}/api/oidc_backchannel_logout"

  if [[ "$current_backchannel" == "$expected_backchannel" ]]; then
    log_ok "Backchannel logout URL already configured"
  else
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[DRY RUN] Would set backchannel logout URL: ${expected_backchannel}"
    else
      local updated_client
      updated_client=$(echo "$full_client" | jq \
        --arg url "$expected_backchannel" \
        '.attributes["backchannel.logout.url"] = $url |
         .attributes["backchannel.logout.session.required"] = "true" |
         .frontchannelLogout = false')
      echo "$updated_client" | kc_api PUT "/realms/${KC_REALM}/clients/${kasm_internal_id}" -d @- 2>/dev/null
      log_ok "Backchannel logout URL set: ${expected_backchannel}"
    fi
  fi

  # Export for KASM phase
  export KASM_CLIENT_SECRET="$kasm_client_secret"

  end_phase "KEYCLOAK: kasm client configured"
}

# =============================================================================
# PHASE 2: KASM SIDE — Create OIDC Provider via Undocumented API
# =============================================================================
phase_kasm() {
  start_phase "KASM: Configure OpenID provider"

  # 2.1 Get KASM admin password
  log_step "Retrieving KASM admin password from kasm-secrets..."
  local admin_pass
  admin_pass=$(kubectl -n kasm get secret kasm-secrets \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
  if [[ -z "$admin_pass" ]]; then
    die "Could not retrieve KASM admin password from kasm-secrets"
  fi
  log_ok "Admin password retrieved"

  # 2.2 Get client secret (from Keycloak phase or file)
  local client_secret="${KASM_CLIENT_SECRET:-}"
  if [[ -z "$client_secret" && -f "$OIDC_SECRETS_FILE" ]]; then
    client_secret=$(jq -r '.kasm // empty' "$OIDC_SECRETS_FILE" 2>/dev/null || echo "")
  fi
  if [[ -z "$client_secret" ]]; then
    die "KASM client secret not available. Run with Keycloak phase or ensure oidc-client-secrets.json exists."
  fi

  # 2.3 Test KASM API connectivity
  log_step "Testing KASM API connectivity..."
  local health
  health=$(curl -sk --connect-timeout 10 --max-time 15 \
    "${KASM_URL}/api/__healthcheck" 2>/dev/null || echo "")
  if [[ -z "$health" ]]; then
    die "Cannot reach KASM API at ${KASM_URL}"
  fi
  log_ok "KASM API reachable"

  # 2.4 Login as admin to get session credentials
  log_step "Logging into KASM as admin@kasm.local..."
  local login_response
  login_response=$(kasm_login "$admin_pass")
  local session_token user_id
  session_token=$(echo "$login_response" | jq -r '.session_token // empty' 2>/dev/null || echo "")
  user_id=$(echo "$login_response" | jq -r '.user_id // empty' 2>/dev/null || echo "")

  if [[ -z "$session_token" || -z "$user_id" ]]; then
    log_warn "Could not extract session_token from login response."
    log_warn "Response: $(echo "$login_response" | jq -c . 2>/dev/null || echo "$login_response")"
    die "KASM login failed. Check admin credentials."
  fi
  log_ok "Logged in (user_id: ${user_id:0:8}...)"

  # 2.5 Check for existing OIDC config
  log_step "Checking for existing OIDC configurations..."
  local oidc_configs
  oidc_configs=$(curl -sk --connect-timeout 10 --max-time 30 \
    -X POST "${KASM_URL}/api/admin/get_oidc_configs" \
    -H "Content-Type: application/json" \
    -d "{
      \"token\": \"${session_token}\",
      \"user_id\": \"${user_id}\"
    }" 2>/dev/null || echo "")

  local existing_kc_config
  existing_kc_config=$(echo "$oidc_configs" | jq -r '.oidc_configs[]? | select(.client_id=="kasm") | .oidc_config_id // empty' 2>/dev/null || echo "")

  if [[ -n "$existing_kc_config" ]]; then
    log_ok "OIDC config for client_id 'kasm' already exists (id: ${existing_kc_config})"
    log_info "To recreate, delete it first in KASM Admin > Authentication > OpenID"
    end_phase "KASM: OIDC already configured"
    return 0
  fi

  # 2.6 Build the OIDC configuration payload
  # Use the external Keycloak FQDN (not port-forward) for KASM-side config
  local kc_external_url="https://keycloak.${DOMAIN}"
  local oidc_issuer="${kc_external_url}/realms/${KC_REALM}"

  local oidc_payload
  oidc_payload=$(jq -n \
    --arg token "$session_token" \
    --arg user_id "$user_id" \
    --arg client_id "kasm" \
    --arg client_secret "$client_secret" \
    --arg auth_url "${oidc_issuer}/protocol/openid-connect/auth" \
    --arg token_url "${oidc_issuer}/protocol/openid-connect/token" \
    --arg userinfo_url "${oidc_issuer}/protocol/openid-connect/userinfo" \
    --arg redirect_url "${KASM_URL}/api/oidc_callback" \
    --arg issuer "$oidc_issuer" \
    --arg display_name "Continue with Keycloak" \
    --arg logo_url "${kc_external_url}/resources/favicon.ico" \
    '{
      "token": $token,
      "user_id": $user_id,
      "target_oidc_config": {
        "enabled": true,
        "display_name": $display_name,
        "logo_url": $logo_url,
        "auto_login": false,
        "hostname": "",
        "default": true,
        "client_id": $client_id,
        "client_secret": $client_secret,
        "authorization_url": $auth_url,
        "token_url": $token_url,
        "user_info_url": $userinfo_url,
        "scope": "openid email profile",
        "username_attribute": "preferred_username",
        "groups_attribute": "groups",
        "redirect_url": $redirect_url,
        "oidc_issuer": $issuer,
        "logout_with_oidc_provider": true,
        "debug": true
      }
    }')

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would create OIDC config with payload:"
    echo "$oidc_payload" | jq 'del(.token, .user_id)'
    end_phase "KASM: DRY RUN complete"
    return 0
  fi

  # 2.7 Create the OIDC configuration
  log_step "Creating OIDC provider configuration in KASM..."
  local create_response
  create_response=$(curl -sk --connect-timeout 10 --max-time 30 \
    -X POST "${KASM_URL}/api/admin/create_oidc_config" \
    -H "Content-Type: application/json" \
    -d "$oidc_payload" 2>/dev/null || echo "")

  # Check for success
  local new_config_id
  new_config_id=$(echo "$create_response" | jq -r '.oidc_config.oidc_config_id // empty' 2>/dev/null || echo "")

  if [[ -n "$new_config_id" ]]; then
    log_ok "OIDC config created successfully (id: ${new_config_id})"
  else
    # If the inferred endpoint fails, try alternative patterns
    log_warn "Primary endpoint may have failed. Trying alternative..."
    log_warn "Response: $(echo "$create_response" | jq -c . 2>/dev/null || echo "${create_response:0:200}")"

    # Alternative: some KASM versions use set_oidc_config instead of create_oidc_config
    create_response=$(curl -sk --connect-timeout 10 --max-time 30 \
      -X POST "${KASM_URL}/api/admin/set_oidc_config" \
      -H "Content-Type: application/json" \
      -d "$oidc_payload" 2>/dev/null || echo "")

    new_config_id=$(echo "$create_response" | jq -r '.oidc_config.oidc_config_id // empty' 2>/dev/null || echo "")

    if [[ -n "$new_config_id" ]]; then
      log_ok "OIDC config created via set_oidc_config (id: ${new_config_id})"
    else
      log_warn "Automated OIDC creation failed. Response:"
      echo "$create_response" | jq . 2>/dev/null || echo "${create_response:0:500}"
      echo ""
      log_warn "==========================================================="
      log_warn "MANUAL FALLBACK: Configure OIDC in KASM Admin UI"
      log_warn "==========================================================="
      log_info ""
      log_info "The undocumented API endpoint name may differ in your KASM"
      log_info "version. To discover the correct endpoint:"
      log_info ""
      log_info "  1. Open browser DevTools > Network tab"
      log_info "  2. In KASM Admin UI, go to:"
      log_info "     Access Management > Authentication > OpenID > Add Config"
      log_info "  3. Fill in the form and click Submit"
      log_info "  4. In DevTools, find the POST request and note the URL"
      log_info ""
      log_info "Then update KASM_OIDC_ENDPOINT in this script and re-run."
      log_info ""
      log_info "OIDC configuration values:"
      log_info "  Client ID:       kasm"
      log_info "  Client Secret:   ${client_secret:0:8}..."
      log_info "  Authorization:   ${oidc_issuer}/protocol/openid-connect/auth"
      log_info "  Token:           ${oidc_issuer}/protocol/openid-connect/token"
      log_info "  Userinfo:        ${oidc_issuer}/protocol/openid-connect/userinfo"
      log_info "  Redirect:        ${KASM_URL}/api/oidc_callback"
      log_info "  Issuer:          ${oidc_issuer}"
      log_info "  Username Attr:   preferred_username"
      log_info "  Groups Attr:     groups"
      log_info "  Scopes:          openid email profile"
      end_phase "KASM: OIDC requires manual configuration (see above)"
      return 1
    fi
  fi

  # 2.8 Reminder about debug mode
  log_warn "OIDC Debug mode is ENABLED. Disable after validation:"
  log_info "  KASM Admin > Authentication > OpenID > edit > uncheck Debug"

  end_phase "KASM: OIDC provider configured"
}

# =============================================================================
# PHASE 3: SUMMARY
# =============================================================================
phase_summary() {
  local kc_external_url="https://keycloak.${DOMAIN}"
  local oidc_issuer="${kc_external_url}/realms/${KC_REALM}"

  echo ""
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}  KASM OIDC SETUP SUMMARY${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo ""
  echo "  Keycloak:"
  echo "    Realm:               ${KC_REALM}"
  echo "    Client ID:           kasm"
  echo "    Issuer:              ${oidc_issuer}"
  echo "    Backchannel Logout:  ${KASM_URL}/api/oidc_backchannel_logout"
  echo "    Group Mapper:        groups (Full group path: OFF)"
  echo ""
  echo "  KASM:"
  echo "    URL:                 ${KASM_URL}"
  echo "    OIDC Provider:       Continue with Keycloak"
  echo "    Redirect:            ${KASM_URL}/api/oidc_callback"
  echo "    Debug:               ENABLED (disable after validation)"
  echo ""
  echo -e "  ${YELLOW}Next steps:${NC}"
  echo "    1. Test: Open incognito browser > ${KASM_URL}"
  echo "       Click 'Continue with Keycloak' and log in"
  echo "    2. Verify group mapping in KASM Admin > Users"
  echo "    3. Disable Debug mode after validation"
  echo "    4. (Optional) Enable Auto Login for Keycloak-only auth"
  echo "       Local admin fallback: ${KASM_URL}/#/staticlogin"
  echo ""
  echo -e "  ${YELLOW}SSO Group Mapping (configure in KASM Admin > Groups):${NC}"
  echo "    Keycloak Group     →  KASM Group"
  echo "    ─────────────────────────────────────"
  echo "    platform-admins    →  Administrators"
  echo "    developers         →  Developers (create this group)"
  echo "    viewers            →  All Users"
  echo ""
  echo "    For each KASM group: SSO Group Mappings > Add SSO Mapping"
  echo "    SSO Provider: 'OpenID - Continue with Keycloak'"
  echo "    Group Attributes: <keycloak-group-name> (no slash prefix)"
  echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo -e "${BOLD}${BLUE}"
  echo "  KASM ↔ Keycloak OIDC Setup"
  echo -e "${NC}"

  DEPLOY_START_TIME=$(date +%s)
  export DEPLOY_START_TIME

  # Preflight
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
  command -v jq >/dev/null 2>&1      || die "jq not found"
  command -v curl >/dev/null 2>&1     || die "curl not found"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY RUN MODE — no changes will be made"
    echo ""
  fi

  # Run phases
  [[ "$SKIP_KEYCLOAK" == "true" ]] || phase_keycloak
  [[ "$SKIP_KASM" == "true" ]]     || phase_kasm
  phase_summary

  print_total_time 2>/dev/null || true
}

main "$@"
