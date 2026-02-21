#!/usr/bin/env bash
# =============================================================================
# setup-keycloak.sh — Keycloak Realm, OIDC Clients, Service Bindings
# =============================================================================
# Standalone backup/re-run tool for Keycloak OIDC configuration.
# All functions are defined in lib.sh and shared with deploy-cluster.sh.
#
# In normal operation, Phase 5 of deploy-cluster.sh handles OIDC setup inline.
# This script exists as a standalone re-run tool if you need to:
#   - Recreate OIDC clients after a Keycloak reset
#   - Re-bind services to Keycloak
#   - Add test users
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
      echo ""
      echo "  Phases:"
      echo "    1  Realm + admin users + TOTP"
      echo "    2  OIDC client creation (all services)"
      echo "    3  Service bindings (Grafana, ArgoCD, Harbor, Vault, Mattermost, Rancher)"
      echo "    4  Groups + role mapping"
      echo "    5  Test users (12 users)"
      echo "    6  Validation summary"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Load domain configuration from .env (if available)
generate_or_load_env

# =============================================================================
# PHASE 1: REALM + ADMIN SETUP
# =============================================================================
phase_1_realm() {
  start_phase "PHASE 1: REALM + ADMIN SETUP"

  kc_init
  kc_setup_realm

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

  kc_init

  # Initialize secrets JSON
  echo "{}" > "$OIDC_SECRETS_FILE"

  # Create "groups" client scope
  kc_create_groups_scope

  local secret

  # Grafana
  secret=$(kc_create_client "grafana" "https://grafana.${DOMAIN}/*" "Grafana")
  kc_save_secret "grafana" "$secret"

  # ArgoCD
  secret=$(kc_create_client "argocd" "https://argo.${DOMAIN}/auth/callback" "ArgoCD")
  kc_save_secret "argocd" "$secret"

  # Harbor
  secret=$(kc_create_client "harbor" "https://harbor.${DOMAIN}/c/oidc/callback" "Harbor Registry")
  kc_save_secret "harbor" "$secret"

  # Vault
  secret=$(kc_create_client "vault" "https://vault.${DOMAIN}/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" "Vault")
  kc_save_secret "vault" "$secret"

  # Mattermost
  secret=$(kc_create_client "mattermost" "https://mattermost.${DOMAIN}/signup/openid/complete" "Mattermost")
  kc_save_secret "mattermost" "$secret"

  # Kasm
  secret=$(kc_create_client "kasm" "https://kasm.${DOMAIN}/api/oidc_callback" "Kasm Workspaces")
  kc_save_secret "kasm" "$secret"

  # GitLab
  secret=$(kc_create_client "gitlab" "https://gitlab.${DOMAIN}/users/auth/openid_connect/callback" "GitLab")
  kc_save_secret "gitlab" "$secret"

  # Kubernetes (public — no secret)
  kc_create_public_client "kubernetes" "http://localhost:8000,http://localhost:18000" "Kubernetes (kubelogin)"

  # Per-service oauth2-proxy OIDC clients
  secret=$(kc_create_client "prometheus-oidc" "https://prometheus.${DOMAIN}/oauth2/callback" "Prometheus")
  kc_save_secret "prometheus-oidc" "$secret"

  secret=$(kc_create_client "alertmanager-oidc" "https://alertmanager.${DOMAIN}/oauth2/callback" "AlertManager")
  kc_save_secret "alertmanager-oidc" "$secret"

  secret=$(kc_create_client "hubble-oidc" "https://hubble.${DOMAIN}/oauth2/callback" "Hubble")
  kc_save_secret "hubble-oidc" "$secret"

  secret=$(kc_create_client "traefik-dashboard-oidc" "https://traefik.${DOMAIN}/oauth2/callback" "Traefik Dashboard")
  kc_save_secret "traefik-dashboard-oidc" "$secret"

  secret=$(kc_create_client "rollouts-oidc" "https://rollouts.${DOMAIN}/oauth2/callback" "Argo Rollouts")
  kc_save_secret "rollouts-oidc" "$secret"

  # Rancher
  # Rancher — use actual Rancher URL from tfvars (may differ from RANCHER_FQDN)
  local _rancher_url
  _rancher_url=$(get_rancher_url)
  secret=$(kc_create_client "rancher" "${_rancher_url}/verify-auth,${_rancher_url}/*" "Rancher")
  kc_save_secret "rancher" "$secret"

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

  # GitLab CI service account
  secret=$(kc_create_service_account_client "gitlab-ci" "GitLab CI Service Account")
  kc_save_secret "gitlab-ci" "$secret"

  # Add "groups" scope to all relevant clients
  local all_clients=(argocd kubernetes grafana harbor vault prometheus-oidc alertmanager-oidc hubble-oidc traefik-dashboard-oidc rollouts-oidc rancher identity-portal identity-portal-admin gitlab-ci)
  kc_add_groups_scope_to_clients "${all_clients[@]}"

  log_ok "All OIDC clients created. Secrets saved to: ${OIDC_SECRETS_FILE}"

  end_phase "PHASE 2: OIDC CLIENTS"
}

# =============================================================================
# PHASE 3: BIND SERVICES TO KEYCLOAK
# =============================================================================
phase_3_bindings() {
  start_phase "PHASE 3: SERVICE BINDINGS"

  kc_init

  kc_bind_grafana
  kc_bind_argocd
  kc_bind_harbor
  kc_bind_vault
  kc_bind_mattermost
  kc_bind_rancher

  # Kasm — must be configured via Admin UI API
  log_step "Kasm OIDC..."
  local oidc_issuer="https://keycloak.${DOMAIN}/realms/${KC_REALM}"
  log_warn "Kasm OIDC must be configured via Admin UI > Authentication > OpenID"
  log_info "  Client ID:     kasm"
  log_info "  Client Secret: $(jq -r '.kasm' "$OIDC_SECRETS_FILE")"
  log_info "  Discovery URL: ${oidc_issuer}/.well-known/openid-configuration"

  # GitLab
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

  kc_init
  kc_create_groups

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
    fi
  fi

  # Add group/audience mappers to all clients
  local all_clients=("grafana" "argocd" "harbor" "vault" "mattermost" "kasm" "gitlab" "kubernetes" "prometheus-oidc" "alertmanager-oidc" "hubble-oidc" "traefik-dashboard-oidc" "rollouts-oidc" "rancher" "identity-portal" "identity-portal-admin" "gitlab-ci")
  kc_add_group_mappers "${all_clients[@]}"

  end_phase "PHASE 4: GROUPS + ROLE MAPPING"
}

# =============================================================================
# PHASE 5: TEST USERS
# =============================================================================
phase_5_test_users() {
  start_phase "PHASE 5: TEST USERS"

  kc_init
  kc_create_test_users

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
  echo "    Password: ${REALM_ADMIN_PASS:-<generated during phase 1>}"
  echo ""
  echo "  General User:"
  echo "    Username: user"
  echo "    Password: ${REALM_USER_PASS:-<generated during phase 1>}"
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

  # Append Keycloak credentials to credentials.txt
  local creds_file="${CLUSTER_DIR}/credentials.txt"
  if [[ -f "$creds_file" ]]; then
    cat >> "$creds_file" <<EOF

# Keycloak OIDC (setup-keycloak.sh — $(date -u +%Y-%m-%dT%H:%M:%SZ))
Keycloak Realm  https://keycloak.${DOMAIN}/admin/${KC_REALM}/console
  Realm Admin:   admin / ${REALM_ADMIN_PASS:-<see phase 1 output>}
  General User:  user / ${REALM_USER_PASS:-<see phase 1 output>}  (developers group)

OIDC Client Secrets:
$(jq -r 'to_entries[] | "  \(.key): \(.value)"' "$OIDC_SECRETS_FILE" 2>/dev/null || echo "  (see ${OIDC_SECRETS_FILE})")

Test Users (password: TestUser2026!, MFA optional):
  alice.morgan, bob.chen, carol.silva, dave.kumar, eve.mueller, frank.jones,
  grace.park, henry.wilson, iris.tanaka, jack.brown, kate.lee, leo.garcia
EOF
    log_ok "Keycloak credentials appended to ${creds_file}"
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
