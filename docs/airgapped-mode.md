# Airgapped Deployment Mode

Guide for deploying the RKE2 cluster stack without internet access.

## Overview

When `AIRGAPPED=true` is set in `scripts/.env`, the deployment scripts:

1. **Helm charts**: Route all `helm install` calls through per-chart OCI URL overrides (`HELM_OCI_*` vars)
2. **Container images**: Route all image pulls through Harbor proxy cache backed by `UPSTREAM_PROXY_REGISTRY`
3. **Terraform cloud-init**: Use private RPM repo mirrors for Rocky 9 and RKE2 packages
4. **CRDs**: Apply Gateway API CRDs from bundled file instead of fetching from GitHub
5. **ArgoCD**: Use `GIT_BASE_URL` for internal git server URLs
6. **Argo Rollouts**: Use `ARGO_ROLLOUTS_PLUGIN_URL` for internal plugin binary
7. **RKE2 system images**: Set `system-default-registry` to Harbor

## `.env` Configuration

### Core Airgapped Variables

```bash
# Airgapped mode
AIRGAPPED="true"
UPSTREAM_PROXY_REGISTRY="registry.internal.corp:5000"

# Git base URL for ArgoCD service repos (internal Gitea/GitLab)
GIT_BASE_URL="git@gitea.internal:org"

# Argo Rollouts Gateway API plugin (must NOT point to github.com)
ARGO_ROLLOUTS_PLUGIN_URL="https://internal-artifacts.corp/rollouts-plugin-trafficrouter-gatewayapi/v0.5.0/gateway-api-plugin-linux-amd64"
```

### Per-Chart OCI URL Overrides (all required when AIRGAPPED=true)

```bash
HELM_OCI_CERT_MANAGER="oci://harbor.DOMAIN/charts.jetstack.io/cert-manager"
HELM_OCI_CNPG="oci://harbor.DOMAIN/charts-cnpg/cloudnative-pg"
HELM_OCI_CLUSTER_AUTOSCALER="oci://harbor.DOMAIN/charts-autoscaler/cluster-autoscaler"
HELM_OCI_REDIS_OPERATOR="oci://harbor.DOMAIN/charts-ot-helm/redis-operator"
HELM_OCI_MARIADB_OPERATOR="oci://harbor.DOMAIN/charts-mariadb/mariadb-operator"  # only if DEPLOY_LIBRENMS=true
HELM_OCI_VAULT="oci://harbor.DOMAIN/charts-hashicorp/vault"
HELM_OCI_HARBOR="oci://harbor.DOMAIN/charts-goharbor/harbor"
HELM_OCI_ARGOCD="oci://harbor.DOMAIN/charts-argoproj/argo-cd"
HELM_OCI_ARGO_ROLLOUTS="oci://harbor.DOMAIN/charts-argoproj/argo-rollouts"
HELM_OCI_KASM="oci://harbor.DOMAIN/charts-kasmtech/kasm"
```

### Terraform Variables (bridged via TF_VAR_ automatically)

```bash
# Private RPM repo mirrors (set in .env, bridged to Terraform)
PRIVATE_ROCKY_REPO_URL="https://repo.internal.corp"    # -> TF_VAR_private_rocky_repo_url
PRIVATE_RKE2_REPO_URL="https://repo.internal.corp"     # -> TF_VAR_private_rke2_repo_url
```

In `cluster/terraform.tfvars`:
```hcl
# Optional: PEM-encoded private CA cert (injected into all node cloud-init)
private_ca_pem = <<-PEM
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
PEM
```

## Required Helm Charts

All charts must be pushed to your private OCI registry before deployment.

| `.env` Variable | Chart | Version | Upstream Source |
|-----------------|-------|---------|----------------|
| `HELM_OCI_CERT_MANAGER` | cert-manager | v1.19.3 | `https://charts.jetstack.io` |
| `HELM_OCI_CNPG` | cloudnative-pg | 0.27.1 | `https://cloudnative-pg.github.io/charts` |
| `HELM_OCI_CLUSTER_AUTOSCALER` | cluster-autoscaler | latest | `https://kubernetes.github.io/autoscaler` |
| `HELM_OCI_REDIS_OPERATOR` | redis-operator | latest | `https://ot-container-kit.github.io/helm-charts/` |
| `HELM_OCI_VAULT` | vault | 0.32.0 | `https://helm.releases.hashicorp.com` |
| `HELM_OCI_HARBOR` | harbor | 1.18.2 | `https://helm.goharbor.io` |
| `HELM_OCI_ARGOCD` | argo-cd | latest | `oci://ghcr.io/argoproj/argo-helm/argo-cd` |
| `HELM_OCI_ARGO_ROLLOUTS` | argo-rollouts | latest | `oci://ghcr.io/argoproj/argo-helm/argo-rollouts` |
| `HELM_OCI_KASM` | kasm | 1.1181.0 | `https://helm.kasmweb.com/` |
| `HELM_OCI_MARIADB_OPERATOR` | mariadb-operator | latest | `https://mariadb-operator.github.io/mariadb-operator` |

### Pushing Charts to Harbor

From a machine with internet access:

```bash
HARBOR="harbor.yourdomain.com"

# Example: cert-manager
helm repo add jetstack https://charts.jetstack.io
helm pull jetstack/cert-manager --version v1.19.3
helm push cert-manager-v1.19.3.tgz oci://${HARBOR}/charts.jetstack.io

# Example: OCI-native chart (ArgoCD)
helm pull oci://ghcr.io/argoproj/argo-helm/argo-cd --version 7.8.23
helm push argo-cd-7.8.23.tgz oci://${HARBOR}/charts-argoproj

# Repeat for all charts in the table above
```

## Prerequisites for Airgapped Mode

### 1. All Credentials Pre-populated

Every required variable in `.env` must be set (same as online mode).

### 2. Per-Chart OCI URLs Set

All 9 (or 10 with LibreNMS) `HELM_OCI_*` variables must be set. The deploy script validates this at startup via `validate_airgapped_prereqs()`.

### 3. Gateway API CRDs Bundled

The file `crds/gateway-api-v1.3.0-standard-install.yaml` must exist in the repo. It is committed to the repo and applied locally instead of fetching from GitHub.

### 4. Upstream Proxy Registry or Harbor Pre-deployed

One of:
- **Upstream proxy registry** with pre-cached images from all 6 upstream registries
- **Harbor already deployed** with proxy cache projects populated from a previous online deployment
- **Local container registry mirror** with all required images pre-loaded

### 5. Internal DNS Resolution

All service FQDNs must resolve to the Traefik LB IP within the network.

### 6. Internal Git Server (for ArgoCD)

ArgoCD bootstrap apps have hardcoded git URLs. Run `./scripts/prepare-airgapped.sh` to rewrite them to your internal git server, then commit and push.

### 7. Private RPM Repo Mirrors (for Terraform/cloud-init)

Nodes need Rocky 9 EPEL and RKE2 RPM repos. Set `PRIVATE_ROCKY_REPO_URL` and `PRIVATE_RKE2_REPO_URL` in `.env`.

### 8. Private CA Certificate (optional)

If your internal services use a private CA, set `private_ca_pem` in `terraform.tfvars`. It will be injected into all node cloud-init and trusted via `update-ca-trust`.

## Preparation Workflow

### Step 1: Online Preparation

On a machine with internet access:

1. Push all Helm charts to Harbor OCI registry (see table above)
2. Deploy the cluster once online — Harbor proxy cache auto-caches all pulled images
3. Run `./scripts/prepare-airgapped.sh` to rewrite ArgoCD git URLs
4. Download the Argo Rollouts Gateway API plugin binary to an internal artifact server

### Step 2: Configure .env

Set all airgapped variables in `scripts/.env`:

```bash
AIRGAPPED="true"
UPSTREAM_PROXY_REGISTRY="harbor.yourdomain.com"
GIT_BASE_URL="git@gitea.internal:org"
ARGO_ROLLOUTS_PLUGIN_URL="https://artifacts.internal/gateway-api-plugin-linux-amd64"
HELM_OCI_CERT_MANAGER="oci://harbor.yourdomain.com/charts.jetstack.io/cert-manager"
# ... (all HELM_OCI_* vars)
PRIVATE_ROCKY_REPO_URL="https://repo.internal.corp"
PRIVATE_RKE2_REPO_URL="https://repo.internal.corp"
```

### Step 3: Deploy

```bash
./scripts/deploy-cluster.sh
```

The script will:
1. Validate all airgapped prerequisites at startup
2. Skip `helm repo add/update` (charts come from OCI)
3. Use `resolve_helm_chart()` to route each chart to its OCI URL
4. Apply Gateway API CRDs from bundled file
5. Substitute `ARGO_ROLLOUTS_PLUGIN_URL` into Helm values
6. Use private RPM repos in cloud-init
7. Set `system-default-registry` in RKE2 machine_global_config

## How It Works

### Helm Chart Routing

`resolve_helm_chart()` in `lib.sh`:
- **Online**: returns the original chart ref (e.g., `jetstack/cert-manager`)
- **Airgapped**: returns the OCI URL from the corresponding `HELM_OCI_*` var

`helm_repo_add()` is a no-op when `AIRGAPPED=true`.

### Terraform Cloud-Init

When `var.airgapped = true`:
- RPM repo URLs switch from `rpm.rancher.io` / EPEL metalink to private mirrors
- Private CA PEM is written to `/etc/pki/ca-trust/source/anchors/` and trusted via `update-ca-trust`
- `system-default-registry` in `machine_global_config` points RKE2 system images to Harbor

### Validation

`validate_airgapped_prereqs()` runs at the end of `generate_or_load_env()` and checks:
- `UPSTREAM_PROXY_REGISTRY` is set
- All required `HELM_OCI_*` vars are set
- `GIT_BASE_URL` is set
- `ARGO_ROLLOUTS_PLUGIN_URL` does NOT point to `github.com`
- `crds/gateway-api-v1.3.0-standard-install.yaml` exists

On failure, it prints the full list of required charts with upstream sources.

## Phase-by-Phase Airgapped Impact

| Phase | Service | Airgapped Change |
|-------|---------|-----------------|
| 0 | Terraform | Private RPM repos in cloud-init; `system-default-registry` in machine_global_config |
| 1 | cert-manager, CNPG, Redis Op, Autoscaler | All charts via `HELM_OCI_*`; Gateway API CRDs from bundled file |
| 2 | Vault + PKI | Chart via `HELM_OCI_VAULT`; Root CA generated locally (no network needed) |
| 3 | Monitoring Stack | Images via Kustomize (pulled through Harbor mirrors) |
| 4 | Harbor | Chart via `HELM_OCI_HARBOR`; proxy cache uses `UPSTREAM_PROXY_REGISTRY` |
| 5 | ArgoCD + Rollouts | Charts via `HELM_OCI_ARGOCD`/`HELM_OCI_ARGO_ROLLOUTS`; plugin URL substituted |
| 6 | Keycloak | Images via Harbor mirrors |
| 7 | Kasm, Mattermost, etc. | Chart via `HELM_OCI_KASM`; images via Harbor mirrors |
| 8 | DNS Records | Internal DNS only |
| 9 | Validation | No external dependencies |
| 10 | Keycloak OIDC | oauth2-proxy images via Harbor mirrors |
| 11 | GitLab | External chart path (unchanged) |

## Implementation Status

- [x] `AIRGAPPED` and `UPSTREAM_PROXY_REGISTRY` flags in `.env`
- [x] Export airgapped variables in `generate_or_load_env()` (lib.sh)
- [x] Harbor proxy cache routing through upstream proxy (deploy-cluster.sh Phase 4)
- [x] Rancher cluster registries with Harbor mirrors + Root CA trust (lib.sh)
- [x] `validate_airgapped_prereqs()` — validates all airgapped vars at startup
- [x] `resolve_helm_chart()` — routes 10 chart installs to OCI URLs
- [x] `helm_repo_add()` — no-op in airgapped mode
- [x] Gateway API CRDs bundled at `crds/gateway-api-v1.3.0-standard-install.yaml`
- [x] Argo Rollouts plugin URL via `CHANGEME_ARGO_ROLLOUTS_PLUGIN_URL` token
- [x] `GIT_BASE_URL` derivation + `CHANGEME_GIT_BASE_URL` substitution
- [x] Terraform: `system-default-registry` when `var.airgapped = true`
- [x] Terraform: private RPM repo URLs in cloud-init
- [x] Terraform: private CA PEM injection + `update-ca-trust`
- [x] `prepare-airgapped.sh` — rewrites ArgoCD bootstrap app git URLs
- [x] TF_VAR bridge for `airgapped`, `private_rocky_repo_url`, `private_rke2_repo_url`
- [ ] Document required container image list per service
- [ ] Test full airgapped deployment cycle
