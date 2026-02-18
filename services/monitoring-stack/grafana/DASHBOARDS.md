# Grafana Dashboard Reference

Complete per-panel metric reference for all 24 Grafana dashboards in the RKE2 monitoring stack. Organized by folder as shown in the Grafana sidebar.

> **Data sources**: All dashboards use `prometheus` (PromQL) unless noted. Log panels use `loki` (LogQL). Template variables like `$cluster`, `$node`, `$namespace` are populated from dropdown selectors at the top of each dashboard.

---

## Home

### Cluster Home

| | |
|---|---|
| **UID** | `home-overview` |
| **ConfigMap** | `grafana-dashboard-home` |
| **Tags** | `home`, `overview`, `rke2`, `noc` |
| **Description** | NOC/SOC command center for the RKE2 cluster. Resource utilization, service health, GatewayAPI traffic, and operational metrics. |

**Cluster Resources (stat panels)**

| Panel | Metric(s) | Unit | What It Shows |
|-------|-----------|------|---------------|
| CPU % | `node_cpu_seconds_total{mode="idle"}` | percent | Average CPU utilization across all nodes (100 - idle%) |
| Memory % | `node_memory_MemAvailable_bytes`, `node_memory_MemTotal_bytes` | percent | Cluster-wide memory utilization |
| Storage % | `node_filesystem_avail_bytes`, `node_filesystem_size_bytes` | percent | Average root filesystem usage across all nodes |
| Nodes Ready | `kube_node_status_condition{condition="Ready",status="true"}` | count | Kubernetes nodes in Ready state |
| Total Pods | `kube_pod_info` | count | Total pods across all namespaces |
| Pods Not Ready | `kube_pod_status_phase{phase=~"Pending\|Unknown\|Failed"}` | count | Pods in non-running phases |
| Firing Alerts | `ALERTS{alertstate="firing"}` | count | Prometheus alerts currently firing |
| Traefik RPS | `traefik_entrypoint_requests_total` | reqps | Total HTTP request rate across all entrypoints |
| Active Connections | `traefik_open_connections` | count | Open connections across all entrypoints |

**Platform Services (stat panels)**

| Panel | Metric(s) | What It Shows |
|-------|-----------|---------------|
| etcd | `up{job="etcd"}` | etcd cluster members responding (expected: 3) |
| API Server | `up{job="kubernetes-apiservers"}` | API server instances (expected: 3) |
| Traefik | `up{job="traefik"}` | Traefik GatewayAPI controller pods |
| CoreDNS | `up{job="coredns"}` | CoreDNS pods responding (expected: 2) |
| Cilium | `up{job="hubble-relay"}` | Hubble-relay responding |
| Prometheus | `up{job="prometheus"}` | Prometheus self-scrape target |
| Loki | `up{job="loki"}` | Loki log aggregation service |
| Alertmanager | `up{job="alertmanager"}` | Alertmanager instances |

**Application Services (stat panels)**

| Panel | Metric(s) | What It Shows |
|-------|-----------|---------------|
| Keycloak | `up{job="keycloak"}` | Keycloak IAM instances (expected: 2) |
| oauth2-proxy | `kube_deployment_status_replicas_ready{deployment=~"oauth2-proxy.*"}` | ForwardAuth deployments with ready replicas (expected: 5) |
| cert-manager | `up{job="cert-manager"}` | cert-manager controller |
| Grafana | `up{job="grafana"}` | Grafana dashboard service |
| Vault | `up{job="vault"}` | HashiCorp Vault instances (expected: 3) |
| GitLab | `up{job="gitlab-exporter"}` | GitLab service endpoints |
| ArgoCD | `up{job="argocd"}` | ArgoCD components |
| Harbor | `up{job="harbor"}` | Harbor registry components |
| Mattermost | `kube_deployment_status_replicas_ready{deployment=~"mattermost.*"}` | Mattermost deployment ready replicas |
| PostgreSQL | `up{job="cnpg-postgresql"}` | CloudNativePG instances |
| Redis | `up{job="redis-exporter"}` | Redis session store (expected: 3) |
| Argo Rollouts | `up{job="argo-rollouts"}` | Argo Rollouts controller instances |
| Storage Autoscaler | `up{job="kubernetes-pods",namespace="storage-autoscaler"}` | PVC autoscaler controller |
| Node Labeler | `up{job="kubernetes-pods",namespace="node-labeler"}` | Node labeler controller |

**GatewayAPI Traffic (stat panels)**

| Panel | Metric(s) | Unit | What It Shows |
|-------|-----------|------|---------------|
| Entrypoint RPS | `traefik_entrypoint_requests_total` | reqps | Total HTTP request rate |
| TLS RPS | `traefik_entrypoint_requests_tls_total` | reqps | TLS-terminated request rate |
| Error Rate % | `traefik_service_requests_total{code=~"5.."}` | percent | Percentage of 5xx responses |
| Avg Latency | `traefik_entrypoint_request_duration_seconds_sum/count` | ms | Average request duration |
| Inbound Bytes/s | `traefik_entrypoint_requests_bytes_total` | Bps | Total inbound request bytes |
| Outbound Bytes/s | `traefik_entrypoint_responses_bytes_total` | Bps | Total outbound response bytes |

**Timeseries Panels**

| Panel | Metric(s) | Unit | What It Shows |
|-------|-----------|------|---------------|
| Cluster CPU by Node | `node_cpu_seconds_total{mode!="idle"}` | cores | CPU usage broken down by node |
| Cluster Memory by Node | `node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes` | bytes | Memory used per node |
| Traefik RPS by Service (Top 15) | `traefik_service_requests_total` | reqps | Request rate per backend service |
| Traefik Service Latency p99 | `traefik_service_request_duration_seconds_bucket` | s | 99th percentile latency per service |
| Container Restarts (1h) | `kube_pod_container_status_restarts_total` | count | Top 10 restarting containers |
| Disk Usage by Node | `node_filesystem_avail_bytes`, `node_filesystem_size_bytes` | percent | Root filesystem usage per node |
| PVC Usage Top 10 | `kubelet_volume_stats_used_bytes`, `kubelet_volume_stats_capacity_bytes` | percent | Highest PVC utilization |

---

### Firing Alerts

| | |
|---|---|
| **UID** | `firing-alerts` |
| **ConfigMap** | `grafana-dashboard-firing-alerts` |
| **Tags** | `alerts`, `home`, `noc` |
| **Description** | Dedicated view of all currently firing Prometheus alerts with severity breakdown, details table, and history. |

| Panel | Type | Metric(s) | What It Shows |
|-------|------|-----------|---------------|
| Total Firing | stat | `ALERTS{alertstate="firing"}` | Total alert count |
| Critical | stat | `ALERTS{alertstate="firing",severity="critical"}` | Critical severity count |
| Warning | stat | `ALERTS{alertstate="firing",severity="warning"}` | Warning severity count |
| Info | stat | `ALERTS{alertstate="firing",severity="info"}` | Info severity count |
| Alert Details | table | `ALERTS{alertstate="firing"}` | All firing alerts with full label details |
| Alert History | timeseries | `ALERTS{alertstate="firing"}` by alertname | Firing alert count over time |

---

## Platform

### etcd

| | |
|---|---|
| **UID** | `etcd-dashboard` |
| **ConfigMap** | `grafana-dashboard-etcd` |
| **Tags** | `platform`, `etcd`, `rke2` |
| **Description** | etcd cluster monitoring. Based on Grafana.com dashboard 3070. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| etcd Members Up | stat | `up{job="etcd"}` | count | Members responding |
| etcd has a leader | stat | `etcd_server_has_leader` | bool | Whether the cluster has elected a leader |
| etcd Leader Changes | stat | `etcd_server_leader_changes_seen_total` | count/1h | Leader elections in the last hour |
| Total DB Size | stat | `etcd_mvcc_db_total_size_in_bytes` | bytes | Total database size |
| Failed Proposals | stat | `etcd_server_proposals_failed_total` | count/1h | Failed raft proposals in the last hour |
| gRPC Rate | timeseries | `grpc_server_started_total{grpc_type="unary",job="etcd"}` | ops | Unary gRPC request rate by method |
| Active Streams | timeseries | `grpc_server_started_total - grpc_server_handled_total` | short | Bidi and server streams currently active |
| DB Size | timeseries | `etcd_mvcc_db_total_size_in_bytes` | bytes | Database size over time |
| Disk WAL Fsync Duration | timeseries | `etcd_disk_wal_fsync_duration_seconds_bucket` | s | p99 WAL fsync latency |
| Disk Backend Commit Duration | timeseries | `etcd_disk_backend_commit_duration_seconds_bucket` | s | p99 backend commit latency |
| Raft Proposals | timeseries | `etcd_server_proposals_committed_total`, `etcd_server_proposals_applied_total`, `etcd_server_proposals_pending`, `etcd_server_proposals_failed_total` | ops | Raft proposal rates by state |
| Client Traffic In | timeseries | `etcd_network_client_grpc_received_bytes_total` | Bps | Client gRPC bytes received |
| Client Traffic Out | timeseries | `etcd_network_client_grpc_sent_bytes_total` | Bps | Client gRPC bytes sent |
| Peer Traffic In | timeseries | `etcd_network_peer_received_bytes_total` | Bps | Peer replication bytes received |
| Peer Traffic Out | timeseries | `etcd_network_peer_sent_bytes_total` | Bps | Peer replication bytes sent |

---

### Control Plane

| | |
|---|---|
| **UID** | `apiserver-performance` |
| **ConfigMap** | `grafana-dashboard-apiserver` |
| **Tags** | `platform`, `apiserver`, `scheduler`, `controller-manager`, `rke2` |
| **Description** | API Server performance, scheduler latency, controller manager workqueue depth, and reconciliation rates. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| API Servers Up | stat | `up{job="kubernetes-apiservers"}` | count | API server instances responding |
| Request Rate | stat | `apiserver_request_total` | reqps | Total API request rate |
| Error Rate % | stat | `apiserver_request_total{code=~"5.."}` | percent | 5xx error percentage |
| Request Rate by Verb | timeseries | `apiserver_request_total` by verb | reqps | GET/LIST/WATCH/CREATE/UPDATE/DELETE rates |
| Request Rate by Resource | timeseries | `apiserver_request_total` by resource | reqps | Top 10 resources by request rate |
| Request Duration (p50/p90/p99) | timeseries | `apiserver_request_duration_seconds_bucket` | s | Latency percentiles by verb |
| Error Rate by Code | timeseries | `apiserver_request_total{code=~"[45].."}` by code | reqps | 4xx/5xx rates by status code |
| Active Requests | timeseries | `apiserver_current_inflight_requests` | short | In-flight request count |
| Webhook Admission Duration p99 | timeseries | `apiserver_admission_webhook_admission_duration_seconds_bucket` | s | Webhook latency by name |
| etcd Request Duration p99 | timeseries | `etcd_request_duration_seconds_bucket` | s | API server to etcd latency by operation |
| Audit Events | timeseries | `apiserver_audit_event_total` | ops | Audit event generation rate |
| Watch Events | timeseries | `apiserver_watch_events_total` | ops | Watch event dispatch rate |
| Scheduler Latency p99 | timeseries | `scheduler_scheduling_attempt_duration_seconds_bucket` | s | Scheduling attempt latency |
| Scheduler Pending Pods | timeseries | `scheduler_pending_pods` | short | Pods waiting to be scheduled |
| Controller Manager Workqueue Depth | timeseries | `workqueue_depth{job="kube-controller-manager"}` | short | Top 10 workqueues by depth |
| Controller Reconcile Rate | timeseries | `workqueue_adds_total{job="kube-controller-manager"}` | ops | Top 10 controllers by reconcile rate |

---

### Node Deep Dive

| | |
|---|---|
| **UID** | `node-deep-dive` |
| **ConfigMap** | `grafana-dashboard-node-detail` |
| **Tags** | `node`, `node-exporter`, `deep-dive` |
| **Description** | Deep-dive node monitoring with CPU, memory, disk, network, and filesystem metrics. |
| **Variables** | `$node` - select individual node |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Uptime | stat | `node_boot_time_seconds` | s | Time since last boot |
| CPU Cores | stat | `node_cpu_seconds_total{mode="idle"}` | short | Number of CPU cores |
| Total Memory | stat | `node_memory_MemTotal_bytes` | bytes | Total physical memory |
| Pod Count | stat | `kube_pod_info{node="$node"}` | count | Running pods on this node |
| CPU Usage % | gauge | `node_cpu_seconds_total{mode="idle"}` | percent | Current CPU utilization |
| Memory Usage % | gauge | `node_memory_MemAvailable_bytes`, `node_memory_MemTotal_bytes` | percent | Current memory utilization |
| Root Disk Usage % | gauge | `node_filesystem_avail_bytes`, `node_filesystem_size_bytes` | percent | Root filesystem utilization |
| CPU Usage by Mode | timeseries | `node_cpu_seconds_total` by mode | short | CPU time by mode (user/system/iowait/etc.) |
| Memory Breakdown | timeseries | `node_memory_MemTotal_bytes`, `MemAvailable_bytes`, `Cached_bytes`, `Buffers_bytes` | bytes | Memory allocation breakdown |
| Disk I/O | timeseries | `node_disk_read_bytes_total`, `node_disk_written_bytes_total` | Bps | Read/write throughput |
| Disk IOPS | timeseries | `node_disk_reads_completed_total`, `node_disk_writes_completed_total` | iops | I/O operations per second |
| Network Traffic | timeseries | `node_network_receive_bytes_total`, `node_network_transmit_bytes_total` | bps | Network rx/tx (excluding virtual interfaces) |
| Network Errors | timeseries | `node_network_receive_errs_total`, `node_network_transmit_errs_total` | short | Network error rates |
| System Load | timeseries | `node_load1`, `node_load5`, `node_load15` | short | 1/5/15 minute load averages |
| Filesystem Usage | table | `node_filesystem_size_bytes`, `node_filesystem_avail_bytes` | mixed | Per-mount filesystem capacity/usage/available |
| Top 10 Pod CPU Consumers | timeseries | `container_cpu_usage_seconds_total{node="$node"}` | short | Pods consuming the most CPU |

---

### Storage & PV Usage

| | |
|---|---|
| **UID** | `k8s-pv-usage` |
| **ConfigMap** | `grafana-dashboard-storage` |
| **Tags** | `platform`, `storage`, `persistent-volume`, `autoscaler` |
| **Description** | Persistent Volume usage monitoring with storage autoscaler metrics, PVC growth forecasting, and volume health tracking. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Total PVCs | stat | `kube_persistentvolumeclaim_info` | short | Total PVC count |
| PVCs Bound | stat | `kube_persistentvolumeclaim_status_phase{phase="Bound"}` | short | PVCs in Bound state |
| PVCs Pending | stat | `kube_persistentvolumeclaim_status_phase{phase="Pending"}` | short | PVCs stuck in Pending |
| Total PV Capacity | stat | `kube_persistentvolume_capacity_bytes` | bytes | Sum of all PV capacity |
| Autoscaler Controller Up | stat | `up{job="kubernetes-pods",namespace="storage-autoscaler"}` | bool | Autoscaler controller status |
| Managed PVCs | stat | `volume_autoscaler_pvc_usage_percent` | count | PVCs monitored by autoscaler |
| PVC Usage Overview | table | `kubelet_volume_stats_capacity_bytes`, `kubelet_volume_stats_used_bytes`, `kubelet_volume_stats_available_bytes` | mixed | Per-PVC capacity, used, available, usage% |
| Volume Usage % Over Time | timeseries | `kubelet_volume_stats_used_bytes / capacity_bytes` | percent | PVC usage trends |
| Volume Used Bytes Over Time | timeseries | `kubelet_volume_stats_used_bytes` | bytes | Absolute storage consumption |
| Inode Usage | table | `kubelet_volume_stats_inodes_used / inodes` | percent | Per-volume inode utilization |
| PV Reclaim Policy | table | `kube_persistentvolume_info` | - | PV info with reclaim policies |
| Volume Provisioner Activity | timeseries | `kube_persistentvolumeclaim_info`, `kube_persistentvolumeclaim_status_phase` | short | PVC count by namespace and phase |
| PVC Usage (Autoscaler View) | timeseries | `volume_autoscaler_pvc_usage_percent` | percent | Autoscaler-reported PVC usage |
| PVC Growth Forecast (7-day) | timeseries | `predict_linear(kubelet_volume_stats_used_bytes[7d], 7*24*3600)` | bytes | Predicted storage in 7 days (linear regression) |
| Poll Errors Over Time | timeseries | `volume_autoscaler_poll_errors_total` | ops | Autoscaler poll error rate |
| Reconcile Duration | timeseries | `volume_autoscaler_reconcile_duration_seconds_bucket` | s | Autoscaler reconcile loop p50/p99 |

---

## Networking

### Traefik GatewayAPI

| | |
|---|---|
| **UID** | `traefik-ingress-controller` |
| **ConfigMap** | `grafana-dashboard-traefik` |
| **Tags** | `traefik`, `ingress`, `platform` |
| **Description** | Traefik GatewayAPI controller monitoring with request rates, error rates, latency percentiles, and connection metrics. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Traefik Instances Up | stat | `up{job="traefik"}` | short | Controller pods responding |
| Total Entrypoints | stat | `traefik_entrypoint_requests_total` | short | Number of configured entrypoints |
| Active Services | stat | `traefik_service_requests_total` | short | Number of distinct backend services |
| Total Requests/sec | stat | `traefik_entrypoint_requests_total` | reqps | Aggregate request rate |
| Request Rate by Entrypoint | timeseries | `traefik_entrypoint_requests_total` by entrypoint | reqps | HTTP/HTTPS/metrics entrypoint rates |
| Request Rate by Status Code | timeseries | `traefik_service_requests_total` by code | reqps | 2xx/3xx/4xx/5xx distribution |
| Error Rate (4xx + 5xx) | timeseries | `traefik_service_requests_total{code=~"4..\|5.."}` | reqps | Combined client+server error rate |
| Request Duration (p50/p90/p99) | timeseries | `traefik_service_request_duration_seconds_bucket` | s | Latency percentiles |
| Open Connections | timeseries | `traefik_open_connections` | short | Active connections per entrypoint |
| Requests by Service (Top 10) | timeseries | `traefik_service_requests_total` by service | reqps | Busiest backend services |
| Service Error Rate % | timeseries | `traefik_service_requests_total{code=~"5.."}` / total | percent | 5xx percentage per service |
| TLS Connections | timeseries | `traefik_tls_certs_not_after` by tls_version | short | TLS version distribution |
| Config Reloads | timeseries | `traefik_config_reloads_total` | ops | Dynamic config reload rate |

---

### CoreDNS

| | |
|---|---|
| **UID** | `coredns-dashboard` |
| **ConfigMap** | `grafana-dashboard-coredns` |
| **Tags** | `coredns`, `dns`, `rke2`, `platform` |
| **Description** | DNS request rates, latency, cache performance, and error tracking. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| CoreDNS Instances Up | stat | `up{job="coredns"}` | count | CoreDNS pods responding |
| Total DNS Requests/s | stat | `coredns_dns_requests_total` | reqps | Aggregate DNS query rate |
| Cache Hit Rate % | stat | `coredns_cache_hits_total`, `coredns_cache_misses_total` | percent | Cache effectiveness |
| Panics | stat | `coredns_panics_total` | count | CoreDNS panic count |
| DNS Request Rate by Type | timeseries | `coredns_dns_requests_total` by type | reqps | A/AAAA/SRV/etc. query distribution |
| DNS Request Rate by Rcode | timeseries | `coredns_dns_responses_total` by rcode | reqps | NOERROR/NXDOMAIN/SERVFAIL distribution |
| DNS Request Duration (p50/p90/p99) | timeseries | `coredns_dns_request_duration_seconds_bucket` | s | DNS latency percentiles |
| Cache Size | timeseries | `coredns_cache_entries` | short | Number of cached entries |
| Cache Hit/Miss Rate | timeseries | `coredns_cache_hits_total` by type, `coredns_cache_misses_total` | ops | Cache hit/miss rates |
| DNS Errors (SERVFAIL) | timeseries | `coredns_dns_responses_total{rcode="SERVFAIL"}` | ops | SERVFAIL response rate |

---

### Cilium CNI Overview

| | |
|---|---|
| **UID** | `cilium-cni-overview` |
| **ConfigMap** | `grafana-dashboard-cilium` |
| **Tags** | `cilium`, `cni`, `networking`, `kubernetes` |
| **Description** | Cilium agent health, endpoint state, network policy, forwarding, drops, API latency, BPF operations, IPAM, and Hubble relay metrics. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Cilium Agents Up | stat | `up{job="cilium-agent"}` | short | Agents responding (requires port 9962 access) |
| Cilium Agents Down | stat | `up{job="cilium-agent"} == 0` | short | Agents not responding |
| Total Endpoints | stat | `cilium_endpoint_state` | short | All managed endpoints |
| Endpoints Ready | stat | `cilium_endpoint_state{endpoint_state="ready"}` | short | Endpoints in ready state |
| Endpoints Not Ready | stat | `cilium_endpoint_state{endpoint_state!="ready"}` | short | Endpoints not ready |
| Policy Change Rate | stat | `cilium_policy_change_total` | short | Network policy update rate |
| Drops per Second | stat | `cilium_drop_count_total` | pps | Total packet drops across all nodes |
| Endpoint State by Node | timeseries | `cilium_endpoint_state` | short | Endpoint states per node |
| Policy Count | timeseries | `cilium_policy` | short | Active network policies |
| Forwarded Bytes | timeseries | `cilium_forward_bytes_total` | Bps | Network throughput |
| Forwarded Packets | timeseries | `cilium_forward_count_total` | pps | Packet forwarding rate |
| Drop Reason | timeseries | `cilium_drop_count_total` by reason | pps | Packet drops by reason |
| API Limiter Processing Duration | timeseries | `cilium_api_limiter_processing_duration_seconds` | s | API rate limiter latency |
| BPF Map Operations | timeseries | `cilium_bpf_map_ops_total` | ops | BPF map operation rate |
| IP Addresses by Family | timeseries | `cilium_ip_addresses` by family | short | IPv4/IPv6 address allocation |
| Hubble gRPC Requests | timeseries | `grpc_server_handled_total{job="hubble-relay"}` | reqps | Hubble relay gRPC rate by method |
| Hubble gRPC Latency p99 | timeseries | `grpc_server_handling_seconds_bucket{job="hubble-relay"}` | s | Hubble relay p99 latency |

---

## Services

### Vault Cluster Overview

| | |
|---|---|
| **UID** | `vault-cluster-overview` |
| **ConfigMap** | `grafana-dashboard-vault` |
| **Tags** | `vault`, `rke2`, `hashicorp` |
| **Description** | 3-replica HA deployment with Raft storage. Metrics from `/v1/sys/metrics?format=prometheus`. Standby nodes require `unauthenticated_metrics_access = true`. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Vault Seal Status | stat | `vault_core_unsealed` | mapped | SEALED/UNSEALED per instance |
| Active Leader | stat | `vault_core_active` | mapped | LEADER/STANDBY per instance |
| Autopilot Health | stat | `vault_autopilot_healthy` | mapped | HEALTHY/UNHEALTHY |
| Vault Up | stat | `up{job="vault"}` | mapped | UP/DOWN per instance |
| Active Leases | stat | `vault_expire_num_leases` | count | Current active leases (orange@5000, red@10000) |
| Token Count | stat | `vault_token_count` | count | Active tokens (orange@5000, red@10000) |
| Barrier Ops Rate | timeseries | `vault_barrier_get`, `vault_barrier_put` | ops | Combined barrier read+write rate |
| Raft Commit p99 | timeseries | `vault_raft_commitTime{quantile="0.99"}` | ms | 99th percentile raft commit time |
| Raft Commit Time | timeseries | `vault_raft_commitTime` by quantile | ms | All quantiles of raft commit time |
| Raft Leader Last Contact | timeseries | `vault_raft_leader_lastContact` by quantile | ms | Time since last leader heartbeat |
| In-Flight Requests | timeseries | `vault_core_in_flight_requests` | short | Currently processing requests |
| Rollback Rate | timeseries | `vault_rollback_attempt_count` | ops | Rollback attempt rate |
| Runtime Memory | timeseries | `vault_runtime_alloc_bytes`, `vault_runtime_sys_bytes` | bytes | Go runtime memory allocation |

---

### GitLab Overview

| | |
|---|---|
| **UID** | `gitlab-overview` |
| **ConfigMap** | `grafana-dashboard-gitlab` |
| **Tags** | `services`, `gitlab`, `ci-cd`, `pipelines` |
| **Description** | Puma/Rails requests, Sidekiq job processing, Gitaly gRPC, Redis operations, error logs via Loki, CNPG database size, and CI/CD pipeline activity. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| GitLab Components Up | stat | `up{namespace="gitlab"}` | count | All GitLab pods responding |
| GitLab Components Down | stat | `up{job="gitlab-exporter"} == 0` | count | Exporter targets not responding |
| Puma Active Connections | timeseries | `puma_running`, `puma_pool_capacity`, `puma_max_threads` | short | Web server thread utilization |
| Rails Request Rate | timeseries | `http_requests_total{namespace="gitlab"}` by method | reqps | HTTP request rate by verb |
| Sidekiq Jobs Processed | timeseries | `sidekiq_jobs_processed_total` | ops | Background job completion rate |
| Sidekiq Jobs Failed | timeseries | `sidekiq_jobs_failed_total` | ops | Background job failure rate |
| Sidekiq Queue Size | timeseries | `sidekiq_queue_size` | short | Jobs waiting in Sidekiq queues |
| Gitaly Request Rate | timeseries | `gitaly_service_client_requests_total` | ops | Git storage operation rate |
| Gitaly Request Duration p99 | timeseries | `grpc_server_handling_seconds_bucket{namespace="gitlab"}` | s | Gitaly gRPC latency |
| Redis Operations | timeseries | `gitlab_redis_client_requests_total` | ops | GitLab Redis operation rate |
| Puma Memory Usage | timeseries | `ruby_process_resident_memory_bytes{pod=~".*webservice.*"}` | bytes | Webservice memory consumption |
| GitLab Error Logs | logs | `{namespace="gitlab"} \|= "error"` | - | Error-level log lines (Loki) |
| PostgreSQL Database Size | timeseries | `cnpg_pg_database_size_bytes{cnpg_cluster="gitlab-postgresql"}` | bytes | GitLab database size |
| Queue Latency | timeseries | `sidekiq_queue_latency_seconds` | s | Time jobs spend waiting in queue |
| Git Push/Fetch Rate | timeseries | `gitaly_service_client_requests_total{grpc_method=~".*Pack.*"}` | ops | ReceivePack/UploadPack rates |
| Pipeline/Deploy Logs | logs | `{namespace="gitlab", container=~"sidekiq\|gitaly"} \|~ "pipeline\|deploy"` | - | CI/CD related log lines (Loki) |

---

### CloudNativePG Cluster

| | |
|---|---|
| **UID** | `cnpg-cluster` |
| **ConfigMap** | `grafana-dashboard-cnpg` |
| **Tags** | `cloudnativepg`, `postgresql`, `cnpg`, `platform` |
| **Variables** | `$cluster` - select CNPG cluster name |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| PostgreSQL Instances Up | stat | `up{job="cnpg-postgresql"}` | count | Instances responding per cluster |
| Primary Instance | stat | `cnpg_pg_replication_in_recovery == 0` | bool | Which instance is primary |
| Replication Lag | stat | `cnpg_pg_replication_lag` | s | Max replication lag (threshold@30s) |
| Active Connections | stat | `cnpg_backends_total` | count | Current database connections |
| Transaction Rate | timeseries | `cnpg_pg_stat_database_xact_commit`, `xact_rollback` | ops | Commit vs rollback rate |
| Rows Returned/Fetched | timeseries | `cnpg_pg_stat_database_tup_returned`, `tup_fetched` | rowsps | Row retrieval rate |
| Rows Inserted/Updated/Deleted | timeseries | `cnpg_pg_stat_database_tup_inserted`, `tup_updated`, `tup_deleted` | rowsps | DML operation rate |
| Connection Usage % | gauge | `cnpg_backends_total / max_connections` | percent | Connection pool utilization (threshold@80%) |
| Replication Lag Over Time | timeseries | `cnpg_pg_replication_lag` | s | Lag trend (threshold@30s) |
| Database Size | timeseries | `cnpg_pg_database_size_bytes` | bytes | Database size growth |
| WAL Files | timeseries | `cnpg_collector_pg_wal{value="count/keep"}`, `cnpg_collector_wal_bytes`, `cnpg_collector_wal_records` | mixed | WAL file count, write rate |
| Block I/O (Read vs Hit) | timeseries | `cnpg_pg_stat_database_blks_read`, `blks_hit` | ops | Disk reads vs buffer cache hits |
| Temp Files & Bytes Written | timeseries | `cnpg_pg_stat_database_temp_bytes`, `temp_files` | Bps | Temporary file creation rate |
| Cache Hit Ratio | timeseries | `blks_hit / (blks_hit + blks_read)` | percent | Buffer cache effectiveness |
| WAL Archive Rate | timeseries | `cnpg_pg_stat_archiver_archived_count`, `failed_count` | ops | WAL archival success/failure rate |

---

### Harbor Registry Overview

| | |
|---|---|
| **UID** | `harbor-overview` |
| **ConfigMap** | `grafana-dashboard-harbor` |
| **Tags** | `harbor`, `registry`, `containers` |
| **Description** | Component health, project/repository counts, artifact pull/push rates, HTTP metrics, quota usage, task queue, and storage operations. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Harbor Components Up | stat | `up{job="harbor"}` | count | Core/registry/exporter responding |
| Total Projects | stat | `harbor_project_total` | count | Harbor project count |
| Total Repositories | stat | `harbor_statistics_total_repo_amount` | count | Container image repositories |
| Artifact Pull / Push Request Rate | timeseries | `harbor_artifact_pulled`, `harbor_core_http_request_total{operation="push"}` | ops | Image pull/push rates |
| HTTP Request Rate | timeseries | `harbor_core_http_request_total` by method, code | reqps | API request distribution |
| Quota Usage by Project | timeseries | `harbor_project_quota_usage_byte` | bytes | Storage consumption per project |
| Task Queue | timeseries | `harbor_task_scheduled_total`, `harbor_task_queue_latency`, `harbor_task_queue_size` | short | Async task queue metrics |
| Replication Status | timeseries | `harbor_task_scheduled_total` | short | Replication task activity |
| Registry Health & Storage Operations | timeseries | `harbor_health`, `registry_storage_action_seconds_count` | short | Health status and storage ops |
| Storage by Project | bargauge | `harbor_project_quota_usage_byte` | bytes | Disk space per project (visual bar) |
| Quota Usage % | stat | `sum(quota_usage_byte) / sum(quota_byte)` | percent | Overall storage quota consumption |

---

### DHI Builder Overview

| | |
|---|---|
| **UID** | `dhi-builder-overview` |
| **ConfigMap** | `grafana-dashboard-dhi-builder` |
| **Tags** | `dhi`, `builder`, `buildkit`, `harbor` |
| **Description** | DHI Builder pipeline overview — build status, durations, Harbor images |

| Panel | Metric(s) | Unit | What It Shows |
|-------|-----------|------|---------------|
| Active Builds | `argo_workflows_count{status="Running",label_app="dhi-builder"}` | count | Currently running DHI build workflows |
| Build Success Rate | `argo_workflows_count{status="Succeeded"}` / total | percent | Percentage of successful builds (24h) |
| Build Duration | `argo_workflows_duration_seconds{label_app="dhi-builder"}` | seconds | Per-image build time trend |
| Images in Harbor | `harbor_project_repo_count{project="dhi"}` | count | Number of images in dhi/ project |
| Manifest vs Harbor | custom query | table | Desired vs actual image inventory |
| BuildKit Cache Usage | `kubelet_volume_stats_used_bytes{namespace="dhi-builder"}` / capacity | percent | Build cache PVC utilization |
| Recent Build Logs | `{namespace="dhi-builder"}` (Loki) | logs | Last 50 workflow pod log lines |
| Build History | `argo_workflows_count{label_app="dhi-builder"}` by status | table | Recent workflow runs with status |

---

### Mattermost Overview

| | |
|---|---|
| **UID** | `mattermost-overview` |
| **ConfigMap** | `grafana-dashboard-mattermost` |
| **Tags** | `mattermost`, `messaging`, `collaboration` |
| **Description** | Kubernetes-level health metrics. App-level metrics require `MetricsSettings.Enable: true` in Mattermost config. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Deployment Readiness | stat | `kube_deployment_status_replicas_ready / spec_replicas` | percentunit | Ready vs desired ratio |
| Deployment Ready | stat | `kube_deployment_status_replicas_ready{deployment=~"mattermost.*"}` | mapped | UP/DOWN based on replica count |
| Pod Restarts (1h) | timeseries | `kube_pod_container_status_restarts_total{pod=~"mattermost.*"}` | short | Container restart count |
| CPU Usage | timeseries | `container_cpu_usage_seconds_total{pod=~"mattermost.*"}` | short | CPU consumption per container |
| Memory Usage | timeseries | `container_memory_working_set_bytes{pod=~"mattermost.*"}` | bytes | Memory per container |
| Network I/O | timeseries | `container_network_receive_bytes_total`, `transmit_bytes_total` | Bps | Network rx/tx rates |
| Mattermost Error Logs | logs | `{namespace="mattermost"} \|= "error"` | - | Error-level log lines (Loki) |

---

### ArgoCD Overview

| | |
|---|---|
| **UID** | `argocd-overview` |
| **ConfigMap** | `grafana-dashboard-argocd` |
| **Tags** | `argocd`, `gitops`, `ci-cd` |
| **Description** | Controller reconciliation, workqueue health, Redis backend, K8s API calls, and Go runtime. Per-app sync/health metrics require ServiceMonitor configuration. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Components Up | stat | `up{job="argocd"}` | count | ArgoCD components responding |
| Reconciliation Total | stat | `controller_runtime_reconcile_total` | count | Cumulative reconciliations |
| Reconciliation Rate | stat | `controller_runtime_reconcile_total` | ops | Reconciliation operations/sec |
| Reconciliation Error Rate | stat | `controller_runtime_reconcile_errors_total` | ops | Failed reconciliations/sec |
| Reconciliation Rate by Controller | timeseries | `controller_runtime_reconcile_total` by controller | ops | Per-controller reconcile rate |
| Reconciliation Error Rate by Controller | timeseries | `controller_runtime_reconcile_errors_total` by controller | ops | Per-controller error rate |
| Reconciliation Duration p99 | timeseries | `controller_runtime_reconcile_time_seconds_bucket` | s | Reconcile latency by controller |
| Workqueue Depth | timeseries | `workqueue_depth{job="argocd"}` | short | Items waiting in workqueue |
| Workqueue Additions | timeseries | `workqueue_adds_total{job="argocd"}` | ops | Items added to workqueue/sec |
| Redis Request Rate | timeseries | `argocd_redis_request_total` | reqps | ArgoCD Redis backend ops |
| K8s API Request Rate | timeseries | `rest_client_requests_total{job="argocd"}` by code, method | reqps | K8s API call rate |
| Workqueue Wait Duration p99 | timeseries | `workqueue_queue_duration_seconds_bucket{job="argocd"}` | s | Time items wait in queue |
| Go Goroutines | timeseries | `go_goroutines{job="argocd"}` | short | Active goroutines |
| Process Memory | timeseries | `go_memstats_alloc_bytes{job="argocd"}` | bytes | Go heap memory |

---

### Argo Rollouts Overview

| | |
|---|---|
| **UID** | `argo-rollouts-overview` |
| **ConfigMap** | `grafana-dashboard-argo-rollouts` |
| **Tags** | `argo-rollouts`, `deployments`, `ci-cd` |
| **Description** | Controller health, K8s API request rates, reconciliation performance, workqueue metrics, and Go runtime. CRD-level rollout metrics replaced with controller-level metrics. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Controller Up | stat | `up{job="argo-rollouts"}` | bool | Controller running status |
| Controller Info | stat | `argo_rollouts_controller_info` | - | Controller version and build info |
| Queue Depth | stat | `workqueue_depth{job="argo-rollouts"}` | count | Items waiting in workqueue |
| K8s API Request Rate | stat | `controller_clientset_k8s_request_total` | reqps | K8s API call rate |
| Rollout Reconciliation | timeseries | `controller_runtime_reconcile_total` by result | ops | Reconciliation rate by outcome |
| Reconciliation Duration p99 | timeseries | `controller_runtime_reconcile_time_seconds_bucket` | s | p99 reconcile latency |
| Workqueue Depth | timeseries | `workqueue_depth{job="argo-rollouts"}` | short | Queue depth over time |
| Workqueue Latency | timeseries | `workqueue_queue_duration_seconds_bucket` | s | p99 queue wait time by name |
| K8s API Requests by Status | timeseries | `controller_clientset_k8s_request_total` by status_code, verb | reqps | API calls by HTTP status |
| Go Memory | timeseries | `go_memstats_alloc_bytes{job="argo-rollouts"}` | bytes | Heap memory allocated |
| Go Goroutines | timeseries | `go_goroutines{job="argo-rollouts"}` | short | Active goroutine count |

---

### Redis Overview

| | |
|---|---|
| **UID** | `redis-overview` |
| **ConfigMap** | `grafana-dashboard-redis` |
| **Tags** | `services`, `redis`, `session-store` |
| **Description** | Redis session store metrics for oauth2-proxy: connections, memory, commands, and replication. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Redis Up | stat | `up{job="redis-exporter"}` | count | Redis exporter targets responding |
| Connected Clients | stat | `redis_connected_clients` | count | Current connected clients (orange@50, red@100) |
| Memory Usage % | stat | `redis_memory_used_bytes / redis_memory_max_bytes` | percent | Memory utilization (shows "No Limit" if maxmemory unset) |
| Connected Replicas | stat | `redis_connected_slaves` | count | Replication status |
| Commands/sec | timeseries | `redis_commands_processed_total` | ops | Command processing rate |
| Cache Hit Rate | timeseries | `redis_keyspace_hits_total / (hits + misses)` | percentunit | Cache effectiveness (red<50%, green>90%) |
| Memory Usage Over Time | timeseries | `redis_memory_used_bytes`, `redis_memory_max_bytes` | bytes | Memory consumption trend |
| Connected Clients Over Time | timeseries | `redis_connected_clients` | count | Client connection trend |
| Network I/O | timeseries | `redis_net_input_bytes_total`, `redis_net_output_bytes_total` | Bps | Network rx/tx throughput |

---

## Security

### Keycloak IAM Overview

| | |
|---|---|
| **UID** | `keycloak-overview` |
| **ConfigMap** | `grafana-dashboard-keycloak` |
| **Tags** | `keycloak`, `iam`, `security`, `authentication` |
| **Description** | Keycloak 26+ (Micrometer metrics). Token request rates, auth error rates, active HTTP requests, registration rates, JVM memory and GC. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Keycloak Up | stat | `up{job="keycloak"}` | bool | Keycloak responding |
| Token Request Rate (Success) | stat | `http_server_requests_seconds_count{uri=~"*/openid-connect/token",status="200"}` | ops | Successful OIDC token rate |
| Token Request Rate (Client Errors) | stat | `http_server_requests_seconds_count{status=~"4.."}` | ops | Failed token requests (4xx) |
| Active HTTP Requests | stat | `http_server_active_requests` | count | In-flight HTTP requests |
| Auth Request Rate | timeseries | `http_server_requests_seconds_count{status="200"}`, `{status=~"4.."}` | ops | Success vs failure rate |
| Auth Error Rate | timeseries | `4xx / total` | percent | Failed auth percentage (threshold@10%/30%) |
| Registration Request Rate | timeseries | `http_server_requests_seconds_count{uri=~"*/registrations",status="200"}` | ops | User registration rate |
| HTTP Request Avg Latency | timeseries | `http_server_requests_seconds_sum / count` | s | Average HTTP latency |
| JVM Memory | timeseries | `jvm_memory_used_bytes`, `jvm_memory_max_bytes` | bytes | JVM heap utilization |
| JVM GC Duration | timeseries | `jvm_gc_pause_seconds_sum` | s | Garbage collection overhead |
| HTTP Server Requests | timeseries | `http_server_requests_seconds_count` by method, status, uri | ops | Full request breakdown |
| Request Duration p99 | timeseries | `http_server_requests_seconds_bucket` | s | p99 latency by HTTP method |

---

### oauth2-proxy ForwardAuth

| | |
|---|---|
| **UID** | `oauth2-proxy-overview` |
| **ConfigMap** | `grafana-dashboard-oauth2-proxy` |
| **Tags** | `oauth2-proxy`, `authentication`, `security`, `keycloak` |
| **Description** | ForwardAuth monitoring using cAdvisor, kube-state-metrics, Traefik for proxy health; Keycloak Micrometer for OIDC analytics; Loki for error logs. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Proxies Ready | stat | `kube_deployment_status_replicas_ready{deployment=~"oauth2-proxy.*"}` | count | Ready pods (expected: 5) |
| Keycloak Logins (1h) | stat | `http_server_requests_seconds_count{status="200"}` | count/1h | Successful OIDC token requests |
| Login Failures (1h) | stat | `http_server_requests_seconds_count{status=~"4.."}` | count/1h | Failed token requests |
| Proxy Request Rate | stat | `traefik_service_requests_total{service=~".*oauth2-proxy.*"}` | reqps | Traffic through proxy services |
| Total Container Memory | stat | `container_memory_working_set_bytes{pod=~"oauth2-proxy.*"}` | bytes | Aggregate memory usage |
| Total Container CPU | stat | `container_cpu_usage_seconds_total{pod=~"oauth2-proxy.*"}` | short | Aggregate CPU usage |
| Pod Ready Status by Deployment | stat | `kube_deployment_status_replicas_ready` per deployment | count | Per-deployment readiness |
| OIDC Token Request Rate by URI | timeseries | `http_server_requests_seconds_count{status="200"}` by uri | ops | Token rate per client |
| OIDC Token Failures by Status | timeseries | `http_server_requests_seconds_count{status=~"4.."}` by status | ops | Failure breakdown (401/403/etc.) |
| Traefik Request Rate by Service | timeseries | `traefik_service_requests_total{service=~".*oauth2-proxy.*"}` | reqps | Traffic per proxy instance |
| OIDC Token Error Rate % | timeseries | `4xx / total` | percent | Failed token percentage |
| Container Memory by Pod | timeseries | `container_memory_working_set_bytes` per pod | bytes | Per-pod memory |
| Container CPU Usage by Pod | timeseries | `container_cpu_usage_seconds_total` per pod | percentunit | Per-pod CPU |
| Traefik Response Codes by Service | timeseries | `traefik_service_requests_total` by service, code | reqps | HTTP status distribution |
| Container Restarts by Pod | timeseries | `kube_pod_container_status_restarts_total{pod=~"oauth2-proxy.*"}` | short | Restart counts |
| oauth2-proxy Error Logs | logs | `{app_kubernetes_io_name="oauth2-proxy"} \|~ "error\|ERR\|401\|403"` | - | Auth error logs (Loki) |

---

### cert-manager Certificates

| | |
|---|---|
| **UID** | `cert-manager-certificates` |
| **ConfigMap** | `grafana-dashboard-cert-manager` |
| **Tags** | `cert-manager`, `certificates`, `tls` |
| **Description** | Certificate status, expiry tracking, ACME requests, and controller sync operations. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Certificates Ready | stat | `certmanager_certificate_ready_status{condition="True"}` | count | Certificates in Ready state |
| Certificates Not Ready | stat | `certmanager_certificate_ready_status{condition="False"}` | count | Certificates failing (red@1) |
| cert-manager Up | stat | `up{job="cert-manager"}` | bool | Controller responding |
| Certificate Expiry | table | `certmanager_certificate_expiration_timestamp_seconds - time()` | s | Time until each certificate expires |
| Certificate Ready Status | table | `certmanager_certificate_ready_status` | bool | Per-certificate ready/not-ready |
| ACME Client Requests | timeseries | `certmanager_http_acme_client_request_count` | reqps | ACME protocol request rate |
| Controller Sync Calls | timeseries | `certmanager_controller_sync_call_count` | ops | Controller reconciliation rate |
| Certificate Renewal Count | timeseries | `certmanager_certificate_renewal_timestamp_seconds` | short | Certificates renewed in last 24h |

---

### Security Operations

| | |
|---|---|
| **UID** | `security-advanced` |
| **ConfigMap** | `grafana-dashboard-security-advanced` |
| **Tags** | `security`, `keycloak`, `threat-detection`, `cilium`, `rbac` |
| **Description** | Threat detection, Keycloak auth monitoring, RBAC audit, DNS anomaly analysis, Cilium policy enforcement, secret access patterns, and log-based threat hunting. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Firing Security Alerts | stat | `ALERTS{alertstate="firing",alertname=~"Keycloak.*\|OAuth2Proxy.*\|..."}` | count | Security-related alerts firing |
| Keycloak Login Failures (1h) | stat | `http_server_requests_seconds_count{status=~"4.."}` | count/1h | Failed OIDC token requests |
| RBAC Denials (1h) | stat | `apiserver_request_total{code="403"}` | count/1h | API server 403 responses |
| Secret Access Rate | stat | `apiserver_request_total{resource="secrets",verb=~"GET\|LIST"}` | ops | Secret read request rate |
| DNS Query Rate | stat | `coredns_dns_requests_total` | ops | Total DNS query rate |
| API Write Rate | stat | `apiserver_request_total{verb!~"GET\|LIST\|WATCH"}` | ops | Non-read API operations |
| Keycloak Login Success vs Failure | timeseries | `http_server_requests_seconds_count{status="200"}`, `{status=~"4.."}` | ops | Auth success/failure trend |
| Login Error Breakdown | timeseries | `http_server_requests_seconds_count{status=~"4.."}` by status | ops | 401/403/etc. breakdown |
| API Request Rate by Verb | timeseries | `apiserver_request_total` by verb | ops | All API operations by type |
| 403 Forbidden Responses | timeseries | `apiserver_request_total{code="403"}` by resource, verb | ops | RBAC denial detail |
| DNS Query Rate by Type | timeseries | `coredns_dns_requests_total` by type | ops | DNS query type distribution |
| DNS Response Errors | timeseries | `coredns_dns_responses_total{rcode!="NOERROR"}` by rcode | ops | DNS error responses |
| Secret Access by Verb | timeseries | `apiserver_request_total{resource="secrets"}` by verb | ops | Secret CRUD operations |
| Service Account Token Requests | timeseries | `apiserver_request_total{resource="serviceaccounts",subresource="token"}` | ops | SA token issuance rate |
| Cilium Policy Drops | timeseries | `cilium_drop_count_total{reason=~"POLICY_DENIED.*"}` | ops | Network policy violations |
| Network Policy Drops by Reason | timeseries | `cilium_drop_count_total` by reason | ops | All drop reasons |
| Keycloak Auth Failures (Loki) | logs | `{namespace="keycloak"} \|~ "LOGIN_ERROR\|WARN\|authentication failed"` | - | Auth failure logs |
| RBAC/Forbidden Logs (Loki) | logs | `{namespace="kube-system", container="kube-apiserver"} \|= "Forbidden"` | - | API server RBAC denial logs |

---

## Observability

### Loki Stack Monitoring

| | |
|---|---|
| **UID** | `loki-stack-monitoring` |
| **ConfigMap** | `grafana-dashboard-loki-stack` |
| **Tags** | `loki`, `monitoring` |
| **Description** | Loki stack internals. Based on Grafana.com dashboard 14055. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Loki Up | stat | `up{job=~"loki.*"}` | count | Loki instances responding |
| Loki Logs Ingestion Rate | timeseries | `loki_distributor_bytes_received_total` | Bps | Log bytes ingested/sec |
| Loki Lines Ingested Rate | timeseries | `loki_distributor_lines_received_total` | short | Log lines ingested/sec |
| Active Streams | timeseries | `loki_ingester_memory_streams` | short | In-memory log streams |
| Chunks in Memory | timeseries | `loki_ingester_memory_chunks` | short | In-memory chunks |
| Chunk Store Operations | timeseries | `loki_chunk_store_index_entries_per_chunk_sum`, `loki_ingester_chunk_stored_bytes_total` | ops | Chunk storage activity |
| Ingester Flush Queue Length | timeseries | `loki_ingester_flush_queue_length` | short | Flush queue backlog |
| Query Latency p99 | timeseries | `loki_request_duration_seconds_bucket{route=~"loki_api_v1_query.*"}` | s | Query latency (threshold: orange@2s, red@10s) |
| Request Rate by Status | timeseries | `loki_request_duration_seconds_count` by status_code | reqps | API request status distribution |
| Loki Process Memory | timeseries | `process_resident_memory_bytes{job="loki"}`, `go_memstats_heap_inuse_bytes` | bytes | Process memory consumption |
| Loki CPU Usage | timeseries | `process_cpu_seconds_total{job="loki"}` | short | CPU utilization |
| Recent Loki Logs | logs | `{namespace="monitoring", app="loki"}` | - | Loki's own log output |

---

### Log Explorer

| | |
|---|---|
| **UID** | `loki-logs` |
| **ConfigMap** | `grafana-dashboard-loki` |
| **Tags** | `loki`, `logs` |
| **Description** | Interactive log viewer. Based on Grafana.com dashboard 15324. |
| **Variables** | `$namespace`, `$pod`, `$search` |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Log Volume | timeseries | `count_over_time({namespace=~"$namespace", pod=~"$pod"})` | short | Log line count by namespace |
| Error Rate | timeseries | `count_over_time(... \|~ "error\|panic\|fatal")` | short | Error/panic/fatal log rate |
| Warning Rate | timeseries | `count_over_time(... \|~ "warn")` | short | Warning log rate |
| Logs | logs | `{namespace=~"$namespace", pod=~"$pod"} \|~ "$search"` | - | Full log viewer with search |
| Log Volume by Container | timeseries | `count_over_time(...)` by container | short | Per-container log volume |

---

### Node Labeler

| | |
|---|---|
| **UID** | `node-labeler` |
| **ConfigMap** | `grafana-dashboard-node-labeler` |
| **Tags** | `operations`, `node-labeler` |
| **Description** | Node labeler controller metrics: label application rate and error tracking. |

| Panel | Type | Metric(s) | Unit | What It Shows |
|-------|------|-----------|------|---------------|
| Controller Up | stat | `up{job="kubernetes-pods",namespace="node-labeler"}` | mapped | UP/DOWN controller status |
| Labels Applied Total | stat | `node_labeler_labels_applied_total` | count | Cumulative labels applied |
| Nodes with Expected Labels | stat | `kube_node_labels{label_workload_type!=""}` | count | Nodes successfully labeled |
| Errors Total | stat | `node_labeler_errors_total` | count | Cumulative errors (orange@1, red@10) |
| Labels Applied Rate | timeseries | `node_labeler_labels_applied_total` | ops | Label application rate |
| Errors Rate | timeseries | `node_labeler_errors_total` | ops | Error rate (threshold: orange@0.01, red@0.1) |

---

## Metric Index

Quick reference of all Prometheus metrics used across dashboards, grouped by exporter/source.

### Node Exporter (`job="node-exporter"`)
- `node_boot_time_seconds` - System boot timestamp
- `node_cpu_seconds_total` - CPU time by mode (user/system/idle/iowait)
- `node_disk_read_bytes_total`, `node_disk_written_bytes_total` - Disk throughput
- `node_disk_reads_completed_total`, `node_disk_writes_completed_total` - Disk IOPS
- `node_filesystem_avail_bytes`, `node_filesystem_size_bytes` - Filesystem capacity
- `node_load1`, `node_load5`, `node_load15` - System load averages
- `node_memory_MemTotal_bytes`, `node_memory_MemAvailable_bytes`, `node_memory_Cached_bytes`, `node_memory_Buffers_bytes` - Memory
- `node_network_receive_bytes_total`, `node_network_transmit_bytes_total` - Network throughput
- `node_network_receive_errs_total`, `node_network_transmit_errs_total` - Network errors

### kube-state-metrics (`job="kube-state-metrics"`)
- `kube_deployment_status_replicas_ready`, `kube_deployment_spec_replicas` - Deployment readiness
- `kube_node_labels` - Node label inventory
- `kube_node_status_condition` - Node conditions (Ready, etc.)
- `kube_persistentvolume_capacity_bytes`, `kube_persistentvolume_info` - PV metadata
- `kube_persistentvolumeclaim_info`, `kube_persistentvolumeclaim_status_phase` - PVC status
- `kube_pod_container_status_restarts_total` - Container restart counts
- `kube_pod_info` - Pod inventory
- `kube_pod_status_phase` - Pod lifecycle phase

### Kubelet (`job="kubelet"`)
- `kubelet_volume_stats_available_bytes`, `kubelet_volume_stats_capacity_bytes`, `kubelet_volume_stats_used_bytes` - PVC storage
- `kubelet_volume_stats_inodes`, `kubelet_volume_stats_inodes_used` - PVC inodes

### cAdvisor (built into kubelet)
- `container_cpu_usage_seconds_total` - Container CPU consumption
- `container_memory_working_set_bytes` - Container memory usage
- `container_network_receive_bytes_total`, `container_network_transmit_bytes_total` - Container network I/O

### Kubernetes API Server (`job="kubernetes-apiservers"`)
- `apiserver_admission_webhook_admission_duration_seconds_bucket` - Webhook latency
- `apiserver_audit_event_total` - Audit event count
- `apiserver_current_inflight_requests` - In-flight request count
- `apiserver_request_duration_seconds_bucket` - Request latency histogram
- `apiserver_request_total` - Request count by verb/resource/code
- `apiserver_watch_events_total` - Watch event count
- `etcd_request_duration_seconds_bucket` - API server to etcd latency

### Kubernetes Scheduler (`job="kube-scheduler"`)
- `scheduler_pending_pods` - Unscheduled pods
- `scheduler_scheduling_attempt_duration_seconds_bucket` - Scheduling latency

### Kubernetes Controller Manager (`job="kube-controller-manager"`)
- `workqueue_adds_total`, `workqueue_depth` - Controller workqueue metrics

### etcd (`job="etcd"`)
- `etcd_disk_backend_commit_duration_seconds_bucket` - Backend commit latency
- `etcd_disk_wal_fsync_duration_seconds_bucket` - WAL fsync latency
- `etcd_mvcc_db_total_size_in_bytes` - Database size
- `etcd_network_client_grpc_received_bytes_total`, `etcd_network_client_grpc_sent_bytes_total` - Client traffic
- `etcd_network_peer_received_bytes_total`, `etcd_network_peer_sent_bytes_total` - Peer traffic
- `etcd_server_has_leader` - Leader status
- `etcd_server_leader_changes_seen_total` - Leader elections
- `etcd_server_proposals_committed_total`, `etcd_server_proposals_applied_total`, `etcd_server_proposals_failed_total`, `etcd_server_proposals_pending` - Raft proposals
- `grpc_server_handled_total`, `grpc_server_started_total` - gRPC activity

### Traefik (`job="traefik"`)
- `traefik_config_reloads_total` - Config reload count
- `traefik_entrypoint_request_duration_seconds_sum/count` - Entrypoint latency
- `traefik_entrypoint_requests_bytes_total`, `traefik_entrypoint_responses_bytes_total` - Throughput
- `traefik_entrypoint_requests_total`, `traefik_entrypoint_requests_tls_total` - Request counts
- `traefik_open_connections` - Active connections
- `traefik_service_request_duration_seconds_bucket` - Per-service latency
- `traefik_service_requests_total` - Per-service request counts
- `traefik_tls_certs_not_after` - TLS certificate expiry

### CoreDNS (`job="coredns"`)
- `coredns_cache_entries` - Cache size
- `coredns_cache_hits_total`, `coredns_cache_misses_total` - Cache performance
- `coredns_dns_request_duration_seconds_bucket` - DNS latency
- `coredns_dns_requests_total` - DNS query count by type
- `coredns_dns_responses_total` - DNS response count by rcode
- `coredns_panics_total` - Panic count

### Cilium (`job="cilium-agent"` / `job="hubble-relay"`)
- `cilium_api_limiter_processing_duration_seconds` - API rate limiter latency
- `cilium_bpf_map_ops_total` - BPF map operations
- `cilium_drop_count_total` - Packet drops by reason
- `cilium_endpoint_state` - Endpoint states
- `cilium_forward_bytes_total`, `cilium_forward_count_total` - Network forwarding
- `cilium_ip_addresses` - IP allocation by family
- `cilium_policy`, `cilium_policy_change_total` - Network policy metrics
- `grpc_server_handled_total`, `grpc_server_handling_seconds_bucket` (hubble-relay) - Hubble gRPC

### Vault (`job="vault"`)
- `vault_autopilot_healthy` - Autopilot health status
- `vault_barrier_get`, `vault_barrier_put` - Barrier operations
- `vault_core_active` - Active/standby status
- `vault_core_in_flight_requests` - In-flight requests
- `vault_core_unsealed` - Seal status
- `vault_expire_num_leases` - Active lease count
- `vault_raft_commitTime` - Raft commit latency
- `vault_raft_leader_lastContact` - Leader heartbeat timing
- `vault_rollback_attempt_count` - Rollback attempts
- `vault_runtime_alloc_bytes`, `vault_runtime_sys_bytes` - Go runtime memory
- `vault_token_count` - Active token count

### GitLab (`namespace="gitlab"`)
- `gitaly_service_client_requests_total` - Gitaly gRPC operations
- `gitlab_redis_client_requests_total` - Redis operations
- `grpc_server_handling_seconds_bucket` - Gitaly gRPC latency
- `http_requests_total` - Rails HTTP requests
- `puma_max_threads`, `puma_pool_capacity`, `puma_running` - Puma web server
- `ruby_process_resident_memory_bytes` - Webservice memory
- `sidekiq_jobs_failed_total`, `sidekiq_jobs_processed_total` - Job processing
- `sidekiq_queue_latency_seconds`, `sidekiq_queue_size` - Queue health

### CloudNativePG (`job="cnpg-postgresql"`)
- `cnpg_backends_total` - Active connections
- `cnpg_collector_pg_wal`, `cnpg_collector_wal_bytes`, `cnpg_collector_wal_records` - WAL metrics
- `cnpg_pg_database_size_bytes` - Database size
- `cnpg_pg_replication_in_recovery` - Primary/replica status
- `cnpg_pg_replication_lag` - Replication lag
- `cnpg_pg_settings_setting{name="max_connections"}` - Connection limit
- `cnpg_pg_stat_archiver_archived_count`, `cnpg_pg_stat_archiver_failed_count` - WAL archiving
- `cnpg_pg_stat_database_blks_hit`, `cnpg_pg_stat_database_blks_read` - Buffer cache
- `cnpg_pg_stat_database_temp_bytes`, `cnpg_pg_stat_database_temp_files` - Temp file usage
- `cnpg_pg_stat_database_tup_deleted`, `tup_fetched`, `tup_inserted`, `tup_returned`, `tup_updated` - Row operations
- `cnpg_pg_stat_database_xact_commit`, `xact_rollback` - Transaction rates

### Harbor (`job="harbor"`)
- `harbor_artifact_pulled` - Image pull count
- `harbor_core_http_request_total` - Core API requests
- `harbor_health` - Component health
- `harbor_project_quota_byte`, `harbor_project_quota_usage_byte` - Storage quota
- `harbor_project_total` - Project count
- `harbor_statistics_total_repo_amount` - Repository count
- `harbor_task_queue_latency`, `harbor_task_queue_size`, `harbor_task_scheduled_total` - Task queue
- `registry_storage_action_seconds_count` - Storage operations

### Keycloak (`job="keycloak"`)
- `http_server_active_requests` - In-flight HTTP requests
- `http_server_requests_seconds_bucket`, `seconds_count`, `seconds_sum` - HTTP request metrics
- `jvm_gc_pause_seconds_sum` - GC overhead
- `jvm_memory_max_bytes`, `jvm_memory_used_bytes` - JVM memory

### ArgoCD (`job="argocd"`)
- `argocd_redis_request_total` - Redis backend requests
- `controller_runtime_reconcile_errors_total`, `controller_runtime_reconcile_total` - Reconciliation
- `controller_runtime_reconcile_time_seconds_bucket` - Reconcile latency
- `go_goroutines`, `go_memstats_alloc_bytes` - Go runtime
- `rest_client_requests_total` - K8s API calls
- `workqueue_adds_total`, `workqueue_depth`, `workqueue_queue_duration_seconds_bucket` - Workqueue

### Argo Rollouts (`job="argo-rollouts"`)
- `argo_rollouts_controller_info` - Controller build info
- `controller_clientset_k8s_request_total` - K8s API requests
- `controller_runtime_reconcile_total`, `controller_runtime_reconcile_time_seconds_bucket` - Reconciliation
- `go_goroutines`, `go_memstats_alloc_bytes` - Go runtime
- `workqueue_depth`, `workqueue_queue_duration_seconds_bucket` - Workqueue

### Redis (`job="redis-exporter"`)
- `redis_commands_processed_total` - Command count
- `redis_connected_clients` - Client connections
- `redis_connected_slaves` - Replica connections
- `redis_keyspace_hits_total`, `redis_keyspace_misses_total` - Cache performance
- `redis_memory_max_bytes`, `redis_memory_used_bytes` - Memory usage
- `redis_net_input_bytes_total`, `redis_net_output_bytes_total` - Network I/O

### cert-manager (`job="cert-manager"`)
- `certmanager_certificate_expiration_timestamp_seconds` - Certificate expiry
- `certmanager_certificate_ready_status` - Certificate readiness
- `certmanager_certificate_renewal_timestamp_seconds` - Renewal timestamps
- `certmanager_controller_sync_call_count` - Controller sync rate
- `certmanager_http_acme_client_request_count` - ACME request rate

### Loki (`job="loki"`)
- `go_memstats_heap_inuse_bytes` - Go heap memory
- `loki_chunk_store_index_entries_per_chunk_sum` - Index entries
- `loki_distributor_bytes_received_total`, `loki_distributor_lines_received_total` - Ingestion rate
- `loki_ingester_chunk_stored_bytes_total` - Stored chunks
- `loki_ingester_flush_queue_length` - Flush queue
- `loki_ingester_memory_chunks`, `loki_ingester_memory_streams` - In-memory state
- `loki_request_duration_seconds_bucket`, `loki_request_duration_seconds_count` - Query performance
- `process_cpu_seconds_total`, `process_resident_memory_bytes` - Process resources

### Storage Autoscaler (`namespace="storage-autoscaler"`)
- `volume_autoscaler_poll_errors_total` - Poll errors
- `volume_autoscaler_pvc_usage_percent` - PVC usage as seen by autoscaler
- `volume_autoscaler_reconcile_duration_seconds_bucket` - Reconcile loop timing

### Node Labeler (`namespace="node-labeler"`)
- `node_labeler_errors_total` - Labeling errors
- `node_labeler_labels_applied_total` - Labels applied

### Prometheus Alerts
- `ALERTS{alertstate="firing"}` - Currently firing alerts (used in Cluster Home and Firing Alerts dashboards)
