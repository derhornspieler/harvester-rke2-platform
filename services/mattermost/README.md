# Mattermost (Team Messaging)

Self-hosted team messaging platform for the Example Org RKE2 cluster. Enterprise Edition 10.5 running in free mode with a zero-effort upgrade path to HA when Enterprise licensed.

> **Note**: Throughout this document, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env` (e.g., `example.com`). Derived formats:
> `<DOMAIN_DASHED>` = dots replaced with hyphens (e.g., `example-com`),
> `<DOMAIN_DOT>` = dots replaced with `-dot-` (e.g., `example-dot-com`).
> All service FQDNs follow the pattern `<service>.<DOMAIN>`.

## Status: Manifests Ready (Not Yet Deployed)

---

## Overview

Mattermost provides Slack-like team messaging with full control over data. The deployment includes PostgreSQL for persistent data, MinIO for S3-compatible file storage, and Prometheus metrics. Pre-configured for HA upgrade by flipping a single environment variable.

## Architecture

```
                    ┌────────────────────────────────────────────┐
                    │   Traefik Ingress (203.0.113.202:443)       │
                    │   mattermost.<DOMAIN>                 │
                    │   (Gateway + HTTPRoute)                    │
                    │   Note: Sticky cookie removed in migration │
                    └──────────────┬─────────────────────────────┘
                                   │ HTTPS (Gateway API)
                    ┌──────────────▼───────────────────────┐
                    │        Mattermost                    │
                    │   (mattermost namespace)              │
                    │   Port: 8065 (HTTP+WS)               │
                    │   Port: 8067 (metrics)                │
                    │   Port: 8074 (gossip, HA)             │
                    │   Pool: general                       │
                    │   1 replica (HA-ready)                │
                    └──────┬──────────────┬────────────────┘
                           │              │
                ┌──────────▼──────┐  ┌────▼─────────────┐
                │   PostgreSQL    │  │     MinIO         │
                │   (database)    │  │   (general pool)  │
                │   :5432         │  │   :9000 (S3)      │
                │   20Gi PVC      │  │   :9001 (console) │
                │   PG 16         │  │   20Gi PVC        │
                └─────────────────┘  └──────────────────┘
```

## HA Upgrade Path

```mermaid
graph LR
    Single["Single Replica<br/>(current)"]
    Flip["Set MM_CLUSTERSETTINGS_ENABLE=true<br/>Set replicas: 2"]
    HA["HA Cluster<br/>(2+ replicas, gossip)"]

    Single -->|"Enterprise license"| Flip --> HA
```

Pre-configured HA features already in the manifests:
- Gossip port 8074 exposed in Service
- Pod anti-affinity (prefer different nodes)
- Shared PostgreSQL and MinIO backends
- Note: Sticky cookie (MMSTICKY) was removed in Gateway API migration — no impact at single-replica, will need session persistence strategy for HA

## Components

| Component | Image | Kind | Replicas | CPU (req/lim) | Memory (req/lim) | Storage | Pool |
|-----------|-------|------|----------|---------------|-------------------|---------|------|
| Mattermost | `mattermost/mattermost-enterprise-edition:10.5` | Deployment | 1 | 500m / 2 | 1Gi / 4Gi | none | general |
| PostgreSQL | `ghcr.io/cloudnative-pg/postgresql:16.6` | CNPG Cluster | 3 instances | 250m / 1 | 512Mi / 2Gi | 20Gi PVC | database namespace |
| MinIO | `docker.io/minio/minio:latest` | StatefulSet | 1 | 250m / 1 | 512Mi / 2Gi | 20Gi PVC | general |

## Prerequisites

- Vault + cert-manager deployed (for TLS certificate)
- Traefik ingress running
- DNS: `mattermost.<DOMAIN>` → `203.0.113.202`

## TLS Trust (Internal CA)

Mattermost needs to trust the Vault Root CA for internal HTTPS connections (e.g., webhook integrations, plugin downloads). The deployment mounts the `vault-root-ca` ConfigMap as a trusted certificate:

- **Environment variable**: `SSL_CERT_FILE=/etc/ssl/certs/vault-root-ca.pem`
- **Volume mount**: `vault-root-ca` ConfigMap (`ca.crt` key) at `/etc/ssl/certs/vault-root-ca.pem`

> **Prerequisite**: The `vault-root-ca` ConfigMap must exist in the `mattermost` namespace before deploying. It is created by the cluster bootstrap script (`deploy-cluster.sh`).

## Deployment

```bash
# Apply all manifests
kubectl apply -k services/mattermost/

# Wait for CNPG PostgreSQL cluster (in database namespace)
kubectl -n database get cluster mattermost-pg -w
# Wait for STATUS: "Cluster in healthy state"

# Wait for MinIO
kubectl -n mattermost rollout status statefulset/mattermost-minio --timeout=120s

# Wait for Mattermost
kubectl -n mattermost rollout status deployment/mattermost --timeout=300s
```

### Post-Deploy Steps

```bash
# 1. Create MinIO bucket
kubectl -n mattermost exec -it statefulset/mattermost-minio -- \
  mc alias set local http://localhost:9000 <access-key> <secret-key>
kubectl -n mattermost exec -it statefulset/mattermost-minio -- \
  mc mb local/mattermost

# 2. Create admin user
kubectl -n mattermost exec -it deployment/mattermost -- \
  mmctl user create --email admin@<DOMAIN> \
  --username admin --password '<strong-password>' \
  --system-admin --local

# 3. Add DNS record
# mattermost.<DOMAIN> → 203.0.113.202
```

## Configuration

All Mattermost configuration is via `MM_*` environment variables in a ConfigMap and Secret. No `config.json` file is mounted.

### Key Settings (ConfigMap)

| Variable | Value | Description |
|----------|-------|-------------|
| `MM_SERVICESETTINGS_SITEURL` | `https://mattermost.<DOMAIN>` | Public URL |
| `MM_SERVICESETTINGS_LISTENADDRESS` | `:8065` | HTTP + WebSocket port |
| `MM_SQLSETTINGS_DRIVERNAME` | `postgres` | Database driver |
| `MM_FILESETTINGS_DRIVERNAME` | `amazons3` | S3 file storage |
| `MM_FILESETTINGS_AMAZONS3BUCKET` | `mattermost` | MinIO bucket |
| `MM_FILESETTINGS_AMAZONS3ENDPOINT` | `mattermost-minio.mattermost.svc.cluster.local:9000` | MinIO endpoint |
| `MM_FILESETTINGS_AMAZONS3SSL` | `false` | Internal connection |
| `MM_LOGSETTINGS_CONSOLEJSON` | `true` | JSON logs to stdout |
| `MM_METRICSSETTINGS_ENABLE` | `true` | Prometheus metrics on :8067 |
| `MM_CLUSTERSETTINGS_ENABLE` | `false` | Set `true` for HA |
| `MM_CLUSTERSETTINGS_CLUSTERNAME` | `mattermost-prod` | Gossip cluster name |
| `MM_CLUSTERSETTINGS_GOSSIPPORT` | `8074` | Inter-node gossip |

### Key Settings (Secret)

| Variable | Description |
|----------|-------------|
| `MM_SQLSETTINGS_DATASOURCE` | PostgreSQL connection string |
| `MM_FILESETTINGS_AMAZONS3ACCESSKEYID` | MinIO access key |
| `MM_FILESETTINGS_AMAZONS3SECRETACCESSKEY` | MinIO secret key |

### PostgreSQL Tuning (ConfigMap)

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `shared_buffers` | `512MB` | Shared memory for caching |
| `max_connections` | `200` | Connection pool size |
| `effective_cache_size` | `1536MB` | OS cache estimate |
| `work_mem` | `4MB` | Per-operation memory |

## Metrics and Logging

- **Metrics**: Port 8067 with `prometheus.io/scrape: "true"` annotations, auto-discovered by Prometheus
- **Logging**: JSON to stdout (`MM_LOGSETTINGS_CONSOLEJSON=true`), collected by Alloy into Loki

## Verification

```bash
# All pods running
kubectl -n mattermost get pods

# Gateway and HTTPRoute deployed
kubectl -n mattermost get gateway
kubectl -n mattermost get httproute
# Gateway should have assigned IP

# TLS secret auto-created by gateway-shim
kubectl -n mattermost get secrets | grep tls

# Test external access
curl -sI https://mattermost.<DOMAIN>/
# HTTP/2 200

# Check metrics endpoint
kubectl -n mattermost port-forward deployment/mattermost 8067:8067
curl http://localhost:8067/metrics | head
```

## Troubleshooting

### Mattermost can't connect to PostgreSQL

Check the `MM_SQLSETTINGS_DATASOURCE` in the Secret. Format:
```
postgres://user:password@mattermost-postgres:5432/mattermost?sslmode=disable
```

### File uploads fail

Verify MinIO bucket exists and credentials match:
```bash
kubectl -n mattermost exec -it statefulset/mattermost-minio -- mc ls local/
# Should show "mattermost" bucket
```

### WebSocket disconnections

Note: Sticky cookie (MMSTICKY) was removed in the Gateway API migration. At single-replica deployment, this is not an issue. For HA (multiple Mattermost replicas), you'll need to implement session persistence via Mattermost cluster mode (`MM_CLUSTERSETTINGS_ENABLE=true`) which uses gossip protocol to share session state.

## File Structure

```
services/mattermost/
├── kustomization.yaml
├── namespace.yaml
├── gateway.yaml                  # Gateway with cert-manager annotation (auto-creates TLS secret)
├── httproute.yaml                # HTTPRoute (no basic-auth middleware)
├── postgres/
│   ├── secret.yaml               # PostgreSQL credentials (CHANGEME)
│   ├── mattermost-pg-cluster.yaml  # CNPG Cluster (3 instances, PG 16, database namespace)
│   └── mattermost-pg-scheduled-backup.yaml  # CNPG ScheduledBackup
├── minio/
│   ├── secret.yaml               # MinIO credentials (CHANGEME)
│   ├── statefulset.yaml          # MinIO, 20Gi PVC
│   └── service.yaml              # ClusterIP :9000 + :9001
└── mattermost/
    ├── secret.yaml               # MM_* secrets (CHANGEME)
    ├── configmap.yaml            # MM_* config
    ├── deployment.yaml           # Mattermost EE 10.5
    ├── service.yaml              # ClusterIP :8065 + :8074
    └── service-metrics.yaml      # Metrics :8067
```

## Dependencies

- **Vault + cert-manager** (TLS certificate issuance)
- **Traefik** (ingress)
- **Harvester CSI** (PVCs for PostgreSQL and MinIO)
- **DNS**: `mattermost.<DOMAIN>` → `203.0.113.202`
