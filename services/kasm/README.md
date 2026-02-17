# Kasm Workspaces (Virtual Desktops)

Container-based virtual desktop streaming platform for the Example Org RKE2 cluster. Kasm 1.18.1 provides browser-accessible Linux desktops and applications via WebSocket streaming.

> **Note**: Throughout this document, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env` (e.g., `example.com`). Derived formats:
> `<DOMAIN_DASHED>` = dots replaced with hyphens (e.g., `example-com`),
> `<DOMAIN_DOT>` = dots replaced with `-dot-` (e.g., `example-dot-com`).
> All service FQDNs follow the pattern `<service>.<DOMAIN>`.

## Status: Deployed

---

## Overview

Kasm Workspaces uses a split architecture: the control plane runs in Kubernetes on the general pool, while workspace sessions run as containers inside Harvester VMs (agent nodes). This separates the lightweight management API from the resource-intensive desktop streaming.

## Split Architecture

```mermaid
graph TD
    subgraph K8s["RKE2 Cluster (General Pool)"]
        Proxy["Kasm Proxy<br/>:8443"]
        API["Kasm API<br/>(Manager)"]
        CNPG["CNPG kasm-pg<br/>(3 instances, PG 14)<br/>Database Pool"]
    end

    subgraph HV["Harvester VMs (Agent Nodes)"]
        Agent1["Kasm Agent VM 1<br/>(desktop sessions)"]
        Agent2["Kasm Agent VM 2<br/>(desktop sessions)"]
    end

    Browser["Browser"]
    Traefik["Traefik LB<br/>kasm.<DOMAIN><br/>(IngressRoute - exception)<br/>WebSocket 1800s timeout<br/>Backend HTTPS with serversTransport"]

    Browser -->|"HTTPS"| Traefik
    Note over Traefik: Uses IngressRoute (not Gateway API)<br/>Reason: Requires serversTransport for HTTPS backend
    Traefik -->|"Route"| Proxy
    Proxy --> API
    API --> CNPG
    API -->|"Provision sessions"| Agent1
    API -->|"Provision sessions"| Agent2
    Browser -->|"WebSocket<br/>(desktop stream)"| Traefik -->|"Route"| Agent1
```

## Session Flow

```
Browser → Traefik (HTTPS, 1800s WebSocket timeout, IngressRoute)
  → Kasm Proxy (:8443, HTTPS backend with insecureSkipVerify)
    → Kasm Manager (session lookup)
      → Agent VM (container desktop)
        → Streaming back via WebSocket
```

> **Traefik timeout**: Increased from 600s to 1800s for desktop streaming. Without this, long-running desktop sessions are killed after 10 minutes of idle.
>
> **Why IngressRoute**: Kasm is an exception to the Gateway API migration. It requires a Traefik serversTransport with `insecureSkipVerify: true` for the HTTPS backend, which is not yet supported in Gateway API HTTPRoute. The Helm chart `backendProtocol: http` setting only affects Ingress annotations, not IngressRoute behavior.

## Components

| Component | Kind | Replicas | Pool | Description |
|-----------|------|----------|------|-------------|
| Kasm Proxy | Deployment | 1 | general | Reverse proxy + WebSocket routing |
| Kasm Manager | Deployment | 1 | general | API server + session management |
| Kasm Share | Deployment | 1 | general | Session sharing service |
| kasm-pg (CNPG) | Cluster | 3 | database | PostgreSQL 14 (required by Kasm) |
| Kasm Agent | Harvester VMs | variable | N/A (external) | Desktop session hosts |

## Prerequisites

- Vault + cert-manager deployed (for TLS certificate)
- Traefik with 1800s timeout (see `traefik-timeout-helmchartconfig.yaml` in Harbor service)
- CNPG Operator installed (`kubectl apply -f https://...cloudnative-pg/releases/...`)
- DNS: `kasm.<DOMAIN>` → `203.0.113.202`

## Deployment

### Step 1: Namespace and Database

```bash
kubectl apply -f services/kasm/namespace.yaml
kubectl apply -f services/kasm/postgres/secret.yaml
kubectl apply -f services/kasm/postgres/kasm-pg-cluster.yaml

# Wait for CNPG cluster to be ready (3 instances, in database namespace)
kubectl -n database get cluster kasm-pg -w
# STATUS: Cluster in healthy state
```

### Step 2: Helm Install

```bash
helm repo add kasmtech https://helm.kasmweb.com/
helm repo update

helm install kasm kasmtech/kasm \
  -n kasm \
  -f services/kasm/kasm-values.yaml
```

### Step 3: Ingress (IngressRoute - Exception)

Kasm remains on IngressRoute (not migrated to Gateway API) due to backend HTTPS requirement with serversTransport.

```bash
kubectl apply \
  -f services/kasm/certificate.yaml \
  -f services/kasm/ingressroute.yaml
```

### Step 4: Post-Deploy

1. Access Kasm at `https://kasm.<DOMAIN>`
2. Login: `admin@kasm.local` / password from `kasm-secrets` secret
3. Configure Harvester VM Provider in Admin UI:
   - Navigate to Infrastructure > Docker Agents
   - Add Harvester VM provider with API credentials
   - Configure VM templates for workspace sessions

## Configuration

### Helm Values (`kasm-values.yaml`)

| Parameter | Value | Description |
|-----------|-------|-------------|
| `database.standalone` | `true` | Use external PostgreSQL (CNPG) |
| `database.host` | `kasm-pg-rw.database.svc.cluster.local` | CNPG read-write service |
| `database.port` | `5432` | PostgreSQL port |
| `database.name` | `kasm` | Database name |
| `proxy.type` | `ClusterIP` | Service type (Traefik handles LB) |
| `ingress.enabled` | `false` | Using IngressRoute instead |

### CNPG Cluster (`kasm-pg-cluster.yaml`)

| Parameter | Value | Description |
|-----------|-------|-------------|
| `instances` | `3` | PostgreSQL replicas |
| `postgresql.major` | `14` | Kasm requires PG 14 |
| `storage.size` | `20Gi` | Per-instance storage |
| `nodeSelector` | `workload-type: database` | Database pool |

## Verification

```bash
# All pods running
kubectl -n kasm get pods

# CNPG cluster healthy (in database namespace)
kubectl -n database get cluster kasm-pg
# STATUS: Cluster in healthy state

# TLS certificate issued
kubectl -n kasm get certificate
# READY = True

# Test external access
curl -sI https://kasm.<DOMAIN>/
# HTTP/2 200

# Check admin credentials
kubectl -n kasm get secret kasm-secrets -o jsonpath='{.data.admin-password}' | base64 -d
```

## Troubleshooting

### Desktop sessions timeout after 10 minutes

Traefik's default `readTimeout` is 60s (CVE-2024-28869 fix in Traefik 3.x). Desktop streaming requires 1800s. Apply the timeout HelmChartConfig:

```bash
kubectl apply -f services/harbor/traefik-timeout-helmchartconfig.yaml
```

### CNPG cluster not initializing

Check the CNPG operator is installed and the secret exists:

```bash
kubectl get pods -n cnpg-system
kubectl -n database get secret kasm-pg-superuser
```

### Kasm pods CrashLoopBackOff

Check database connectivity:

```bash
kubectl -n kasm logs deployment/kasm-manager | grep -i database
```

Common cause: CNPG cluster not ready yet, or secret credentials don't match.

### Agent VMs can't connect

Verify the Harvester VM Provider is configured in Admin UI. Agent VMs need network access to the Kasm proxy service.

## File Structure

```
services/kasm/
├── kustomization.yaml           # Lists namespace, cert, ingressroute
├── namespace.yaml               # kasm namespace
├── kasm-values.yaml             # Helm values (external PG, ClusterIP proxy)
├── certificate.yaml             # Explicit TLS cert for kasm.<DOMAIN> (not auto via gateway-shim)
├── ingressroute.yaml            # Traefik IngressRoute (exception: embeds ServersTransport for HTTPS backend)
└── postgres/
    ├── secret.yaml              # CNPG superuser credentials (CHANGEME)
    ├── kasm-pg-cluster.yaml     # CNPG Cluster (3 instances, PG 14)
    └── kasm-pg-scheduled-backup.yaml  # CNPG ScheduledBackup
```

> **Note**: Kasm is the only service that remains on IngressRoute (not migrated to Gateway API) because it requires backend HTTPS with `insecureSkipVerify`, which Gateway API HTTPRoute does not yet support via extensionRef.

## Dependencies

- **Vault + cert-manager** (TLS certificate issuance)
- **Traefik** (ingress with 1800s timeout)
- **CNPG Operator** (PostgreSQL cluster management)
- **Harvester CSI** (PVCs for CNPG)
- **Harvester** (VM provisioning for agent nodes)
- **DNS**: `kasm.<DOMAIN>` → `203.0.113.202`
