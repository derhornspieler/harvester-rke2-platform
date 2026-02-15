# Keycloak Identity Provider

Keycloak deployed as the centralized Identity Provider (IDP) for the RKE2 cluster, with TOTP-based two-factor authentication.

> **Note**: Throughout this document, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env` (e.g., `example.com`). Derived formats:
> `<DOMAIN_DASHED>` = dots replaced with hyphens (e.g., `example-com`),
> `<DOMAIN_DOT>` = dots replaced with `-dot-` (e.g., `example-dot-com`).
> All service FQDNs follow the pattern `<service>.<DOMAIN>`.

## Status: Phase 1 (Deployed)

Phase 1 manifests are deployed. See deployment and post-deploy commands below.

---

## Overview

Keycloak will serve as the single sign-on (SSO) provider for all cluster services, replacing per-service basic-auth with centralized identity management and mandatory TOTP 2FA.

### Goals

1. Deploy Keycloak on the database worker pool (stateful workload)
2. TOTP 2FA enforced for all users via authenticator apps (Google Authenticator, Authy, etc.)
3. Integrate with existing services: Grafana, Vault, Traefik dashboard
4. TLS via Vault PKI / cert-manager (same pattern as other services)
5. External access at `https://keycloak.<DOMAIN>`

---

## Architecture

```
                    ┌────────────────────────────────────────┐
                    │   Traefik Ingress (203.0.113.202:443)   │
                    │  keycloak.<DOMAIN> (Gateway + HTTPRoute)│
                    └──────────────┬─────────────────────────┘
                                   │ HTTPS (Gateway API)
                    ┌──────────────▼───────────────┐
                    │        Keycloak              │
                    │   (keycloak namespace)        │
                    │   Port: 8080                  │
                    │   Database: PostgreSQL         │
                    │   Node: database pool          │
                    └──────────────┬───────────────┘
                                   │
               ┌───────────────────┼───────────────────┐
               │                   │                   │
        ┌──────▼──────┐   ┌───────▼───────┐   ┌──────▼──────┐
        │   Grafana   │   │    Vault      │   │  Traefik    │
        │  OIDC SSO   │   │  OIDC/JWT     │   │  Forward    │
        │             │   │               │   │  Auth       │
        └─────────────┘   └───────────────┘   └─────────────┘
```

## Implementation Plan

### Phase 1: Deploy Keycloak

1. **PostgreSQL database** (StatefulSet on database pool)
   - 1 replica, 10Gi PVC on Harvester CSI
   - Credentials stored in K8s Secret (migrate to Vault KV in Phase 4)
   - `nodeSelector: workload-type: database`

2. **Keycloak server** (Deployment on general pool)
   - Image: `quay.io/keycloak/keycloak:26.0` (or latest stable)
   - Production mode (`--optimized`, `KC_HOSTNAME`, `KC_PROXY_HEADERS=xforwarded`)
   - 1 replica initially, HA-ready with shared DB
   - `nodeSelector: workload-type: general`
   - Health check: `/health/ready`

3. **Kubernetes manifests** (Kustomize):
   ```
   services/keycloak/
   ├── kustomization.yaml
   ├── namespace.yaml
   ├── postgres/
   │   ├── secret.yaml              # DB credentials (CHANGEME placeholder)
   │   ├── configmap.yaml           # PostgreSQL tuning (shared_buffers, etc.)
   │   ├── statefulset.yaml         # PostgreSQL 16, 10Gi PVC
   │   └── service.yaml             # ClusterIP :5432
   ├── keycloak/
   │   ├── secret.yaml              # Admin credentials
   │   ├── rbac.yaml                # SA + Role for KUBE_PING pod listing
   │   ├── deployment.yaml          # Keycloak 26.0 HA, 2 replicas
   │   ├── service.yaml             # ClusterIP :8080
   │   ├── service-headless.yaml    # Headless for Infinispan KUBE_PING
   │   └── hpa.yaml                 # HPA 2-5 replicas, 70% CPU
   ├── gateway.yaml                 # Gateway with cert-manager annotation (auto-creates TLS secret)
   └── httproute.yaml               # HTTPRoute (no basic-auth)
   ```

### Phase 2: Configure Keycloak Realm

1. **Create realm**: `example`
2. **TOTP 2FA policy** (required for all users):
   - Authentication > Required Actions > enable "Configure OTP"
   - OTP Policy: TOTP, SHA-1, 6 digits, 30s period
   - Compatible with: Google Authenticator, Authy, Microsoft Authenticator, 1Password
3. **Create admin user** with TOTP enrolled
4. **Browser authentication flow**: Username/Password → OTP → Grant

### Phase 3: Service Integration

| Service | Integration Method | Keycloak Client |
|---------|-------------------|-----------------|
| Grafana | OIDC (generic OAuth) | `grafana` client, confidential |
| Vault | OIDC auth method | `vault` client, confidential |
| Traefik Dashboard | Traefik ForwardAuth middleware → Keycloak | `traefik` client, confidential |
| Prometheus | Traefik ForwardAuth middleware → Keycloak | `prometheus` client, public |
| Hubble UI | Traefik ForwardAuth middleware → Keycloak | `hubble` client, public |

**Grafana OIDC config** (via env vars in deployment):
```
GF_AUTH_GENERIC_OAUTH_ENABLED=true
GF_AUTH_GENERIC_OAUTH_NAME=Keycloak
GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=<from-secret>
GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email
GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://keycloak.<DOMAIN>/realms/example/protocol/openid-connect/auth
GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://keycloak.<DOMAIN>/realms/example/protocol/openid-connect/token
GF_AUTH_GENERIC_OAUTH_API_URL=https://keycloak.<DOMAIN>/realms/example/protocol/openid-connect/userinfo
GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(realm_access.roles[*], 'admin') && 'Admin' || 'Viewer'
```

**Vault OIDC config**:
```bash
vault auth enable oidc
vault write auth/oidc/config \
  oidc_discovery_url="https://keycloak.<DOMAIN>/realms/example" \
  oidc_client_id="vault" \
  oidc_client_secret="<from-secret>" \
  default_role="reader"
```

**Traefik ForwardAuth** (replaces basic-auth middleware):
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: keycloak-auth
spec:
  forwardAuth:
    address: http://keycloak.keycloak.svc:8080/realms/example/protocol/openid-connect/auth
    trustForwardHeader: true
    authResponseHeaders:
      - X-Forwarded-User
```

### Phase 4: Credential Migration

After Vault KV secrets engine is configured (see `docs/vault-credential-storage.md`):
- Move PostgreSQL credentials to Vault KV
- Move Keycloak admin credentials to Vault KV
- Move OIDC client secrets to Vault KV
- Use External Secrets Operator to sync Vault → K8s Secrets

---

## Resource Requirements

| Component | CPU (req/lim) | Memory (req/lim) | Storage | Pool |
|-----------|---------------|-------------------|---------|------|
| PostgreSQL | 250m / 1 | 512Mi / 2Gi | 10Gi PVC | database |
| Keycloak | 500m / 2 | 512Mi / 1536Mi | none (stateless) | general |

## Network Requirements

| Port | Protocol | Purpose |
|------|----------|---------|
| 8080 | TCP | Keycloak HTTP (behind Traefik TLS) |
| 8443 | TCP | Keycloak HTTPS (optional, not used with Traefik TLS termination) |
| 5432 | TCP | PostgreSQL (internal only) |

## Deployment

```bash
# Apply all manifests
kubectl --context rke2-prod apply -k services/keycloak/

# Wait for PostgreSQL
kubectl --context rke2-prod -n keycloak rollout status statefulset/keycloak-postgres --timeout=180s

# Wait for Keycloak (startup probe gives 150s for first boot)
kubectl --context rke2-prod -n keycloak rollout status deployment/keycloak --timeout=300s

# Verify Infinispan cluster (should show 2 members)
kubectl --context rke2-prod -n keycloak logs deployment/keycloak | grep -i "cluster"

# Verify TLS certificate issued
kubectl --context rke2-prod -n keycloak get certificate

# Verify HPA
kubectl --context rke2-prod -n keycloak get hpa

# Test external access
curl -sI https://keycloak.<DOMAIN>/
```

### Post-Deploy: Create Realm + Admin User

```bash
# Exec into keycloak pod
kubectl --context rke2-prod -n keycloak exec -it deployment/keycloak -- bash

# Authenticate admin CLI
/opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password 'CHANGEME_KC_ADMIN_PASSWORD'

# Create example realm
/opt/keycloak/bin/kcadm.sh create realms \
  -s realm=example \
  -s enabled=true \
  -s displayName="Example Org"

# Create admin user in example realm
/opt/keycloak/bin/kcadm.sh create users \
  -r example \
  -s username=admin \
  -s enabled=true \
  -s email=admin@<DOMAIN> \
  -s firstName=Admin \
  -s lastName=User

# Set password
/opt/keycloak/bin/kcadm.sh set-password \
  -r example \
  --username admin \
  --new-password 'CHANGEME_KC_ADMIN_PASSWORD'

# Assign realm-admin role
/opt/keycloak/bin/kcadm.sh add-roles \
  -r example \
  --uname admin \
  --rolename admin
```

## Dependencies

- Vault PKI + cert-manager (for TLS certificate)
- Traefik ingress (for external access)
- Harvester CSI (for PostgreSQL PVC)
- DNS: `keycloak.<DOMAIN>` → `203.0.113.202`

## Related Documentation

- [Security](../../docs/security.md) - Authentication matrix, SSO roadmap, TLS chain
- [Service Architecture](../../docs/service-architecture.md) - All services overview, resource budget
- [Deployment Flow](../../docs/deployment-flow.md) - 5-phase service deployment sequence
- [Troubleshooting](../../docs/troubleshooting.md) - Keycloak-specific issues and fixes
- [Operations Runbook](../../docs/operations-runbook.md) - Day-2 operations, credential rotation
