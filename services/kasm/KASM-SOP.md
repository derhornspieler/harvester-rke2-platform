# Kasm Workspaces -- Post-Install Configuration SOP

> Standard Operating Procedure for configuring Kasm Workspaces 1.18.1 after
> Helm deployment. Covers all session delivery models, Keycloak SSO
> (including automation), Harvester VDI autoscaling, and workspace image
> registration.
>
> **Audience**: Platform engineer with Harvester admin + Kasm admin access.
>
> **Prerequisites**: Kasm 1.18.1 control plane running on RKE2 (see README.md
> for Helm install steps). Keycloak realm created by `setup-keycloak.sh`.

---

## Table of Contents

**Part I -- Session Delivery Models**
1. [Session Delivery Overview](#1-session-delivery-overview)
2. [Docker Agent Pools (Container Workspaces)](#2-docker-agent-pools-container-workspaces)
3. [Server Pools (Full VM Desktops)](#3-server-pools-full-vm-desktops)
4. [Multi-Session Servers (RDS / Shared)](#4-multi-session-servers-rds--shared)
5. [Persistent Sessions & Profiles](#5-persistent-sessions--profiles)
6. [Session Staging (Pre-Warmed)](#6-session-staging-pre-warmed)
7. [Choosing a Deployment Model](#7-choosing-a-deployment-model)

**Part II -- Keycloak OIDC Integration**
8. [Gather Credentials](#8-gather-credentials)
9. [Configure Keycloak OIDC (SSO)](#9-configure-keycloak-oidc-sso)
10. [Automating OIDC Configuration via API](#10-automating-oidc-configuration-via-api)
11. [Configure KASM Group Mappings](#11-configure-kasm-group-mappings)

**Part III -- Harvester VDI Autoscaling**
12. [Set the Zone Upstream Auth Address](#12-set-the-zone-upstream-auth-address)
13. [Prepare Harvester for Autoscaling](#13-prepare-harvester-for-autoscaling)
14. [Configure KASM Harvester VM Provider](#14-configure-kasm-harvester-vm-provider)
15. [Create a Docker Agent Pool with Autoscaling](#15-create-a-docker-agent-pool-with-autoscaling)
16. [Create a Linux KasmVNC Server Pool](#16-create-a-linux-kasmvnc-server-pool)
17. [Create a Windows RDP Server Pool](#17-create-a-windows-rdp-server-pool)

**Part IV -- Workspaces & Validation**
18. [Register Workspace Images](#18-register-workspace-images)
19. [End-to-End Validation](#19-end-to-end-validation)
20. [Troubleshooting](#20-troubleshooting)
21. [References](#21-references)

---

# Part I -- Session Delivery Models

## 1. Session Delivery Overview

KASM Workspaces supports four workspace types visible to users, backed by
multiple infrastructure provisioning models. Understanding these is critical
before choosing what to deploy.

### 1.1 Workspace Types

| Type | Protocol | What the User Gets | Infrastructure |
|------|----------|--------------------|----------------|
| **Container** | KasmVNC | Linux desktop/app in a Docker container | Docker Agent Pool |
| **Server** | RDP / KasmVNC / VNC / SSH | Fixed single server | Static registration |
| **Server Pool** | RDP / KasmVNC / VNC / SSH | VM from a pool of identical servers | Server Pool (auto-scaled or static) |
| **Link** | HTTP redirect | URL bookmark on dashboard | None |

### 1.2 Complete Session Delivery Matrix

| Model | OS | Protocol | Density | Boot Time | Auto-scale? | Persistence |
|-------|----|----------|---------|-----------|-------------|-------------|
| Docker container (single app) | Linux | KasmVNC | 8-48/VM | 7-10s | Yes (Agent pools) | Ephemeral (profiles optional) |
| Docker container (full desktop) | Linux | KasmVNC | 8-48/VM | 7-10s | Yes (Agent pools) | Ephemeral (profiles optional) |
| Pre-staged container | Linux | KasmVNC | 8-48/VM | 1-2s | N/A (uses pools) | Ephemeral only |
| Server Pool (RDP) | Windows | RDP | 1:1 per VM | Minutes | Yes | VM state persists |
| Server Pool (KasmVNC) | Linux | KasmVNC | 1:1 per VM | Minutes | Yes | VM state persists |
| Server Pool (VNC) | Any | VNC | 1:1 per VM | Minutes | Yes | VM state persists |
| Server Pool (SSH) | Any | SSH | Multi-session | Minutes | Yes | VM state persists |
| Multi-session RDS | Windows | RDP | Multi-user | Seconds (on running server) | Via RDS | Server state persists |
| Windows RemoteApp | Windows | RDP | Multi-app | Seconds (on running server) | Via RDS | Server state persists |
| Fixed Server | Any | RDP/VNC/KasmVNC/SSH | 1:1 | Always on | No | Persistent VM |
| Link (URL redirect) | N/A | HTTP | N/A | Instant | N/A | N/A |

### 1.3 Harvester vs KubeVirt Provider

Both providers create KubeVirt `VirtualMachine` CRDs. The difference:

| Aspect | Harvester Provider | KubeVirt Provider |
|--------|-------------------|-------------------|
| Target | SUSE Harvester HCI | Any K8s + KubeVirt |
| Disk Image | Harvester image name (native) | PVC to clone (CDI) |
| KubeConfig | Downloaded from Harvester Support page | Standard K8s kubeconfig |
| Networking | Same (pod or multus) | Same (pod or multus) |
| When to use | **You are running Harvester** | Generic K8s with KubeVirt |

**Use the Harvester provider** for this deployment since we run Harvester.

---

## 2. Docker Agent Pools (Container Workspaces)

This is KASM's flagship model -- **Containerized Desktop Infrastructure (CDI)**.
Multiple Docker containers run on a single VM, each streaming an isolated
desktop or application to a user's browser via KasmVNC.

### 2.1 How It Works

```
User Browser
    |
    v (WebSocket / HTTPS)
Traefik -> Kasm Proxy -> Kasm Manager
                            |
                            v (selects Agent with available resources)
                    Docker Agent VM
                    ├── Container: Chrome (user A)
                    ├── Container: VS Code (user B)
                    ├── Container: Desktop (user C)
                    └── ... up to 8-48 per VM
```

- Each Agent VM runs Docker Engine + the KASM Agent service.
- Agent reports available CPU, RAM, and GPUs to the Manager every 30 seconds.
- Manager assigns sessions to Agents based on resource availability.
- Containers are ephemeral by default -- destroyed when the session ends.

### 2.2 Resource Allocation Per Container

Each workspace definition specifies cores, memory, and optional GPUs.
Default: 2 cores, 2768 MB RAM per container.

Density examples (from KASM sizing guide):

| Workspace | Agent VM | Override | Sessions/Agent |
|-----------|----------|----------|----------------|
| 2 CPU, 4 GB | 16 CPU, 64 GB | None | ~8 |
| 4 CPU, 4 GB | 16 CPU, 64 GB | 96 CPU, 80 GB | ~20 |
| 4 CPU, 4 GB | 32 CPU, 128 GB | 192 CPU, 192 GB | ~48 |

### 2.3 Static vs Auto-Scaled Agents

**Static**: Manually install KASM Agent on a VM, register in Admin UI.
Best for: bare metal, pre-existing VMs, fixed-capacity labs.

**Auto-scaled**: KASM provisions/destroys VMs via Harvester API based on
demand thresholds. Best for: elastic capacity, cost optimization.

Both can coexist in the same pool.

### 2.4 Custom Docker Images

KASM provides base images for building custom workspaces:

| Base Image | Purpose |
|-----------|---------|
| `kasmweb/core-ubuntu-jammy` | Minimal core (Ubuntu 22.04) |
| `kasmweb/core-ubuntu-noble` | Minimal core (Ubuntu 24.04) |
| `kasmweb/core-nvidia-focal` | Core + NVIDIA runtime |
| `kasmweb/ubuntu-jammy-desktop` | Full XFCE desktop |

Build custom images with a Dockerfile extending any core image. Push to
Harbor for private distribution. Use rolling tags
(`1.18.0-rolling-weekly`) for automatic security updates.

### 2.5 Sysbox Runtime (Docker-in-Docker)

For workspaces requiring `sudo`, `systemd`, or Docker-in-Docker:

```json
{
  "runtime": "sysbox-runc",
  "entrypoint": ["/sbin/init"],
  "user": 0
}
```

Install Sysbox on Agent VMs. Provides VM-like isolation within containers.
**Incompatible with**: persistent profiles, NVIDIA GPU, cross-runtime storage.

### 2.6 GPU Support (NVIDIA)

- Requires NVIDIA Container Toolkit + drivers >= 560.28.03 on Agent VMs.
- GPUs treated like CPU cores: each agent reports GPU count.
- Default: 1 GPU workspace = 1 session per GPU.
- Override: set agent GPU count higher for GPU sharing (security caveats).
- Vulkan GPU acceleration for Chromium browsers added in 1.18.0.

### 2.7 Network Isolation Per Container

- Default: `kasm_default_network` (bridged Docker network).
- Custom networks: create per-workspace isolation networks.
- IPVLAN: place containers directly on VLANs.
- **Managed Egress** (v1.16+): per-container VPN tunnels (OpenVPN/WireGuard).

---

## 3. Server Pools (Full VM Desktops)

Server Pools deliver full VM desktops -- one VM per user session. This is
the "thick" VDI model, providing complete OS isolation.

### 3.1 Connection Types

| Type | Default Port | Use Case | Multi-Session? |
|------|-------------|----------|----------------|
| **RDP** | 3389 | Windows desktops | Configurable (1:1 or multi) |
| **KasmVNC** | 6901 | Linux desktops (richest features) | Single user |
| **VNC** | 5901 | Generic VNC (basic) | Single user |
| **SSH** | 22 | Terminal access | Multi-session |

### 3.2 RDP Client Modes

| Mode | How | Features |
|------|-----|----------|
| **Web Native** | Browser via Guacamole Connection Proxy | File transfer, clipboard, screenshots |
| **RDP Thick Client** | Native RDP app via KASM RDP Gateway (port 3389) | Smartcard, USB, webcam passthrough |
| **RDP HTTPS Gateway** | RDP tunneled over HTTPS (RD Gateway protocol) | Traverses restrictive firewalls |

### 3.3 Credential Types

| Type | Description |
|------|-------------|
| Static | Fixed username/password |
| SSO_CREATE_USER | KASM creates a local account on the VM dynamically |
| SSO_USERNAME | Pass-through from KASM SSO credentials |
| Smartcard | PKI-based auth |
| Prompt User | User enters credentials at session start |

### 3.4 Require Checkin

For auto-scaled Server Pools, "Require Checkin" prevents users from
connecting to a VM that is still initializing. The VM must explicitly call
the KASM API (via the Kasm Desktop Service on Windows, or a startup script
on Linux) to signal readiness.

### 3.5 Auto-Scale Configuration (Server Pools)

| Field | Description |
|-------|-------------|
| Minimum Available Sessions | Scale up when fewer than N ready sessions exist |
| Max Simultaneous Sessions Per Server | 1 for dedicated VDI, >1 for shared |
| Downscale Backoff (seconds) | Wait before destroying idle VMs |
| Aggressive Scaling | Queue requests and provision on-demand |

---

## 4. Multi-Session Servers (RDS / Shared)

KASM integrates with Microsoft RDS (Remote Desktop Services) for shared
Windows Server sessions.

### 4.1 Architecture

- KASM connects to an RDS Connection Broker (port 3389).
- Multiple users share a single Windows Server VM via RDP sessions.
- Requires Active Directory for SSO.
- KASM handles DLP (clipboard, file transfer, watermarking) on top of RDS.

### 4.2 RemoteApp Publishing

Deliver individual Windows applications (not full desktops):

- Register apps with double-pipe syntax: `||Microsoft Excel`
- Two delivery modes: Web Native (browser) or RDP Thick Client
- Requires the **Kasm Desktop Service** on Windows for web-native cleanup

### 4.3 Kasm Desktop Service (Windows)

A Windows service installed on target servers that provides:

- File upload/download support
- Desktop screenshot previews
- PowerShell script execution at session start/end
- Dynamic local user account creation
- RemoteApp session cleanup
- Cloud storage mapping via WinFSP

Supported: Windows 10, 11, Server 2019, Server 2022 (x86_64).

---

## 5. Persistent Sessions & Profiles

### 5.1 Container Lifecycle States

| State | Disk | Processes | Resources |
|-------|------|-----------|-----------|
| **Running** | Active | Active | Full CPU/RAM |
| **Paused** | Preserved | Frozen in memory | Still holds RAM/swap |
| **Stopped** | Preserved | Terminated | CPU/RAM released |
| **Destroyed** | Lost | Lost | Fully released |

Users can pause, stop, and resume sessions from the KASM control panel.
Session Time Limit controls max lifetime (default: 1 hour, max: 1 year).

### 5.2 Persistent Profiles

Two storage backends for persisting user home directories across
ephemeral container sessions:

**Volume Mount Profiles** (NFS/shared storage):
```
/mnt/kasm_profiles/{username}/{image_id}/
```
Requires shared storage for multi-agent deployments.

**S3-Based Profiles** (recommended for Harvester):
```
s3://kasm-profiles@minio.minio.svc:9000/{username}/
```
Container requests presigned URLs from KASM API -- no S3 credentials
in containers. Size limit enforced via `KASM_PROFILE_SIZE_LIMIT`.

### 5.3 Cloud Storage Mappings

Users can mount Google Drive, Dropbox, OneDrive, Nextcloud, or S3
directly into container sessions. Admin configures providers, users
self-enroll accounts.

### 5.4 Persistent Containers vs Persistent Profiles

| Feature | Persistent Container (Pause/Stop) | Persistent Profile |
|---------|----------------------------------|--------------------|
| What persists | Entire container filesystem + optional process state | User home directory only |
| Container lifecycle | Container survives between sessions | Container destroyed/recreated each session |
| Use case | Dev environments, long-running tasks | Standard user desktops |
| Resource impact | Holds agent resources while paused/stopped | No resource impact when idle |

---

## 6. Session Staging (Pre-Warmed)

### 6.1 What It Is

Maintain a pool of pre-created, already-running containers so users
connect in 1-2 seconds instead of waiting 7-10 seconds for on-demand
provisioning.

### 6.2 How It Works

1. Admin creates a Staging Config: zone, workspace image, desired count.
2. KASM continuously maintains the desired count of running containers.
3. User requests a session -- KASM assigns a pre-staged container.
4. When no staged container matches, falls back to on-demand creation.

### 6.3 Limitations

Staged sessions are **incompatible** with:
- Persistent profiles
- Volume mappings with `{username}` or `{user_id}` tokens
- User-specific file mappings or SSH key injection
- Group-level run configs or web filter policies

### 6.4 Assignment Priority

1. Staged session in current Zone
2. Staged session in alternate Zones
3. On-demand session in current Zone
4. On-demand session in alternate Zones

---

## 7. Choosing a Deployment Model

### Decision Tree

```
Do you need Windows desktops?
├── Yes → Server Pool (RDP) with Harvester auto-scale
│         ├── Full desktop → 1:1 VM per user
│         └── Individual apps → RemoteApp on multi-session RDS
└── No → Linux workloads
         ├── Need VM-level isolation (high security / compliance)?
         │   └── Yes → Server Pool (KasmVNC) with Harvester auto-scale
         │   └── No → Docker Agent Pool (CDI)
         │            ├── Need instant startup? → Add Session Staging
         │            ├── Need Docker-in-Docker? → Enable Sysbox runtime
         │            └── Need GPU? → NVIDIA Container Toolkit on agents
```

### Recommended Starting Architecture for Harvester

| Pool | Type | Use Case | Start With |
|------|------|----------|------------|
| `harvester-agents` | Docker Agent | Linux containers (browsers, dev tools, desktops) | 2 VMs, auto-scale to 10 |
| `harvester-linux-vdi` | Server (KasmVNC) | Full Linux VM desktops (high security) | Optional, 0 VMs standby |
| `harvester-windows-rdp` | Server (RDP) | Windows desktops | Optional, 0 VMs standby |

All three pool types can coexist. Users see a unified workspace dashboard
and KASM routes sessions to the correct pool based on workspace type.

### Comparison with Traditional VDI

| Aspect | KASM CDI (Containers) | KASM Server Pools | Citrix/VMware Horizon |
|--------|----------------------|-------------------|-----------------------|
| Boot time | 7-10s (1-2s staged) | Minutes | Minutes |
| Density | 8-48/VM | 1:1 | 5-15/host |
| Client | Browser only | Browser or RDP client | Thick client preferred |
| Protocol | KasmVNC (WebSocket) | RDP/KasmVNC/VNC/SSH | ICA/HDX, PCoIP/Blast |
| Image mgmt | Docker images (CI/CD native) | VM templates | Golden images, linked clones |
| Cost | Lowest | Higher (1:1) | Highest (proprietary stack) |

---

# Part II -- Keycloak OIDC Integration

## 8. Gather Credentials

### 8.1 Kasm Admin Credentials

```bash
# Admin password
kubectl -n kasm get secret kasm-secrets \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Manager token (used by agents to register)
kubectl -n kasm get secret kasm-secrets \
  -o jsonpath='{.data.manager-token}' | base64 -d; echo
```

Login: `https://kasm.<DOMAIN>` as `admin@kasm.local`.

### 8.2 Keycloak OIDC Client Secret

The `setup-keycloak.sh` script already created a `kasm` OIDC client in the
`<KC_REALM>` realm (default = first segment of DOMAIN, e.g. `example`).

```bash
# If you saved the secrets file during setup:
jq -r '.kasm' scripts/oidc-client-secrets.json

# Or retrieve directly from Keycloak:
# Keycloak Admin > Clients > kasm > Credentials tab > Client Secret
```

### 8.3 Keycloak OIDC Endpoints

| Endpoint | URL |
|----------|-----|
| Issuer | `https://keycloak.<DOMAIN>/realms/<KC_REALM>` |
| Authorization | `https://keycloak.<DOMAIN>/realms/<KC_REALM>/protocol/openid-connect/auth` |
| Token | `https://keycloak.<DOMAIN>/realms/<KC_REALM>/protocol/openid-connect/token` |
| Userinfo | `https://keycloak.<DOMAIN>/realms/<KC_REALM>/protocol/openid-connect/userinfo` |

Verify:
```bash
curl -sk "https://keycloak.<DOMAIN>/realms/<KC_REALM>/.well-known/openid-configuration" | jq .
```

### 8.4 Harvester KubeConfig

1. **Harvester UI** > **Support** (bottom-left) > **Download KubeConfig**.
2. Extract from the YAML:
   - **server** → Harvester API Host
   - **certificate-authority-data** → base64-encoded SSL certificate
   - **token** → API bearer token

---

## 9. Configure Keycloak OIDC (SSO)

### 9.1 Create the Keycloak Group Membership Mapper

The `setup-keycloak.sh` script creates the `kasm` client but does NOT
create a group membership mapper. You must add one.

1. **Keycloak Admin Console** > select your realm.
2. **Clients** > `kasm` > **Client scopes** tab.
3. Click `kasm-dedicated`.
4. **Mappers** > **Configure a new mapper** > **Group Membership**.
5. Configure:

   | Field | Value |
   |-------|-------|
   | Name | `groups` |
   | Token Claim Name | `groups` |
   | Full group path | **OFF** |
   | Add to ID token | ON |
   | Add to access token | ON |
   | Add to userinfo | ON |

6. **Save**.

> **Why OFF?** With it ON, Keycloak sends `/group-name` (slash-prefixed).
> OFF sends `group-name`. This SOP assumes OFF. If you set it ON, prefix
> every group name with `/` in KASM's SSO Group Mappings.

### 9.2 Configure Keycloak Logout URLs

1. **Clients** > `kasm` > **Settings** > **Logout settings**.
2. Set:

   | Field | Value |
   |-------|-------|
   | Front channel logout | OFF |
   | Backchannel logout URL | `https://kasm.<DOMAIN>/api/oidc_backchannel_logout` |
   | Backchannel logout session required | ON |

3. **Save**.

### 9.3 Verify Redirect URIs

1. **Clients** > `kasm` > **Settings**.
2. **Valid redirect URIs**: `https://kasm.<DOMAIN>/*`
3. **Web origins**: `https://kasm.<DOMAIN>`
4. **Save**.

### 9.4 Configure KASM OpenID Provider (Manual UI Method)

1. **KASM Admin** > **Access Management** > **Authentication** > **OpenID** > **Add Config**.
2. Fill in:

   | Field | Value |
   |-------|-------|
   | Enabled | Checked |
   | Display Name | `Continue with Keycloak` |
   | Logo URL | `https://keycloak.<DOMAIN>/resources/favicon.ico` |
   | Auto Login | Unchecked (enable after validation) |
   | Hostname | *(leave empty)* |
   | Default | Checked |
   | Client ID | `kasm` |
   | Client Secret | *(from Step 8.2)* |
   | Authorization URL | `https://keycloak.<DOMAIN>/realms/<KC_REALM>/protocol/openid-connect/auth` |
   | Token URL | `https://keycloak.<DOMAIN>/realms/<KC_REALM>/protocol/openid-connect/token` |
   | User Info URL | `https://keycloak.<DOMAIN>/realms/<KC_REALM>/protocol/openid-connect/userinfo` |
   | Scope | `openid` (one per line:) `email` `profile` |
   | Username Attribute | `preferred_username` |
   | Groups Attribute | `groups` |
   | Redirect URL | `https://kasm.<DOMAIN>/api/oidc_callback` |
   | OpenID Connect Issuer | `https://keycloak.<DOMAIN>/realms/<KC_REALM>` |
   | Logout with OIDC Provider | Checked |
   | Debug | Checked *(disable after validation)* |

3. **Submit**.

> **CRITICAL**: If the `groups` claim is missing from the token, auth fails
> entirely when Groups Attribute is set. Quick fix: temporarily clear Groups
> Attribute, test login, fix mapper, re-enable.

### 9.5 Test OIDC Login

1. Incognito browser > `https://kasm.<DOMAIN>`.
2. Click **"Continue with Keycloak"**.
3. Log in with a Keycloak user.
4. On success, auto-provisioned in KASM.

If login fails:
```bash
kubectl -n kasm logs deployment/kasm-api --tail=200 | grep -i "oidc\|openid\|auth"
```

### 9.6 Post-Validation

1. Disable Debug: edit OpenID config > uncheck Debug > Submit.
2. (Optional) Enable Auto Login for Keycloak-only environments.
   - To reach local admin after Auto Login: `https://kasm.<DOMAIN>/#/staticlogin`

---

## 10. Automating OIDC Configuration via API

### 10.1 The Problem

KASM's public Developer API documentation does not expose endpoints for
OIDC provider configuration. The official docs say "configure via Admin UI".
This breaks infrastructure-as-code workflows.

### 10.2 The Solution: Undocumented Admin API

**This is officially sanctioned by KASM.** From their support documentation:

> *"The Workspaces platform is developed such that any JSON API utilized by
> the graphical user interface can also be instrumented via the developer
> API Keys."*
>
> -- [Using Undocumented APIs (Kasm Support)](https://kasmweb.atlassian.net/wiki/spaces/KCS/pages/10682377/Using+Undocumented+APIs)

The Admin UI is a SPA that calls REST endpoints. Every UI action has a
backing API endpoint. The KASM permission model includes `Auth Create`,
`Auth Modify`, `Auth Delete`, `Auth View` permissions -- these exist
specifically for API key-based access to authentication configuration
endpoints.

### 10.3 How to Discover the Exact Endpoints

**One-time browser interception** (do this once, script forever):

1. Log into KASM Admin UI.
2. Open browser DevTools > **Network** tab > filter by `XHR/Fetch`.
3. Navigate to **Access Management** > **Authentication** > **OpenID** > **Add Config**.
4. Fill in the OIDC fields and click **Submit**.
5. In the Network tab, find the `POST` request.
6. Note the **URL** (e.g., `/api/admin/create_oidc_config`).
7. Note the **Request Body** (JSON payload with all OIDC fields).
8. The equivalent public API endpoint replaces `/api/admin/` with `/api/public/`.

Based on decompiled KASM API code (v1.15.0) and confirmed SAML/LDAP
patterns, the OIDC endpoints are:

| Operation | Endpoint (probable) |
|-----------|---------------------|
| List configs | `POST /api/public/get_oidc_configs` |
| Get single config | `POST /api/public/get_oidc_config` |
| Create config | `POST /api/public/create_oidc_config` |
| Update config | `POST /api/public/update_oidc_config` |
| Delete config | `POST /api/public/delete_oidc_config` |

### 10.4 Scripted OIDC Configuration

**Step 1: Create an API key with Auth permissions.**

KASM Admin > **Settings** > **Developers** > **Add API Key**.
Grant permissions: `Auth View`, `Auth Create`, `Auth Modify`, `Auth Delete`.

**Step 2: Call the API.**

```bash
#!/usr/bin/env bash
# configure-kasm-oidc.sh
# Automates KASM OIDC provider configuration via undocumented admin API.
#
# IMPORTANT: Verify the exact endpoint name by intercepting one browser
# request first (see SOP Section 10.3). The endpoint below is the most
# likely pattern based on SAML/LDAP equivalents in the decompiled API.

set -euo pipefail

KASM_URL="${KASM_URL:-https://kasm.${DOMAIN}}"
API_KEY="${KASM_API_KEY:?Set KASM_API_KEY}"
API_SECRET="${KASM_API_SECRET:?Set KASM_API_SECRET}"

KC_URL="https://keycloak.${DOMAIN}/realms/${KC_REALM}"
KC_CLIENT_SECRET="${KC_KASM_CLIENT_SECRET:?Set KC_KASM_CLIENT_SECRET}"

# Create OIDC config
curl -sk -X POST "${KASM_URL}/api/public/create_oidc_config" \
  -H "Content-Type: application/json" \
  -d "$(cat <<EOF
{
  "api_key": "${API_KEY}",
  "api_key_secret": "${API_SECRET}",
  "oidc_config": {
    "enabled": true,
    "display_name": "Continue with Keycloak",
    "logo_url": "https://keycloak.${DOMAIN}/resources/favicon.ico",
    "auto_login": false,
    "hostname": "",
    "default": true,
    "client_id": "kasm",
    "client_secret": "${KC_CLIENT_SECRET}",
    "authorization_url": "${KC_URL}/protocol/openid-connect/auth",
    "token_url": "${KC_URL}/protocol/openid-connect/token",
    "user_info_url": "${KC_URL}/protocol/openid-connect/userinfo",
    "scope": "openid email profile",
    "username_attribute": "preferred_username",
    "groups_attribute": "groups",
    "redirect_url": "${KASM_URL}/api/oidc_callback",
    "oidc_issuer": "${KC_URL}",
    "logout_with_oidc_provider": true,
    "debug": false
  }
}
EOF
)"

echo "OIDC configuration created."
```

### 10.5 Alternative Automation Approaches (Ranked)

| Rank | Approach | Reliability | Works Post-Install? |
|------|----------|-------------|---------------------|
| 1 | **Undocumented Admin API** (above) | High | Yes |
| 2 | **Slip-Stream Install** (export config YAML, inject at install) | High | No (install-time only) |
| 3 | **System Import/Export API** (export full config, modify, re-import) | Medium | Yes |
| 4 | **Terraform Provider** ([SiM22/terraform-provider-kasm](https://github.com/SiM22/terraform-provider-kasm)) | Medium | Yes (OIDC not yet supported but provider is active) |
| 5 | **Direct PostgreSQL Insert** | Low | Yes (risky, schema may change) |

**Slip-Stream Install** (for fresh deployments):
1. Install KASM once, configure OIDC manually.
2. Export: Diagnostics > System Info > Import/Export > Export Config.
3. Extract `export_data.yaml` from the AES256-encrypted zip.
4. Replace `kasm_release/conf/database/seed_data/default_properties.yaml`
   with your export.
5. Run `install.sh` -- OIDC config is pre-loaded.

See: [Slip-Stream Install](https://kasm.com/docs/latest/guide/import_export/slipstream_install.html)

### 10.6 What Keycloak CAN Automate (Already Done)

The `setup-keycloak.sh` script already handles the Keycloak side:

- Creates the `kasm` OIDC client (confidential, correct redirect URI)
- Generates and stores the client secret
- Outputs the secret for KASM-side configuration

What needs to be **added** to `setup-keycloak.sh`:

- Create the Group Membership mapper on the `kasm` client
- Configure backchannel logout URL

These are straightforward Keycloak Admin API calls:

```bash
# Create Group Membership mapper (add to setup-keycloak.sh Phase 2)
kc_api POST "/realms/${KC_REALM}/clients/${KASM_CLIENT_INTERNAL_ID}/protocol-mappers/models" \
  '{
    "name": "groups",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "consentRequired": false,
    "config": {
      "full.path": "false",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "claim.name": "groups",
      "userinfo.token.claim": "true"
    }
  }'

# Set backchannel logout URL
kc_api PUT "/realms/${KC_REALM}/clients/${KASM_CLIENT_INTERNAL_ID}" \
  "$(kc_api GET "/realms/${KC_REALM}/clients/${KASM_CLIENT_INTERNAL_ID}" | \
    jq '.attributes."backchannel.logout.url" = "https://kasm.'${DOMAIN}'/api/oidc_backchannel_logout" |
        .attributes."backchannel.logout.session.required" = "true"')"
```

---

## 11. Configure KASM Group Mappings

### 11.1 Create KASM Groups

KASM ships with **Administrators** and **All Users**. Create additional groups:

| KASM Group | Priority | Description |
|------------|----------|-------------|
| Administrators | 10 | Full admin access (exists) |
| Developers | 20 | VS Code, Terminal, Desktop, Browsers |
| All Users | 100 | Browsers only (exists) |

> Priority: lower number = higher priority for conflicting settings.

### 11.2 Add SSO Group Mappings

For each KASM group > **SSO Group Mappings** tab > **Add SSO Mapping**:

| Keycloak Group | KASM SSO Group Attribute | KASM Group |
|---------------|-------------------------|------------|
| `aegis-admins` | `aegis-admins` | Administrators |
| `aegis-developers` | `aegis-developers` | Developers |
| `aegis-users` | `aegis-users` | All Users |

SSO Provider: `OpenID - Continue with Keycloak`

> If Full group path = ON in Keycloak mapper, prefix with `/`:
> `/aegis-admins`, `/aegis-developers`, `/aegis-users`.

### 11.3 Group Permissions

**Developers**: Allow all workspace images, 8-hour session limit, 20-min
idle timeout, clipboard both directions, file upload/download enabled.

**All Users**: Browsers only, 4-hour session limit, 10-min idle timeout,
clipboard download only, file transfer disabled.

### 11.4 Verify

Login via Keycloak as a user in `aegis-developers`. Check KASM Admin >
Users > user > Groups tab. They should be in both `All Users` and
`Developers`. Group membership re-evaluates on every login.

---

# Part III -- Harvester VDI Autoscaling

## 12. Set the Zone Upstream Auth Address

**Must be done before configuring any autoscaling.**

1. **KASM Admin** > **Infrastructure** > **Zones** > click **default**.
2. Set **Upstream Auth Address**: `kasm.<DOMAIN>`
3. **IMPORTANT**: Do NOT leave as `$request_host$` (default). Agent VMs
   need an actual hostname they can reach to register.
4. **Submit**.

---

## 13. Prepare Harvester for Autoscaling

### 13.1 Create Namespace

**Harvester UI** > **Namespaces** > **Create**: `kasm-autoscale`

### 13.2 Upload Ubuntu Cloud Image

**Harvester UI** > **Images** > **Create**:

| Field | Value |
|-------|-------|
| Namespace | `kasm-autoscale` |
| Name | `ubuntu-22.04-cloud` |
| URL | `https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img` |

Wait for status: Active.

### 13.3 VM Network (if needed)

If agents need the management network: **Networks** > **Create** > cluster
network `mgmt` > Name: `vm-network`.

For pod networking (default), skip this.

### 13.4 SSH Key Pair

```bash
ssh-keygen -t ed25519 -f ~/.ssh/kasm-agent-key -N "" -C "kasm-agent"
cat ~/.ssh/kasm-agent-key.pub
```

---

## 14. Configure KASM Harvester VM Provider

### 14.1 Docker Agent VM Provider

**KASM Admin** > **Infrastructure** > **VM Provider Configs** > **Add Config** > **Harvester**:

| Field | Value |
|-------|-------|
| Name | `harvester-docker-agents` |
| Max Instances | `10` |
| Host | *(Harvester API URL from KubeConfig `server` field)* |
| SSL Certificate | *(PEM-decoded cert from KubeConfig)* |
| API Token | *(token from KubeConfig)* |
| VM Namespace | `kasm-autoscale` |
| VM SSH Public Key | *(~/.ssh/kasm-agent-key.pub)* |
| Cores | `8` |
| Memory (GiB) | `16` |
| Disk Image | `ubuntu-22.04-cloud` |
| Disk Size (GiB) | `100` |
| Network Type | `pod` |
| Interface Type | `masquerade` |

**Startup Script** (official kasmtech cloud-init for Harvester Docker Agents):

```yaml
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
  - sudo
users:
  - name: kasm-admin
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - {ssh_key}

write_files:
  - path: /usr/local/bin/apt-wait.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      echo "Waiting for apt lock to be free..."
      while sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 ; do
          sleep 1
        done
        while sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 ; do
          sleep 1
        done
        if [ -f /var/log/unattended-upgrades/unattended-upgrades.log ]; then
          while sudo fuser /var/log/unattended-upgrades/unattended-upgrades.log >/dev/null 2>&1 ; do
            sleep 1
          done
        fi
runcmd:
  - - systemctl
    - enable
    - --now
    - qemu-guest-agent.service
  - IP=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+')
  - cd /tmp
  - wget https://kasm-static-content.s3.amazonaws.com/kasm_release_1.18.1.tar.gz -O kasm.tar.gz
  - tar -xf kasm.tar.gz
  - |
    if [ -z "$GIVEN_FQDN" ] ||  [ "$GIVEN_FQDN" == "None" ]  ;
    then
        AGENT_ADDRESS=$IP
    else
        AGENT_ADDRESS=$GIVEN_FQDN
    fi
  - /usr/local/bin/apt-wait.sh
  - sleep 10
  - /usr/local/bin/apt-wait.sh
  - bash kasm_release/install.sh -e -S agent -p $AGENT_ADDRESS -m {upstream_auth_address} -i {server_id} -r {provider_name} -M {manager_token}
  - rm kasm.tar.gz
  - rm -rf kasm_release
swap:
   filename: /var/swap.1
   size: 8589934592
```

> Template variables (`{ssh_key}`, `{upstream_auth_address}`, `{server_id}`,
> `{provider_name}`, `{manager_token}`) are replaced by KASM at provisioning
> time. Do NOT replace them manually.

### 14.2 Verify Connectivity

After saving, KASM validates the Harvester API connection. If it fails:

```bash
kubectl -n kasm exec deployment/kasm-api -- \
  curl -sk -H "Authorization: Bearer <TOKEN>" \
  "https://<HARVESTER_HOST>/v1/harvester/namespaces"
```

---

## 15. Create a Docker Agent Pool with Autoscaling

### 15.1 Create Pool

**Infrastructure** > **Pools** > **Add**:
- Name: `harvester-agents`
- Type: **Docker Agent**

### 15.2 AutoScale Config

Pool > **AutoScale** tab > **Add AutoScale Config**:

| Field | Value |
|-------|-------|
| VM Provider | `harvester-docker-agents` |
| Enabled | Checked |
| Standby Cores | `8` |
| Standby Memory (MB) | `8000` |
| Standby GPUs | `0` |
| Downscale Backoff (seconds) | `900` |
| Aggressive Scaling | Unchecked |
| Register DNS | Unchecked |

Optional: set a schedule for business-hours-only scaling.

### 15.3 Verify

KASM provisions a VM within minutes. Watch:
- **KASM Admin** > **Infrastructure** > **Docker Agents** (status: Provisioning → Online)
- **Harvester UI** > **Virtual Machines** > namespace `kasm-autoscale`

If stuck, SSH in and check cloud-init:
```bash
ssh -i ~/.ssh/kasm-agent-key kasm-admin@<VM_IP>
sudo cat /var/log/cloud-init-output.log
```

---

## 16. Create a Linux KasmVNC Server Pool

For full Linux VM desktops with complete OS isolation (the "thick" model).

### 16.1 VM Provider Config

**Infrastructure** > **VM Provider Configs** > **Add** > **Harvester**:

| Field | Value |
|-------|-------|
| Name | `harvester-linux-vdi` |
| Max Instances | `5` |
| Cores | `4` |
| Memory (GiB) | `8` |
| Disk Image | `ubuntu-22.04-cloud` |
| Disk Size (GiB) | `50` |

**Startup Script**: Use `linux_vms/ubuntu.sh` from
[kasmtech/workspaces-autoscale-startup-scripts](https://github.com/kasmtech/workspaces-autoscale-startup-scripts/tree/release/1.18.1/linux_vms).
This installs KasmVNC + XFCE desktop and registers the VM.

Add qemu-guest-agent installation to the script (uncomment or add):
```bash
apt-get update && apt install -y qemu-guest-agent
systemctl enable --now qemu-guest-agent.service
```

### 16.2 Create Server Pool

**Infrastructure** > **Pools** > **Add**:
- Name: `harvester-linux-vdi`
- Type: **Server**
- Connection Type: **KasmVNC**
- Connection Port: `6901`

Attach AutoScale config with the `harvester-linux-vdi` VM provider.
Set **Minimum Available Sessions**: `1`.

### 16.3 Create Workspace

**Workspaces** > **Add Workspace**:
- Type: **Server Pool**
- Server Pool: `harvester-linux-vdi`
- Friendly Name: `Linux Desktop (Full VM)`

---

## 17. Create a Windows RDP Server Pool

### 17.1 Build Windows Template in Harvester

1. Upload Windows Server 2022 ISO and [VirtIO drivers ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso) to Harvester Images.
2. Create VM: 4 CPU, 8 GiB RAM, 60 GiB VirtIO boot disk, two SATA CD-ROMs.
3. Install Windows (load VirtIO SCSI driver during disk selection).
4. Post-install:
   - Install all VirtIO drivers from VirtIO CD.
   - Install **QEMU Guest Agent**: `D:\guest-agent\qemu-ga-x86_64.msi`.
   - Install **Cloudbase-Init** (LocalSystem, no sysprep, no shutdown).
   - Enable **Remote Desktop**.
   - Enable audio: `Set-Service Audiosrv -StartupType Automatic`.
5. Shut down, remove CD-ROMs, **Generate Template** > **With Data** > name: `win2022-kasm-rdp`.

### 17.2 VM Provider Config

| Field | Value |
|-------|-------|
| Name | `harvester-windows-rdp` |
| Max Instances | `5` |
| Cores | `4` |
| Memory (GiB) | `8` |
| Disk Image | `win2022-kasm-rdp` |
| Disk Size (GiB) | `60` |
| Enable EFI Boot | Checked |

Startup Script: PowerShell scripts from
[kasmtech/workspaces-autoscale-startup-scripts/windows_vms](https://github.com/kasmtech/workspaces-autoscale-startup-scripts/tree/release/1.18.1/windows_vms).

### 17.3 Create Server Pool

- Name: `harvester-windows-rdp`
- Type: **Server**
- Connection Type: **RDP**
- Connection Port: `3389`
- Minimum Available Sessions: `2`
- Require Checkin: **Checked** (wait for Kasm Desktop Service)

### 17.4 Create Workspace

- Type: **Server Pool**
- Server Pool: `harvester-windows-rdp`
- Friendly Name: `Windows Desktop`

---

# Part IV -- Workspaces & Validation

## 18. Register Workspace Images

### 18.1 Add Workspace Registry

**Workspaces** > **Registry** > **Add Registry**:
- URL: `https://registry.kasmweb.com/1.0/`

Browse and install images directly.

### 18.2 Manual Registration

| Friendly Name | Docker Image | Cores | RAM (MB) |
|--------------|-------------|-------|----------|
| Chrome | `kasmweb/chrome:1.18.0` | 2 | 2768 |
| Firefox | `kasmweb/firefox:1.18.0` | 2 | 2768 |
| Ubuntu Desktop | `kasmweb/desktop:1.18.0` | 2 | 2768 |
| VS Code | `kasmweb/vs-code:1.18.0` | 2 | 2768 |
| Terminal | `kasmweb/terminal:1.18.0` | 1 | 1024 |

For Harbor proxy cache: set Docker Registry to `harbor.<DOMAIN>/dockerhub`.

### 18.3 Assign to Groups

Each workspace > **Groups** tab > add appropriate groups.

---

## 19. End-to-End Validation

### 19.1 Admin Login Test

Login as `admin@kasm.local`, launch Chrome workspace, verify streaming.

### 19.2 SSO Login Test

Incognito > `https://kasm.<DOMAIN>` > **Continue with Keycloak** > login >
verify group-appropriate workspaces visible.

### 19.3 Autoscale Test

Launch sessions until standby exhausted > verify new VM provisions >
end sessions > verify idle VM destroyed after backoff.

### 19.4 Logout Test

Logout from KASM > verify Keycloak session also terminated (backchannel).

---

## 20. Troubleshooting

### OIDC Login Fails

1. Is the `groups` mapper configured? Missing claim = auth failure.
   Quick fix: temporarily clear Groups Attribute in KASM OIDC config.
2. Check API logs: `kubectl -n kasm logs deployment/kasm-api --tail=200 | grep -i oidc`
3. Debug mode logs full token payload. Check `groups` claim.
4. Verify redirect URI: `https://kasm.<DOMAIN>/api/oidc_callback`
5. TLS issues: Debug mode disables OIDC TLS verification.
   See [GitHub #834](https://github.com/kasmtech/workspaces-issues/issues/834).

### Groups Not Mapping

1. Check token claims (Debug mode).
2. Slash prefix: if Keycloak has Full group path = ON, KASM mapping must
   include `/` prefix.
3. SSO provider name must match exactly: `OpenID - Continue with Keycloak`.

### Agent VM Stuck Provisioning

1. SSH in: `ssh -i ~/.ssh/kasm-agent-key kasm-admin@<VM_IP>`
2. Check cloud-init: `sudo cat /var/log/cloud-init-output.log`
3. Common causes: QEMU Guest Agent not running, Upstream Auth Address wrong,
   manager token expired, DNS resolution failing, tarball download failure.

### Desktop Sessions Timeout

Apply Traefik timeout HelmChartConfig (1800s):
```bash
kubectl apply -f services/harbor/traefik-timeout-helmchartconfig.yaml
```

### Local Admin After Auto-Login

`https://kasm.<DOMAIN>/#/staticlogin`

---

## 21. References

### Official Documentation
- [KASM Keycloak OIDC Setup](https://www.kasmweb.com/docs/develop/guide/oidc/keycloak.html)
- [KASM OpenID Authentication](https://www.kasmweb.com/docs/latest/guide/oidc.html)
- [KASM Developer API](https://www.kasmweb.com/docs/latest/developers/developer_api.html)
- [Using Undocumented APIs (Kasm Support)](https://kasmweb.atlassian.net/wiki/spaces/KCS/pages/10682377/Using+Undocumented+APIs)
- [Slip-Stream Install](https://kasm.com/docs/latest/guide/import_export/slipstream_install.html)
- [KASM Harvester AutoScale Provider](https://www.kasmweb.com/docs/develop/how_to/infrastructure_components/autoscale_providers/harvester.html)
- [KASM KubeVirt VM Provider](https://kasm.com/docs/latest/guide/compute/vm_providers/kubevirt.html)
- [AutoScale Config (Docker Agent)](https://kasmweb.com/docs/develop/how_to/infrastructure_components/autoscale_config_docker_agent.html)
- [AutoScale Config (Server Pool)](https://kasm.com/docs/latest/how_to/infrastructure_components/autoscale_config_server.html)
- [KASM Pools](https://www.kasmweb.com/docs/latest/guide/compute/pools.html)
- [KASM VM Provider Configs](https://www.kasmweb.com/docs/latest/guide/compute/vm_providers.html)
- [KASM Groups and Permissions](https://www.kasmweb.com/docs/latest/guide/groups.html)
- [KASM Deployment Zones](https://www.kasmweb.com/docs/develop/guide/zones/deployment_zones.html)
- [KASM Workspace Registry](https://www.kasmweb.com/docs/latest/guide/workspace_registry.html)
- [KASM Persistent Profiles](https://www.kasmweb.com/docs/latest/guide/persistent_data/persistent_profiles.html)
- [KASM Session Staging](https://kasm.com/docs/latest/guide/staging.html)
- [KASM Session Sharing](https://kasm.com/docs/latest/guide/session_sharing.html)
- [KASM GPU Acceleration](https://kasm.com/docs/latest/how_to/gpu.html)
- [KASM Sysbox Runtime](https://www.kasmweb.com/docs/develop/how_to/sysbox_runtime.html)
- [KASM Network Isolation](https://kasm.com/docs/latest/how_to/restrict_to_docker_network.html)
- [KASM Managed Egress](https://www.kasmweb.com/docs/latest/guide/egress.html)
- [KASM Windows Overview](https://www.kasmweb.com/docs/latest/guide/windows/overview.html)
- [KASM RemoteApps](https://www.kasmweb.com/docs/latest/how_to/windows_remote_apps.html)
- [KASM Connection Proxies](https://www.kasmweb.com/docs/develop/guide/connection_proxies.html)
- [KASM Sizing Guide](https://kasm.com/docs/latest/how_to/sizing_operations.html)
- [KASM Building Custom Images](https://www.kasmweb.com/docs/develop/how_to/building_images.html)
- [KASM Kubernetes Installation](https://www.kasmweb.com/docs/develop/install/kubernetes.html)
- [KASM 1.18.0 Release Notes](https://docs.kasm.com/docs/release_notes/1.18.0)

### GitHub
- [kasmtech/kasm-helm](https://github.com/kasmtech/kasm-helm)
- [kasmtech/workspaces-autoscale-startup-scripts](https://github.com/kasmtech/workspaces-autoscale-startup-scripts)
- [kasmtech/workspaces-issues](https://github.com/kasmtech/workspaces-issues)
- [SiM22/terraform-provider-kasm](https://github.com/SiM22/terraform-provider-kasm)
- [kasmweb-decompilation/api](https://github.com/kasmweb-decompilation/api)
- [SplinterHead/Kasm-python](https://github.com/SplinterHead/Kasm-python)

### Architecture / Blog
- [VDI on Kubernetes: Rancher + Harvester + KASM](https://medium.kasm.com/vdi-on-kubernetes-for-enterprises-rancher-harvester-kasm-92652d46d8ca)
- [Installing KASM on Rancher Using Official Helm Chart](https://medium.kasm.com/installing-kasm-workspaces-on-rancher-using-the-official-helm-chart-a4c4ef918e35)
- [CDI: Containerized Desktop Infrastructure](https://medium.kasm.com/containerized-desktop-infrastructure-cdi-improved-efficiency-scalability-and-security-9e5780f73f03)
- [Rancher GA Announcement (Dec 2025)](https://www.einpresswire.com/article/876608994/rancher-announces-general-availability-of-kasm-kubernetes-helm-partner-chart)
