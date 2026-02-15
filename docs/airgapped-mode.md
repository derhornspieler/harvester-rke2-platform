# Airgapped Deployment Mode

Design document for deploying the RKE2 cluster stack without internet access.

## Overview

When `AIRGAPPED=true` is set in `scripts/.env`, the deployment scripts validate that all required resources (images, charts, credentials) are available locally or via internal registries before proceeding. No external network calls are made during deployment.

## `.env` Configuration

```bash
AIRGAPPED="false"   # Set to "true" for airgapped deployment
```

## Prerequisites for Airgapped Mode

### 1. All Credentials Pre-populated

Every required variable in `.env` must be set. The deployment scripts will not generate random passwords in airgapped mode (they may fail DNS/network checks during generation).

Required variables:
- `DOMAIN` — internal DNS domain
- `HARBOR_ADMIN_PASSWORD`
- `HARBOR_REDIS_PASSWORD`
- `KEYCLOAK_DB_PASSWORD`
- `KEYCLOAK_ADMIN_CLIENT_SECRET`
- `GRAFANA_ADMIN_PASSWORD`
- `BASIC_AUTH_PASSWORD`
- All CNPG database passwords

### 2. Internal DNS Resolution

All service FQDNs must resolve to the Traefik LB IP within the network:
- `vault.DOMAIN`, `harbor.DOMAIN`, `keycloak.DOMAIN`, etc.

### 3. Harbor Pre-deployed or Local Registry Mirror

One of:
- Harbor already deployed with proxy cache projects populated from a previous online deployment
- Local container registry mirror with all required images pre-loaded

### 4. Helm Charts Available

Either:
- OCI charts accessible via internal Harbor
- Tarballs in a `charts/` directory (future implementation)

### 5. Private CA Certificate

- Root CA PEM file at `cluster/aegis-root-ca.pem`
- Trusted by all internal services

### 6. Vault Init File (Rebuild Scenarios)

- `cluster/vault-init.json` must exist if rebuilding from backup
- Stored as K8s secret on Harvester

## Validation Function

```bash
# In lib.sh:
validate_airgapped_prereqs() {
    [[ "${AIRGAPPED:-false}" != "true" ]] && return 0

    local errors=0

    # Check required .env values
    for var in DOMAIN HARBOR_ADMIN_PASSWORD HARBOR_REDIS_PASSWORD \
               KEYCLOAK_DB_PASSWORD GRAFANA_ADMIN_PASSWORD BASIC_AUTH_PASSWORD; do
        if [[ -z "${!var}" ]]; then
            log_error "AIRGAPPED: ${var} not set in .env"
            errors=$((errors + 1))
        fi
    done

    # Test internal DNS
    if ! host "${DOMAIN}" &>/dev/null; then
        log_warn "AIRGAPPED: ${DOMAIN} does not resolve (may be expected pre-deploy)"
    fi

    # Test Private CA trust
    if [[ -f "${CLUSTER_DIR}/aegis-root-ca.pem" ]]; then
        log_ok "AIRGAPPED: Root CA certificate found"
    else
        log_error "AIRGAPPED: Root CA certificate not found at cluster/aegis-root-ca.pem"
        errors=$((errors + 1))
    fi

    # Test Harbor reachability (if DNS resolves)
    if host "harbor.${DOMAIN}" &>/dev/null 2>&1; then
        if curl --cacert "${CLUSTER_DIR}/aegis-root-ca.pem" -sf \
            "https://harbor.${DOMAIN}/api/v2.0/health" &>/dev/null; then
            log_ok "AIRGAPPED: Harbor registry reachable"
        else
            log_warn "AIRGAPPED: Harbor not reachable yet (may be deployed later)"
        fi
    fi

    [[ $errors -gt 0 ]] && die "AIRGAPPED: ${errors} prerequisite(s) failed"
    log_ok "AIRGAPPED: All prerequisites validated"
}
```

## Image Pre-loading Strategy

For a fully airgapped deployment, container images must be pre-loaded into the internal registry. Use Harbor's proxy cache feature from a previous online deployment:

### Step 1: Online Deployment (with internet)

Deploy normally. Harbor's proxy cache projects (`dockerhub`, `quay`, `ghcr`, `gcr`, `k8s`, `elastic`) automatically cache images as they are pulled by the cluster.

### Step 2: Export Registry Data

Back up Harbor's MinIO storage and PostgreSQL database.

### Step 3: Airgapped Deployment

Restore Harbor from backup. All cached images are available without internet.

### Manual Image Loading (Alternative)

For clusters without a prior Harbor deployment:

```bash
# On machine with internet access:
# 1. Pull all required images
# 2. Save as tarballs
# 3. Transfer to airgapped network
# 4. Load into internal registry

# Example:
docker pull gcr.io/distroless/static:nonroot
docker tag gcr.io/distroless/static:nonroot harbor.internal/gcr/distroless/static:nonroot
docker push harbor.internal/gcr/distroless/static:nonroot
```

## Helm Chart Strategy

### OCI Charts via Harbor

Harbor serves as an OCI registry for Helm charts. In online mode, charts are pushed to the `charts` project:

```bash
helm push cert-manager-v1.19.3.tgz oci://harbor.DOMAIN/charts
```

In airgapped mode, `helm install` pulls from Harbor instead of upstream:

```bash
helm install cert-manager oci://harbor.DOMAIN/charts/cert-manager --version v1.19.3
```

### Local Tarballs (Future)

A future enhancement could download charts to a local `charts/` directory:

```bash
charts/
  cert-manager-v1.19.3.tgz
  cloudnative-pg-0.27.1.tgz
  vault-0.32.0.tgz
  harbor-1.18.2.tgz
  ...
```

The deploy script would detect `AIRGAPPED=true` and use `helm install -f values.yaml charts/<chart>.tgz` instead of repo-based installs.

## Deploy Script Integration

The `validate_airgapped_prereqs()` function is called:
1. In `check_prerequisites()` (lib.sh) — runs before any phase
2. Before Phase 4 (Harbor) — verifies registry backend is ready
3. Before Phase 10 (Keycloak OIDC) — verifies all services accessible

## Implementation Status

- [ ] Add `AIRGAPPED` flag to `.env`
- [ ] Implement `validate_airgapped_prereqs()` in `lib.sh`
- [ ] Add airgapped Helm install path in `helm_install_if_needed()`
- [ ] Document required image list per service
- [ ] Add chart tarball download script for offline preparation
- [ ] Test full airgapped deployment cycle
