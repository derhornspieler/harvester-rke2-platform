# Airgapped Bootstrap Registry Implementation Plan

## 1. Problem Statement

The current airgapped mode (`AIRGAPPED=true`) has a fundamental chicken-and-egg problem: `system-default-registry` in `cluster.tf` is set to `harbor.${domain}`, but Harbor does not exist until Phase 4. During Phases 0 through 3, the RKE2 nodes must pull container images (RKE2 system images, Traefik, Cilium, cert-manager, CNPG, Vault, kube-prometheus-stack, etc.) from *somewhere*. In online mode, they pull directly from public registries. In the current airgapped code, the `system-default-registry` points to a Harbor instance that does not yet exist, which means the cluster would never bootstrap.

The solution is a **bootstrap registry** — a pre-existing external registry (running outside the RKE2 cluster, potentially on the Harvester host network, on the vcluster Rancher management plane, or on a separate host) that contains all images and Helm charts needed before in-cluster Harbor comes online. After Harbor is operational (end of Phase 4), the system transitions from the bootstrap registry to Harbor.

## 2. Architecture Overview

```
                    PHASE 0-3                              PHASE 4+
    ┌─────────────────────────────┐     ┌──────────────────────────────────┐
    │   Bootstrap Registry        │     │   In-Cluster Harbor              │
    │   (pre-existing, external)  │     │   (proxy-cache + local projects) │
    │   e.g. registry.local:5000  │     │   harbor.${DOMAIN}              │
    │                             │     │                                  │
    │   Contains:                 │     │   Contains:                      │
    │   - RKE2 system images      │     │   - Proxy-cache for docker.io,  │
    │   - Cilium, Traefik images  │     │     ghcr.io, quay.io, etc.      │
    │   - cert-manager images     │     │   - OCI Helm charts             │
    │   - CNPG, Redis Op images   │     │   - Custom operator images      │
    │   - Vault images            │     │   - All bootstrap images (now   │
    │   - Monitoring stack images │     │     served via Harbor mirrors)   │
    │   - Harbor images (!)       │     │                                  │
    │   - OCI Helm charts         │     │                                  │
    └─────────────────────────────┘     └──────────────────────────────────┘
             │                                        │
             │ system-default-registry                │ Rancher registries
             │ + containerd mirrors                   │ patch (mirrors + CA)
             ▼                                        ▼
    ┌─────────────────────────────────────────────────────────────────────┐
    │                     RKE2 Cluster Nodes                             │
    │  Phase 0-3: All pulls → Bootstrap Registry                        │
    │  Phase 4+:  All pulls → Harbor (via containerd mirrors)           │
    └─────────────────────────────────────────────────────────────────────┘
```

## 3. Pre-requisites: What Must Be Pre-loaded in the Bootstrap Registry

### 3.1 RKE2 System Images

RKE2 v1.34.2 ships with a fixed image list. When `system-default-registry` is set, RKE2 rewrites all system image references to pull from that registry. The full list can be obtained from:
```
https://github.com/rancher/rke2/releases/download/v1.34.2+rke2r1/rke2-images-all.linux-amd64.txt
```

Key images include:
- `rancher/rke2-runtime:v1.34.2-rke2r1`
- Cilium agent, operator, hubble images
- Traefik image
- CoreDNS, metrics-server, etcd
- Rancher system-agent, cattle-agent

### 3.2 Helm Chart Repositories (as OCI artifacts)

All charts installed in Phases 1-4 must be available from the bootstrap registry:
- cert-manager v1.19.3
- cloudnative-pg 0.27.1
- cluster-autoscaler (latest)
- redis-operator (latest)
- vault 0.32.0
- kube-prometheus-stack (`KPS_CHART_VERSION`, currently 72.6.2)
- harbor 1.18.2
- mariadb-operator (if `DEPLOY_LIBRENMS=true`)

### 3.3 Application Container Images (Phases 1-4)

Images referenced in Kustomize manifests and Helm values used before Harbor is up:
- `quay.io/jetstack/cert-manager-*` (controller, webhook, cainjector)
- `ghcr.io/cloudnative-pg/cloudnative-pg:*`
- `quay.io/opstree/redis:v7.0.15`, `quay.io/opstree/redis-sentinel:v7.0.15`
- `registry.k8s.io/autoscaling/cluster-autoscaler:*`
- `hashicorp/vault:*`
- `docker.io/grafana/loki:3.1.0`, `docker.io/grafana/alloy:v1.3.0`
- `quay.io/oauth2-proxy/oauth2-proxy:v7.8.1`
- `quay.io/prometheus-operator/*`, `quay.io/prometheus/*`, `docker.io/grafana/grafana:*`
- `goharbor/harbor-*:*` (core, portal, registry, jobservice, trivy, exporter)
- `docker.io/minio/minio:*`, `docker.io/minio/mc:*`
- `curlimages/curl` (used by `deploy_check_pod`)
- Custom operator images: `node-labeler`, `storage-autoscaler`, `rancher-ca-sync`
- `alpine:3.21` (used in Traefik init containers)

### 3.4 Terraform Provider Binaries

Already set up at `/home/rocky/terraform-providers/` with a `.terraformrc` filesystem mirror:
- `rancher/rancher2` v13.1.4
- `harvester/harvester` v0.6.7
- `hashicorp/null` v3.2.4

### 3.5 RPM Packages (for cloud-init)

Already supported via `PRIVATE_ROCKY_REPO_URL` and `PRIVATE_RKE2_REPO_URL`.

### 3.6 Binaries and CRDs

Already supported via `BINARY_URL_*`, `GATEWAY_API_CRD_URL`, `ARGO_ROLLOUTS_PLUGIN_URL`, `CRD_SCHEMA_BASE_URL` overrides.

## 4. New `.env` Configuration Variables

### 4.1 Bootstrap Registry Configuration

```bash
# Bootstrap registry — pre-existing external registry used BEFORE in-cluster Harbor exists.
# Required when AIRGAPPED=true. Must contain all RKE2 system images, Helm charts (OCI),
# and application images needed for Phases 0-4.
# Format: hostname[:port] (no protocol prefix, no trailing slash)
BOOTSTRAP_REGISTRY=""

# Optional: CA certificate PEM for the bootstrap registry (if self-signed TLS)
BOOTSTRAP_REGISTRY_CA_PEM=""

# Optional: username/password for bootstrap registry authentication
BOOTSTRAP_REGISTRY_USERNAME=""
BOOTSTRAP_REGISTRY_PASSWORD=""
```

### 4.2 Relationship Between Variables

- `BOOTSTRAP_REGISTRY` — used by RKE2 containerd (system-default-registry) and Helm during Phases 0-4
- `UPSTREAM_PROXY_REGISTRY` — used by Harbor proxy-cache projects (Phase 4) to chain upstream pulls
- In many deployments, `BOOTSTRAP_REGISTRY == UPSTREAM_PROXY_REGISTRY`

## 5. Changes to `cluster/cluster.tf`

### 5.1 system-default-registry Must Point to Bootstrap Registry

**Current** (line 297):
```hcl
var.airgapped ? { "system-default-registry" = "harbor.${var.domain}" } : {}
```

**Change**:
```hcl
var.airgapped ? { "system-default-registry" = var.bootstrap_registry } : {}
```

### 5.2 Containerd Registries Configuration

When `var.airgapped` is true, configure containerd mirrors pointing all upstream registries to the bootstrap registry during initial provisioning:

```hcl
dynamic "mirrors" {
  for_each = var.airgapped ? toset(["docker.io", "quay.io", "ghcr.io", "gcr.io",
                                    "registry.k8s.io", "docker.elastic.co"]) : toset([])
  content {
    hostname  = mirrors.value
    endpoints = ["https://${var.bootstrap_registry}"]
    rewrites  = { "^(.*)$" = "${mirrors.value}/$1" }
  }
}
```

### 5.3 New Terraform Variables

```hcl
variable "bootstrap_registry" {
  description = "Pre-existing container registry for airgapped bootstrap"
  type        = string
  default     = ""
}

variable "bootstrap_registry_ca_pem" {
  description = "PEM-encoded CA cert for bootstrap registry TLS"
  type        = string
  default     = ""
  sensitive   = true
}

variable "bootstrap_registry_username" {
  type    = string
  default = ""
}

variable "bootstrap_registry_password" {
  type      = string
  default   = ""
  sensitive = true
}
```

## 6. Changes to `scripts/lib.sh`

### 6.1 New Variables in `generate_or_load_env()`

Add defaults, exports, TF_VAR bridges, and .env save entries for all BOOTSTRAP_REGISTRY_* variables.

### 6.2 Update `validate_airgapped_prereqs()`

Add check that `BOOTSTRAP_REGISTRY` is set when `AIRGAPPED=true`.

### 6.3 Update `configure_rancher_registries()` — The Transition

Extend the Phase 4 transition to also update `system-default-registry` from bootstrap to `harbor.${DOMAIN}`:

```json
{
  "spec": {
    "rkeConfig": {
      "machineGlobalConfig": {
        "system-default-registry": "harbor.${DOMAIN}"
      },
      "registries": {
        "configs": { ... },
        "mirrors": { ... }
      }
    }
  }
}
```

## 7. Changes to `scripts/deploy-cluster.sh`

### Phases 0-3: No Script Changes

All bootstrap registry logic is handled by Terraform variables and cloud-init templates.

### Phase 4: Harbor — The Transition Phase

1. Deploy Harbor (images from bootstrap registry)
2. Configure Harbor Gateway + HTTPRoute + TLS
3. `configure_harbor_projects()` — proxy-cache projects (via `UPSTREAM_PROXY_REGISTRY`)
4. `configure_rancher_registries()` — patches cluster to use Harbor mirrors + updates system-default-registry
5. Wait for rolling restart
6. Push operator images

If `UPSTREAM_PROXY_REGISTRY == BOOTSTRAP_REGISTRY`, Harbor proxy-cache naturally becomes a pull-through cache. No explicit seeding needed.

### Phases 5+: No Changes

Everything operates through Harbor after Phase 4.

## 8. Changes to `scripts/precheck.sh`

Add bootstrap registry connectivity check, Terraform provider mirror validation, and extended `--fetch-list` for bootstrap content.

## 9. New Script: `scripts/prepare-bootstrap-registry.sh`

Populates the bootstrap registry from an online machine:
1. Download RKE2 system images list
2. Use `crane` to copy all system images
3. Pull and push Helm charts as OCI artifacts
4. Copy all Phase 0-4 application images
5. Validate completeness

## 10. Transition Logic

```
Phase 0-3: cluster runs with bootstrap registry
Phase 4:   Harbor deployed → proxy-cache configured → registries patched → rolling restart
Phase 4+:  All pulls go through Harbor → bootstrap registry (via proxy-cache) → images
```

### Rollback Safety

If Harbor goes down after transition, mitigations:
- Harbor is HA (2 replicas)
- Critical images cached on nodes from bootstrap phase
- Can revert registries patch to point back to bootstrap registry

### Terraform State Considerations

After transition, `system-default-registry` in TF state still says bootstrap. Options:
- Accept drift (use `lifecycle.ignore_changes`)
- Update TF variable and re-apply

## 11. Implementation Sequence

1. `.env.example` and `lib.sh` — Add BOOTSTRAP_REGISTRY variables
2. `lib.sh` `validate_airgapped_prereqs()` — Add validation
3. `cluster/variables.tf` — Add new variables
4. `cluster/cluster.tf` — Change system-default-registry, extend registries block
5. `cluster/machine_config.tf` — Add bootstrap registry CA to cloud-init
6. `lib.sh` `configure_rancher_registries()` — Extend for transition
7. `scripts/precheck.sh` — Add bootstrap registry checks
8. `scripts/prepare-bootstrap-registry.sh` — New script
9. `docs/airgapped-mode.md` — Full documentation update
10. Testing

## 12. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Rancher provider doesn't support mirrors+rewrites | Fall back to cloud-init write_files |
| system-default-registry change causes node downtime | Rolling update is sequential; images pre-cached |
| Harbor proxy-cache can't reach bootstrap registry | Verify network path before transition |
| Terraform state drift after API patch | Add to lifecycle.ignore_changes |
| Bootstrap registry goes down during Phase 0-3 | Document HA requirements |
| Different CA chains for bootstrap vs Harbor | Distribute both CAs in cloud-init |
