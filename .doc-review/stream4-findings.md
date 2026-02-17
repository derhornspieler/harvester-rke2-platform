# Stream 4 Findings: Security + Monitoring Documentation Review

**Reviewer**: Claude Opus 4.6
**Date**: 2026-02-17
**Files reviewed**:
- `docs/engineering/security-architecture.md`
- `docs/engineering/monitoring-observability.md`

**Ground truth sources checked**:
- `scripts/setup-keycloak.sh`, `scripts/deploy-cluster.sh`, `scripts/lib.sh`
- `services/monitoring-stack/prometheus/configmap.yaml` (scrape jobs + alert rules)
- `services/monitoring-stack/grafana/deployment.yaml` (dashboard volumes)
- `services/monitoring-stack/grafana/configmap-dashboard-provider.yaml` (folder config)
- `services/monitoring-stack/oauth2-proxy-redis/` (all 3 manifests)
- `services/monitoring-stack/loki/configmap.yaml`, `loki/statefulset.yaml`
- `services/monitoring-stack/alloy/configmap.yaml`
- `services/monitoring-stack/alertmanager/configmap.yaml`
- `services/monitoring-stack/kustomization.yaml`
- `services/vault/vault-values.yaml`
- `services/rbac/*.yaml`
- `services/monitoring-stack/grafana/configmap-dashboard-*.yaml` (25 ConfigMaps)

---

## SECURITY-ARCHITECTURE.MD FINDINGS

### Finding S1: EtcdHighLatency threshold is wrong (INCORRECT)
- **Location**: Section 3 Alert Rules, kubernetes-alerts group
- **Doc says**: EtcdHighLatency WAL fsync p99 > 0.5s
- **Ground truth** (`prometheus/configmap.yaml` line 602): `> 1` (1.0 seconds)
- **Fix**: Change 0.5s to 1s

### Finding S2: EtcdHighCommitDuration threshold is wrong (INCORRECT)
- **Location**: Section 3 Alert Rules (referenced in monitoring doc)
- **Doc says**: Backend commit p99 > 0.25s
- **Ground truth** (`prometheus/configmap.yaml` line 611): `> 0.5` (0.5 seconds)
- **Fix**: Change 0.25s to 0.5s

### Finding S3: EtcdHighLatency "for" duration is wrong (INCORRECT)
- **Location**: monitoring-observability.md, kubernetes-alerts group
- **Doc says**: for: 10m
- **Ground truth** (`prometheus/configmap.yaml` line 603): `for: 15m`
- **Fix**: Change 10m to 15m

### Finding S4: EtcdHighCommitDuration "for" duration is wrong (INCORRECT)
- **Location**: monitoring-observability.md, kubernetes-alerts group
- **Doc says**: for: 10m
- **Ground truth** (`prometheus/configmap.yaml` line 612): `for: 15m`
- **Fix**: Change 10m to 15m

### Finding S5: Security doc OIDC client count states 14 -- CORRECT
- **Ground truth**: `setup-keycloak.sh` creates: grafana, argocd, harbor, vault, mattermost, kasm, gitlab, kubernetes (public), prometheus-oidc, alertmanager-oidc, hubble-oidc, traefik-dashboard-oidc, rollouts-oidc, rancher = 14 clients
- **Status**: Matches doc

### Finding S6: User groups count -- doc says 8, script comment says 7
- **Doc**: Lists 8 groups: platform-admins, harvester-admins, rancher-admins, infra-engineers, network-engineers, senior-developers, developers, viewers
- **Ground truth** (`setup-keycloak.sh` line 713): `groups=("platform-admins" "harvester-admins" "rancher-admins" "infra-engineers" "network-engineers" "senior-developers" "developers" "viewers")` = 8 groups
- **Script header comment** (line 4): "Creates user groups with role mappings (7 groups)" -- this header is WRONG, but our doc is correct with 8 groups
- **Status**: Doc is CORRECT (8 groups)

### Finding S7: RBAC section missing Kubernetes OIDC RBAC manifests
- **Location**: Section 8, RBAC Architecture
- **Missing**: The doc has no mention of the Kubernetes OIDC-based RBAC manifests in `services/rbac/`:
  - `platform-admins-crb.yaml` (platform-admins -> cluster-admin)
  - `infra-engineers-cr.yaml` + `infra-engineers-crb.yaml` (custom ClusterRole)
  - `viewers-crb.yaml` (viewers -> view)
  - `developer-rolebinding-template.yaml` (developers + senior-developers -> edit, per-namespace)
- **Fix**: Add a new subsection documenting OIDC-based K8s RBAC

---

## MONITORING-OBSERVABILITY.MD FINDINGS

### Finding M1: Scrape job count is wrong (INCORRECT)
- **Location**: Section 3, heading says "31 total"
- **Ground truth** (`prometheus/configmap.yaml`): Jobs are numbered 1-30, with job 30 being `grafana`
  - 1: prometheus, 2: kubernetes-apiservers, 3: kubelet, 4: cadvisor, 5: etcd, 6: cilium-agent, 6b: hubble-relay, 7: coredns, 8: kube-scheduler, 9: kube-controller-manager, 10: node-exporter, 11: kube-state-metrics, 12: kubernetes-service-endpoints, 13: kubernetes-pods, 14: vault, 15: cert-manager, 16: traefik, 17: cnpg-controller, 18: cnpg-postgresql, 19: alloy, 20: loki, 21: gitlab-exporter, 22: argocd, 23: argo-rollouts, 24: harbor, 25: keycloak, 26: mattermost, 27: alertmanager, 28: oauth2-proxy, 29: redis-exporter, 30: grafana = 30 jobs (31 entries if counting 6b separately)
- **Fix**: Change "31 total" to "30 total" (or "31 entries" counting 6b), and add missing jobs 29 (redis-exporter) and 30 (grafana) to the table

### Finding M2: Missing scrape jobs 29 (redis-exporter) and 30 (grafana) from table
- **Location**: Section 3, Scrape Jobs table
- **Doc**: Table ends at job 28 (oauth2-proxy)
- **Ground truth**: configmap.yaml has job 29 `redis-exporter` (pod SD, monitoring ns, port 9121) and job 30 `grafana` (endpoints SD, monitoring ns)
- **Fix**: Add these two rows to the table

### Finding M3: Alert rule groups count is wrong (INCORRECT)
- **Location**: Section 3, "organized into 13 groups"
- **Ground truth**: configmap.yaml has 16 groups: node-alerts, kubernetes-alerts, vault-alerts, certmanager-alerts, gitlab-alerts, postgresql-alerts, monitoring-self-alerts, traefik-alerts, cilium-alerts, argocd-alerts, harbor-alerts, keycloak-alerts, mattermost-alerts, oauth2-proxy-alerts, security-alerts, redis-alerts, operator-alerts = 17 groups
- Wait, let me recount: (1) node-alerts, (2) kubernetes-alerts, (3) vault-alerts, (4) certmanager-alerts, (5) gitlab-alerts, (6) postgresql-alerts, (7) monitoring-self-alerts, (8) traefik-alerts, (9) cilium-alerts, (10) argocd-alerts, (11) harbor-alerts, (12) keycloak-alerts, (13) mattermost-alerts, (14) oauth2-proxy-alerts, (15) security-alerts, (16) redis-alerts, (17) operator-alerts = 17 groups
- **Fix**: Change "13 groups" to "17 groups"

### Finding M4: Missing alert groups: redis-alerts and operator-alerts
- **Location**: Section 3, Alert Rules
- **Doc**: Does not document the `redis-alerts` group or `operator-alerts` group
- **Ground truth**:
  - `redis-alerts`: RedisDown (up{job="redis-exporter"}==0, 2m, critical), RedisHighMemory (>80% of max, 10m, warning)
  - `operator-alerts`: StorageAutoscalerDown (absent, 5m, warning), StorageAutoscalerPollErrors (>5 in 15m, 5m, warning), NodeLabelerDown (absent, 5m, warning), NodeLabelerErrors (>0 in 15m, 5m, warning), ArgoRolloutsDown (up==0, 5m, warning)
- **Fix**: Add these two groups to the doc

### Finding M5: Missing GrafanaDown alert in monitoring-self-alerts group
- **Location**: Section 3, monitoring-self-alerts group
- **Doc**: Lists 5 alerts (PrometheusTargetDown, PrometheusTSDBCompactionsFailing, PrometheusStorageAlmostFull, LokiDown, AlloyDown)
- **Ground truth**: Also has `GrafanaDown` (up{job="grafana"}==0, 5m, warning)
- **Fix**: Add GrafanaDown to the table

### Finding M6: CiliumAgentDown alert expression is documented incorrectly
- **Location**: monitoring-observability.md, cilium-alerts group
- **Doc says**: `up{job="cilium-agent"} == 0`
- **Ground truth** (`prometheus/configmap.yaml` line 859): `up{job="hubble-relay"} == 0` -- the alert monitors hubble-relay, not cilium-agent directly (because cilium-agent port 9962 is blocked by host firewall)
- **Fix**: Update expression to match actual

### Finding M7: Dashboard inventory has WRONG folder names and count (MAJOR)
- **Location**: Section 11, Dashboard Inventory
- **Doc folder names**: RKE2, Kubernetes, Loki, Services, Networking, Security, Operations, CI/CD, Home (9 folders)
- **Ground truth** (configmap-dashboard-provider.yaml): Home, Platform, Networking, Services, Security, Observability (6 folders)
- **Ground truth** (deployment.yaml mounts): home, platform, networking, services, security, observability
- **Doc lists 24 dashboards but actual count**: 25 dashboard ConfigMaps
  - Missing from doc: `firing-alerts` (Home folder), `node-labeler` (Platform folder), `redis-overview` (Services folder)
  - Doc lists dashboards in WRONG folders (e.g., etcd in "RKE2" but actual is "Platform", loki in "Loki" but actual is "Observability")
  - Doc invents folders that don't exist: "RKE2", "Kubernetes", "Loki", "Operations", "CI/CD"
  - Doc lists dashboards that don't exist as ConfigMaps: `rke-cluster`, `cluster-monitoring`, `pod-monitoring`, `cluster-security`, `cluster-operations`, `pipelines-overview`
- **Fix**: Complete rewrite of dashboard inventory section

### Finding M8: Dashboard count by folder table is completely wrong
- **Location**: Section 11
- **Actual counts by folder**: Home=2, Platform=5, Networking=3, Services=7, Security=4, Observability=2 -- but wait, let me recount from deployment.yaml:
  - Home: home-overview.json, firing-alerts.json = 2
  - Platform: etcd.json, apiserver-performance.json, node-detail.json, pv-usage.json, node-labeler.json = 5
  - Networking: traefik-overview.json, coredns.json, cilium-overview.json = 3
  - Services: vault-overview.json, cnpg-cluster.json, gitlab-overview.json, argocd-overview.json, harbor-overview.json, mattermost-overview.json, argo-rollouts-overview.json, redis-overview.json = 8
  - Security: keycloak-overview.json, cert-manager.json, security-advanced.json, oauth2-proxy-overview.json = 4
  - Observability: loki-logs.json, loki-stack.json = 2
  - Total: 2+5+3+8+4+2 = 24 dashboards (but 25 ConfigMaps because of the provider ConfigMap)
- **Fix**: Replace entire folder/count table

### Finding M9: Redis session store for oauth2-proxy NOT documented in monitoring doc
- **Location**: The monitoring doc has no mention of the Redis subservice
- **Ground truth**: `services/monitoring-stack/oauth2-proxy-redis/` contains:
  - `secret.yaml`: oauth2-proxy-redis-credentials
  - `replication.yaml`: RedisReplication CRD (3 replicas, OpsTree operator, redis v7.0.15, redis-exporter sidecar)
  - `sentinel.yaml`: RedisSentinel CRD (3 sentinels, HA failover)
- **Fix**: Add Redis session store section or at least mention it in the overview table

---

## SUMMARY OF REQUIRED EDITS

### security-architecture.md
1. (S7) Add OIDC-based Kubernetes RBAC section listing platform-admins, infra-engineers, viewers CRBs and developer template

### monitoring-observability.md
1. (M1) Fix scrape job count: "31 total" -> "30 total"
2. (M2) Add scrape jobs 29 (redis-exporter) and 30 (grafana)
3. (M3) Fix alert group count: "13 groups" -> "17 groups"
4. (M4) Add redis-alerts and operator-alerts groups
5. (M5) Add GrafanaDown to monitoring-self-alerts
6. (M6) Fix CiliumAgentDown expression
7. (M7/M8) Rewrite entire dashboard inventory with correct folders (6 folders: Home, Platform, Networking, Services, Security, Observability), correct dashboard names, and correct counts (24 dashboards total)
8. (M9) Add Redis session store section to overview
9. (S1) Fix EtcdHighLatency threshold (0.5s -> 1s)
10. (S2) Fix EtcdHighCommitDuration threshold (0.25s -> 0.5s)
11. (S3/S4) Fix EtcdHighLatency and EtcdHighCommitDuration "for" durations (10m -> 15m)

---

## EDITS APPLIED

All fixes have been applied to:
- `/home/rocky/data/rke2-cluster-via-rancher/docs/engineering/security-architecture.md`
- `/home/rocky/data/rke2-cluster-via-rancher/docs/engineering/monitoring-observability.md`

### security-architecture.md changes:
1. Added OIDC-based Kubernetes RBAC section (platform-admins, infra-engineers, viewers CRBs + developer template)
2. Added Related Files entries for services/rbac/ manifests

### monitoring-observability.md changes:
1. Fixed scrape job count from 31 to 30
2. Added scrape jobs 29 (redis-exporter) and 30 (grafana) to table
3. Fixed alert group count from 13 to 17
4. Fixed EtcdHighLatency threshold (0.5s -> 1s) and duration (10m -> 15m)
5. Fixed EtcdHighCommitDuration threshold (0.25s -> 0.5s) and duration (10m -> 15m)
6. Fixed CiliumAgentDown expression from `up{job="cilium-agent"}` to `up{job="hubble-relay"}`
7. Added GrafanaDown alert to monitoring-self-alerts group
8. Added redis-alerts group (RedisDown, RedisHighMemory)
9. Added operator-alerts group (StorageAutoscalerDown, StorageAutoscalerPollErrors, NodeLabelerDown, NodeLabelerErrors, ArgoRolloutsDown)
10. Added Redis session store component to overview table
11. Added new Section 10: Redis Session Store (oauth2-proxy) with full details
12. Rewrote dashboard folder structure: 9 folders -> 6 folders (Home, Platform, Networking, Services, Security, Observability)
13. Rewrote complete dashboard table with correct 24 dashboards in correct folders
14. Added 3 missing dashboards: Firing Alerts, Node Labeler, Redis Overview
15. Removed 6 phantom dashboards that had no ConfigMaps: rke-cluster, cluster-monitoring, pod-monitoring, cluster-security, cluster-operations, pipelines-overview
16. Fixed dashboard count by folder table
17. Added Redis manifests to Related Files
18. Updated Table of Contents with new section numbering

STATUS: COMPLETE
