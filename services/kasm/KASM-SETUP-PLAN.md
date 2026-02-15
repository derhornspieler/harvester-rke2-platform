# Kasm Workspaces - Setup & Configuration Plan

> **Note**: Throughout this document, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env` (e.g., `example.com`). Derived formats:
> `<DOMAIN_DASHED>` = dots replaced with hyphens (e.g., `example-com`),
> `<DOMAIN_DOT>` = dots replaced with `-dot-` (e.g., `example-dot-com`).
> All service FQDNs follow the pattern `<service>.<DOMAIN>`.

## Current Deployment Status

Kasm 1.18.1 control plane deployed on RKE2 via Helm (`kasmtech/kasm` v1.1181.0):
- All pods running on general worker pool
- CNPG PostgreSQL 14 cluster (3 instances) on database pool
- Traefik IngressRoute with sticky sessions + ServersTransport (HTTPS backend)
- cert-manager Certificate via vault-issuer (kasm.<DOMAIN>)
- Admin: `admin@kasm.local` (password in `kasm-secrets` secret)

---

## Architecture Overview

### Split Architecture
- **Control plane** runs in K8s (API, Manager, Proxy, Guac, RDP gateways)
- **Workspace sessions** run on separate **Docker Agent VMs** or **KubeVirt/Harvester VMs**
- Agents are NOT K8s pods — they require external VMs with Docker Engine

### Traffic Flow
1. User browser → Traefik (443/WSS) → Kasm Proxy (8443)
2. Proxy → API (authenticates, queries DB for available agents)
3. API → Manager (finds healthy Connection Proxy in Zone)
4. User's WebSocket stream → Connection Proxy (Guacamole) → Agent VM → KasmVNC container
5. Desktop/app rendered in browser via WebSocket

### Workspace Session Types
| Type | Description | Use Case |
|------|-------------|----------|
| Container (Docker) | Runs on Docker Agent VMs, multiple per host | Browsers, Linux apps, dev tools |
| Server (RDP/VNC) | Full VM, 1:1 ratio | Windows desktops, legacy apps |
| Server Pool | Auto-scaled VMs | Scalable Windows/Linux desktops |
| Link | URL redirect | SaaS app bookmarks |

---

## Phase 1: Docker Agent VMs (Container Workspaces)

### Option A: Static Agents (Start Here)
Provision 2-3 Ubuntu VMs on Harvester manually:

1. **Create Ubuntu 22.04 VM template in Harvester**
   - 8 vCPU, 16GB RAM, 100GB disk (supports ~4-6 concurrent sessions each)
   - Network: vm-network (same as worker nodes)
   - Cloud image: Ubuntu 22.04 (or Rocky 9)

2. **Install Kasm Agent on each VM**
   - Install Docker Engine
   - Download/run Kasm agent installer
   - Register with control plane using Manager Token:
     ```bash
     kubectl -n kasm get secret kasm-secrets -o jsonpath='{.data.manager-token}' | base64 -d
     ```

3. **Register agents in Kasm Admin UI**
   - Admin > Infrastructure > Docker Agents > Add
   - Hostname/IP of each VM
   - Zone: default

### Option B: Auto-Scaled Agents (After Validation)
Configure Harvester KubeVirt provider for automatic VM provisioning:

1. **Create VM template in Harvester**
   - Ubuntu 22.04 with qemu-guest-agent
   - Cloud-init startup script that:
     - Installs Docker Engine
     - Installs Kasm agent
     - Registers with control plane automatically
   - **IMPORTANT**: Uncomment qemu-agent lines in startup script (required for KubeVirt)

2. **Configure in Kasm Admin UI**
   - Admin > Infrastructure > VM Providers > Add
   - Provider: KubeVirt/Harvester
   - Harvester kubeconfig
   - VM namespace, image, network, template
   - Startup script (cloud-init)

3. **Auto-Scale Settings**
   - Min VMs: 2 (always-on capacity)
   - Max VMs: 10
   - Minimum Available Sessions: 4 (triggers scale-up when fewer than 4 open slots)
   - Scale-down delay: 15 minutes (avoids thrashing)

### Resource Sizing (per Docker Agent VM)

| Agent Size | vCPU | RAM | Disk | Concurrent Sessions |
|-----------|------|-----|------|-------------------|
| Small | 4 | 8GB | 50GB | 2-3 |
| Medium | 8 | 16GB | 100GB | 4-6 |
| Large | 16 | 32GB | 200GB | 8-12 |

Default per workspace: 2 vCPU, 2768MB RAM (configurable per image).

---

## Phase 2: Workspace Images

### Initial Images to Register
Register in Admin > Workspaces > Add Workspace:

| Image | Docker Image | Use Case |
|-------|-------------|----------|
| Chrome | `kasmweb/chrome:1.18.0` | Secure web browsing |
| Firefox | `kasmweb/firefox:1.18.0` | Alternative browser |
| Ubuntu Desktop | `kasmweb/desktop:1.18.0` | Full Linux desktop |
| VS Code | `kasmweb/vs-code:1.18.0` | Development IDE |
| Terminal | `kasmweb/terminal:1.18.0` | CLI access |

### Harbor Integration (Proxy Cache)
Configure agents to pull through Harbor proxy cache:
- Instead of: `kasmweb/chrome:1.18.0`
- Use: `harbor.<DOMAIN>/dockerhub/kasmweb/chrome:1.18.0`

**Setup:**
1. Create Harbor robot account for Kasm agents
2. Configure Docker daemon on agent VMs to use Harbor as registry mirror
3. Or set registry per-workspace in Kasm Admin > Workspaces > Docker Registry field

### Custom Images (Future)
- Build custom workspace images based on `kasmweb/core-*` base images
- Push to `harbor.<DOMAIN>/library/`
- Include Aegis-specific tools, configs, CA certs

---

## Phase 3: Keycloak OIDC Integration

### Keycloak Configuration
1. **Create OIDC client** in `example` realm:
   - Client ID: `kasm`
   - Client Protocol: openid-connect
   - Access Type: confidential
   - Valid Redirect URIs: `https://kasm.<DOMAIN>/*`

2. **Create Group Membership mapper**:
   - Mapper Type: Group Membership
   - Token Claim Name: `groups`
   - Full group path: OFF

### Kasm Configuration
1. Admin > Access Management > Authentication > OpenID > Add Config
2. Enter Keycloak OIDC endpoints:
   - Issuer: `https://keycloak.<DOMAIN>/realms/example`
   - Authorization endpoint: `.../protocol/openid-connect/auth`
   - Token endpoint: `.../protocol/openid-connect/token`
   - Userinfo endpoint: `.../protocol/openid-connect/userinfo`
3. Client ID + Client Secret from Keycloak

### Group Mapping
| Keycloak Group | Kasm Group | Access |
|---------------|------------|--------|
| aegis-admins | Administrators | Full admin access |
| aegis-developers | Developers | VS Code, Terminal, Desktop, Browsers |
| aegis-users | All Users | Browsers only |

MFA enforced through Keycloak (not Kasm's built-in MFA).

---

## Phase 4: Persistent Profiles

### S3-Based Profiles (Recommended)
Use existing MinIO deployment for profile storage:

1. **Create MinIO bucket**: `kasm-profiles`
2. **Configure in Kasm Admin** > Settings > Global > Persistent Profiles:
   - Storage Provider: S3
   - Endpoint: `http://minio.minio.svc.cluster.local:9000`
   - Bucket: `kasm-profiles`
   - Access Key / Secret Key: MinIO credentials
   - Size Limit: 10GB per user

3. **Profile filtering** (exclude from sync):
   ```
   .cache
   .vnc
   Downloads
   Uploads
   ```

### Important Notes
- All workspaces run as **UID/GID 1000** (kasm-user) — hardcoded, cannot change
- Profiles sync on session start/stop
- Changes NOT saved if profile exceeds size limit

---

## Phase 5: Security & Session Policies

### Session Settings (per Group)
| Setting | Value | Description |
|---------|-------|-------------|
| Idle Disconnect | 20 min | Disconnect inactive users |
| Session Time Limit | 8 hours | Hard limit per session |
| Keepalive Expiration | 1 hour | No heartbeat triggers action |
| Expiration Action | Destroy | Remove container on timeout |

### Network Isolation
- Each workspace container is network-isolated
- Configure Docker network restrictions per workspace
- Consider Sysbox runtime for enhanced container isolation

### Clipboard / DLP
- Clipboard transfer configurable per group (enable/disable)
- File upload/download configurable per group
- Watermarking available (Enterprise)

---

## Deployment Zones

### Current: Single Zone (Default)
Sufficient for single-location cluster. All agents and sessions in one zone.

### Future Multi-Zone Considerations
- Separate zones for different workspace types (dev vs general)
- Compliance isolation zones
- Each zone: 1 Manager, multiple agents, 100-200 concurrent sessions
- Geographic distribution if expanding to other sites

---

## Monitoring Integration

### Prometheus
- Kasm exposes metrics endpoints on API and Manager services
- Add scrape targets in Prometheus configmap
- Key metrics: active sessions, agent health, resource utilization

### Grafana Dashboard
- Create Kasm dashboard tracking:
  - Active sessions count
  - Agent VM count and health
  - Session duration distribution
  - Resource utilization per agent
  - Login/auth metrics

### Logging (Alloy + Loki)
- Kasm services log JSON to stdout
- Auto-collected by Alloy into Loki
- Key log sources: API, Manager, Guac, Proxy

---

## Known Limitations

| Limitation | Impact | Workaround |
|-----------|--------|------------|
| Agents cannot run as K8s pods | Must provision separate VMs | Use Harvester auto-scale |
| K8s deployment is "Technical Preview" | Not officially production-ready | Monitor for GA release |
| UID/GID 1000 hardcoded | All users share same UID | Plan directory structure carefully |
| No public roadmap for native K8s pods | Architecture requires Docker daemon | Harvester KubeVirt provides VM auto-scaling |

---

## Implementation Order

```
Phase 1a: Static Docker Agent VMs (2-3 Ubuntu VMs on Harvester)
     1b: Register workspace images (Chrome, Firefox, Desktop, VS Code)
     1c: Test end-to-end: login → launch workspace → stream → destroy

Phase 2:  Keycloak OIDC integration (SSO + group-based access)

Phase 3:  Persistent profiles via MinIO S3

Phase 4:  Harbor proxy cache for workspace images

Phase 5:  Auto-scaled agents via Harvester KubeVirt provider

Phase 6:  Monitoring (Prometheus scrape + Grafana dashboard)
```

---

## References

- [Kasm Documentation](https://docs.kasm.com)
- [Kasm Helm Chart](https://github.com/kasmtech/kasm-helm)
- [Harvester AutoScale Provider](https://www.kasmweb.com/docs/develop/how_to/infrastructure_components/autoscale_providers/harvester.html)
- [Keycloak OIDC Setup](https://www.kasmweb.com/docs/develop/guide/oidc/keycloak.html)
- [Persistent Profiles](https://www.kasmweb.com/docs/latest/guide/persistent_data/persistent_profiles.html)
- [Workspace Registry](https://www.kasmweb.com/docs/latest/guide/workspace_registry.html)
- [VDI on K8s: Rancher + Harvester + Kasm](https://medium.kasm.com/vdi-on-kubernetes-for-enterprises-rancher-harvester-kasm-92652d46d8ca)
- [Docker Agents](https://docs.kasm.com/docs/latest/guide/compute/servers/index.html)
- [Deployment Zones](https://www.kasmweb.com/docs/develop/guide/zones/deployment_zones.html)
- [Auto-Scaling](https://docs.kasm.com/docs/latest/how-to/autoscale/index.html)
- [Session Management Settings](https://www.kasmweb.com/docs/develop/guide/groups/group_settings.html)
- [Reverse Proxy Configuration](https://kasm.com/docs/latest/how_to/reverse_proxy.html)
