# Stream 2 Findings: Architecture & Terraform Documentation Review

**Reviewed**: 2026-02-17
**Files reviewed**:
- `docs/engineering/system-architecture.md`
- `docs/engineering/terraform-infrastructure.md`

**Ground truth files compared**:
- `cluster/cluster.tf`, `cluster/variables.tf`, `cluster/machine_config.tf`, `cluster/image.tf`
- `cluster/efi.tf`, `cluster/outputs.tf`, `cluster/versions.tf`, `cluster/providers.tf`
- `cluster/cloud_credential.tf`, `scripts/deploy-cluster.sh`, `services/` directory

---

## TERRAFORM-INFRASTRUCTURE.md FINDINGS

### F1: Variable count wrong (44 vs 54) [CRITICAL]
- **Location**: Line 44 in file overview
- **Doc says**: "All input variables (44 variables)"
- **Actual**: 54 variables in `variables.tf`
- **Root cause**: 10 variables added in recent commits (airgapped, autoscaler behavior, dockerhub) not reflected in doc

### F2: Missing variable sections -- Airgapped Mode [CRITICAL]
- **Missing variables**: `airgapped` (bool, default false), `private_rocky_repo_url` (string, default ""), `private_rke2_repo_url` (string, default ""), `private_ca_pem` (string, sensitive, default "")
- **Source**: variables.tf lines 350-373
- **Impact**: Airgapped deployment (commit 97c4173) entirely undocumented

### F3: Missing variable section -- Cluster Autoscaler Behavior [CRITICAL]
- **Missing variables**: `autoscaler_scale_down_unneeded_time` (default "30m0s"), `autoscaler_scale_down_delay_after_add` (default "15m0s"), `autoscaler_scale_down_delay_after_delete` (default "30m0s"), `autoscaler_scale_down_utilization_threshold` (default "0.5")
- **Source**: variables.tf lines 260-282
- **Impact**: Autoscaler tuning variables undocumented

### F4: Missing variable section -- Docker Hub Auth [MODERATE]
- **Missing variables**: `dockerhub_username` (string, default ""), `dockerhub_token` (string, sensitive, default "")
- **Source**: variables.tf lines 288-299
- **Impact**: Docker Hub rate-limit workaround undocumented

### F5: Missing resource -- rancher2_secret_v2.dockerhub_auth [MODERATE]
- **Source**: cluster.tf lines 6-15
- **Impact**: The dockerhub auth secret resource is not documented anywhere in the terraform doc

### F6: Missing cluster-level annotations [MODERATE]
- **Source**: cluster.tf lines 22-27
- **Doc omits**: The `rancher2_cluster_v2.rke2` resource has 4 cluster-level annotations for autoscaler behavior that are not shown in the cluster.tf documentation

### F7: Missing machine_global_config setting -- ingress-controller [MINOR]
- **Doc says**: machine_global_config only has cni, disable-kube-proxy, disable, etcd-expose-metrics, kube-apiserver-arg, kube-scheduler-arg, kube-controller-manager-arg
- **Actual**: Also has `"ingress-controller" = "traefik"` (cluster.tf line 278)

### F8: Missing machine_global_config -- airgapped conditional merge [MODERATE]
- **Source**: cluster.tf lines 273-291 uses `merge()` with conditional `system-default-registry`
- **Doc shows**: plain `yamlencode({...})` without the `merge()` pattern or the airgapped conditional

### F9: Missing registries block [MODERATE]
- **Source**: cluster.tf lines 296-301
- **Doc omits**: The `registries { configs { hostname = "docker.io" ... } }` block entirely

### F10: Traefik chart_values incomplete [CRITICAL]
- **Doc shows only**: service, providers, logs, tracing
- **Missing from doc**:
  - `ports.web.redirections` (HTTP-to-HTTPS redirect)
  - `volumes` (vault-root-ca ConfigMap, combined-ca emptyDir)
  - `deployment.initContainers` (combine-ca init container for Vault CA trust)
  - `env` (SSL_CERT_FILE pointing to combined CA bundle)
  - `additionalArguments` (api.insecure=true, readTimeout/writeTimeout=1800s on both entrypoints)
- **Impact**: Major Traefik features (TLS trust, HTTP redirect, timeouts) undocumented

---

## SYSTEM-ARCHITECTURE.md FINDINGS

### F11: Dashboard count wrong (says 24, actual 25; table has 28 entries) [MODERATE]
- **Location**: Section 9, line 1017 heading + line 969
- **Doc heading**: "24 Dashboards"
- **Actual dashboard configmaps**: 25 (24 actual dashboards + 1 provider meta-config)
- **Doc table**: Lists 28 entries, several of which do not correspond to actual files
- **Dashboards in doc but NOT in files**:
  - "RKE2 Cluster" -- no corresponding configmap
  - "Kubernetes RKE Cluster" -- no corresponding configmap
  - "Cluster Monitoring" -- no corresponding configmap
  - "Pod Monitoring" -- no corresponding configmap
  - "Security" -- no corresponding configmap (only security-advanced exists)
  - "Operations" -- no corresponding configmap
  - "Pipelines" -- no corresponding configmap
- **Dashboards in files but NOT in doc**:
  - `configmap-dashboard-firing-alerts.yaml` (Firing Alerts)
  - `configmap-dashboard-node-labeler.yaml` (Node Labeler)
  - `configmap-dashboard-redis.yaml` (Redis)

### F12: Missing airgapped mode references in architecture doc [MODERATE]
- The system architecture doc makes no mention of airgapped deployment mode
- Commit 97c4173 added full airgapped deployment support
- The architecture should at minimum note the airgapped capability in the system overview or as an appendix note

### F13: Missing cluster-level autoscaler behavior annotations in architecture doc [MINOR]
- Section 8 (Autoscaling Architecture) documents pool-level min/max annotations
- Does not mention cluster-level autoscaler behavior annotations (scale-down-unneeded-time, delay-after-add, delay-after-delete, utilization-threshold)

### F14: Missing Docker Hub registry auth in architecture doc [MINOR]
- No mention of the Docker Hub authenticated pull workaround in the cluster config

### F15: Traefik config in architecture doc incomplete [MINOR]
- Section 4 mentions readTimeout=1800s, writeTimeout=1800s correctly
- Does not mention HTTP-to-HTTPS redirect, Vault CA trust injection (volumes/initContainers/env), or api.insecure=true

### F16: Phase 1 in architecture doc missing Cluster Autoscaler and MariaDB Operator [MINOR]
- Appendix B Phase 1 diagram lists: cert-manager, CNPG Operator, OpsTree Redis Operator, Node Labeler, Cluster Autoscaler, MariaDB Operator
- deploy-cluster.sh confirms MariaDB Operator is installed conditionally (for LibreNMS)
- This matches. No fix needed -- noted for completeness.

---

## SUMMARY

| Severity | Count | Category |
|----------|-------|----------|
| CRITICAL | 4 | F1, F2, F3, F10 |
| MODERATE | 6 | F4, F5, F6, F8, F9, F11, F12 |
| MINOR | 5 | F7, F13, F14, F15, F16 |

## FIXES APPLIED

### terraform-infrastructure.md
- **F1**: Fixed variable count from 44 to 54
- **F2**: Added "Airgapped Mode" variable section (4 variables: airgapped, private_rocky_repo_url, private_rke2_repo_url, private_ca_pem)
- **F3**: Added "Cluster Autoscaler Behavior" variable section (4 variables)
- **F4**: Added "Docker Hub Auth" variable section (2 variables)
- **F5**: Added new section 4.6 documenting rancher2_secret_v2.dockerhub_auth resource
- **F6**: Added "Cluster-Level Autoscaler Annotations" subsection with annotation table
- **F7**: Added `ingress-controller = "traefik"` to machine_global_config code and table
- **F8**: Updated machine_global_config to show merge() pattern and airgapped conditional, added system-default-registry to table
- **F9**: Added "Private Registry Auth" subsection documenting the registries block
- **F10**: Expanded Traefik chart_values to include ports.web.redirections, volumes, deployment.initContainers, env (SSL_CERT_FILE), additionalArguments, and explanatory note about Vault CA trust
- Added airgapped cloud-init note in Section 5.1

### system-architecture.md
- **F11**: Replaced dashboard table with accurate 24-row table matching actual configmap files, added ConfigMap column for traceability. Removed phantom dashboards (RKE2 Cluster, Kubernetes RKE Cluster, Cluster Monitoring, Pod Monitoring, Security, Operations, Pipelines). Added missing dashboards (Firing Alerts, Node Labeler, Redis).
- **F12**: Added airgapped deployment to the platform capabilities list in Section 1
- **F13**: Added "Cluster Autoscaler: Scale-Down Behavior" subsection with annotation table in Section 8
- **F14**: Added "Registry Configuration" subsection in Section 3 documenting Docker Hub auth and airgapped system-default-registry
- **F15**: Updated Traefik mermaid diagram to mention HTTP-to-HTTPS redirect and Vault CA trust. Added callout notes below routing table.

STATUS: COMPLETE
