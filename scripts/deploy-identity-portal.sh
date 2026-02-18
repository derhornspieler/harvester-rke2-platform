#!/usr/bin/env bash
# deploy-identity-portal.sh — Targeted deployment of the Identity Portal
# to an existing RKE2 cluster with Vault + Keycloak already running.
#
# Usage:
#   ./scripts/deploy-identity-portal.sh
#   ./scripts/deploy-identity-portal.sh --skip-vault   # Skip Vault SSH CA setup
#   ./scripts/deploy-identity-portal.sh --skip-keycloak # Skip Keycloak client setup
#
# Prerequisites:
#   - RKE2 workload cluster accessible via kubectl (context: rke2-prod)
#   - Vault running and unsealed
#   - Keycloak running
#   - cert-manager running with vault-issuer ClusterIssuer
#   - Container images built and pushed to GHCR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

# shellcheck source=scripts/lib.sh
source scripts/lib.sh

# ── Parse flags ──────────────────────────────────────────────────────────
SKIP_VAULT=false
SKIP_KEYCLOAK=false
for arg in "$@"; do
  case "$arg" in
    --skip-vault)    SKIP_VAULT=true ;;
    --skip-keycloak) SKIP_KEYCLOAK=true ;;
    -h|--help)
      echo "Usage: $0 [--skip-vault] [--skip-keycloak]"
      exit 0
      ;;
  esac
done

# ── Load environment ─────────────────────────────────────────────────────
log_step "Loading environment"
generate_or_load_env
DOMAIN_DASHED="${DOMAIN//./-}"
log_ok "Environment loaded (DOMAIN=${DOMAIN})"

# ── Switch to RKE2 workload cluster ─────────────────────────────────────
log_step "Switching to RKE2 workload cluster context"
kubectl config use-context rke2-prod
kubectl cluster-info | head -1
log_ok "Connected to RKE2 cluster"

# ── Step 1: Vault SSH Certificate Authority ──────────────────────────────
if [[ "$SKIP_VAULT" == "false" ]]; then
  log_step "Configuring Vault SSH Certificate Authority"

  # Load Vault root token
  VAULT_INIT_FILE="cluster/vault-init.json"
  if [[ ! -f "$VAULT_INIT_FILE" ]]; then
    log_error "Vault init file not found: $VAULT_INIT_FILE"
    log_error "Cannot configure SSH CA without Vault root token"
    exit 1
  fi
  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

  log_step "Enabling SSH client signer secrets engine"
  vault_exec "$root_token" secrets enable -path=ssh-client-signer ssh 2>/dev/null || true

  log_step "Generating SSH CA signing key"
  vault_exec "$root_token" write ssh-client-signer/config/ca generate_signing_key=true 2>/dev/null || true

  log_step "Creating SSH signing roles"

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

  log_step "Creating Vault policies"

  vault_exec_stdin "$root_token" policy write ssh-sign-admin - <<'POLICY'
path "ssh-client-signer/sign/*" {
  capabilities = ["create", "update"]
}
path "ssh-client-signer/config/ca" {
  capabilities = ["read"]
}
POLICY

  vault_exec_stdin "$root_token" policy write ssh-sign-self - <<'POLICY'
path "ssh-client-signer/sign/developer-role" {
  capabilities = ["create", "update"]
}
path "ssh-client-signer/config/ca" {
  capabilities = ["read"]
}
POLICY

  vault_exec_stdin "$root_token" policy write ssh-admin - <<'POLICY'
path "ssh-client-signer/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
POLICY

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

  log_ok "Vault SSH CA configured (3 roles, 4 policies, K8s auth role)"
else
  log_warn "Skipping Vault SSH CA setup (--skip-vault)"
fi

# ── Step 2: Distribute Root CA ───────────────────────────────────────────
log_step "Creating identity-portal namespace"
kubectl create namespace identity-portal --dry-run=client -o yaml | kubectl apply -f -

log_step "Distributing Root CA to identity-portal namespace"
# Copy the vault-root-ca ConfigMap from kube-system (where distribute_root_ca puts it)
if kubectl get configmap vault-root-ca -n kube-system &>/dev/null; then
  kubectl get configmap vault-root-ca -n kube-system -o json | \
    jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.managedFields) | .metadata.namespace = "identity-portal"' | \
    kubectl apply -f -
  log_ok "Root CA ConfigMap distributed to identity-portal namespace"
else
  log_warn "vault-root-ca ConfigMap not found in kube-system — TLS verification may fail"
fi

# ── Step 3: Apply K8s manifests ──────────────────────────────────────────
log_step "Applying Identity Portal manifests"
kube_apply_k_subst services/identity-portal
log_ok "Manifests applied"

# ── Step 4: Keycloak OIDC clients (two-client setup) ───────────────────
# The identity-portal uses two Keycloak clients:
#   - identity-portal:       PUBLIC client for frontend PKCE OIDC flow (browser login)
#   - identity-portal-admin: CONFIDENTIAL client with service account for backend Admin API
# setup-keycloak.sh creates both clients and exports IDENTITY_PORTAL_OIDC_SECRET
# (the identity-portal-admin client secret) for injection in step 5.
if [[ "$SKIP_KEYCLOAK" == "false" ]]; then
  log_step "Creating Identity Portal OIDC clients in Keycloak (public + admin)"
  log_info "Running setup-keycloak.sh to create/update identity-portal (public) and identity-portal-admin (confidential)"
  log_info "(This will also update existing clients — safe to re-run)"
  bash scripts/setup-keycloak.sh
  log_ok "Keycloak OIDC clients configured (identity-portal + identity-portal-admin)"
else
  log_warn "Skipping Keycloak client setup (--skip-keycloak)"
  log_warn "You must set IDENTITY_PORTAL_OIDC_SECRET manually"
fi

# ── Step 5: Inject OIDC secret ──────────────────────────────────────────
log_step "Injecting Identity Portal OIDC secret"
if [[ -z "${IDENTITY_PORTAL_OIDC_SECRET:-}" ]]; then
  log_error "IDENTITY_PORTAL_OIDC_SECRET not set — run setup-keycloak.sh first or set in .env"
  exit 1
fi
kubectl -n identity-portal create secret generic identity-portal-secret \
  --from-literal=KEYCLOAK_CLIENT_SECRET="${IDENTITY_PORTAL_OIDC_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
log_ok "OIDC secret injected"

# ── Step 6: Restart backend to pick up secret ────────────────────────────
log_step "Restarting backend deployment"
kubectl -n identity-portal rollout restart deployment/identity-portal-backend
log_ok "Backend restart triggered"

# ── Step 7: Wait for deployments ─────────────────────────────────────────
log_step "Waiting for Identity Portal deployments"
wait_for_deployment identity-portal identity-portal-backend 180
wait_for_deployment identity-portal identity-portal-frontend 180
log_ok "All deployments ready"

# ── Step 8: Wait for TLS certificate ────────────────────────────────────
log_step "Waiting for TLS certificate"
wait_for_tls_secret identity-portal "identity-${DOMAIN_DASHED}-tls" 180
log_ok "TLS certificate issued"

# ── Step 9: Verify ──────────────────────────────────────────────────────
log_step "Verifying Identity Portal"
# Deploy a curl pod for in-cluster checks if not exists
deploy_check_pod 2>/dev/null || true
sleep 5
check_https "identity.${DOMAIN}" "/healthz" || log_warn "HTTPS check failed — DNS may not be configured yet"
cleanup_check_pod 2>/dev/null || true

echo ""
log_ok "════════════════════════════════════════════════════════════════"
log_ok "  Identity Portal deployed successfully!"
log_ok "  URL: https://identity.${DOMAIN}"
log_ok "════════════════════════════════════════════════════════════════"
echo ""
log_info "Next steps:"
log_info "  1. Ensure DNS resolves: identity.${DOMAIN} → cluster ingress IP"
log_info "  2. Open https://identity.${DOMAIN} in your browser"
log_info "  3. Login via Keycloak OIDC"
log_info "  4. Test SSH certificate signing and kubeconfig download"
