# Kasm Workspaces -- Post-Install Configuration SOP

> Standard Operating Procedure for configuring Kasm Workspaces after Helm
> deployment. Covers Keycloak SSO, Harvester VDI autoscaling, and workspace
> image registration.
>
> **Audience**: Platform engineer with Harvester admin + Kasm admin access.
>
> **Prerequisites**: Kasm 1.18.1 control plane running on RKE2 (see README.md
> for Helm install steps). Keycloak realm created by `setup-keycloak.sh`.

---

## Table of Contents

1. [Gather Credentials](#1-gather-credentials)
2. [Configure Keycloak OIDC (SSO)](#2-configure-keycloak-oidc-sso)
3. [Configure KASM Group Mappings](#3-configure-kasm-group-mappings)
4. [Set the Zone Upstream Auth Address](#4-set-the-zone-upstream-auth-address)
5. [Prepare Harvester for Autoscaling](#5-prepare-harvester-for-autoscaling)
6. [Configure KASM Harvester VM Provider](#6-configure-kasm-harvester-vm-provider)
7. [Create a Docker Agent Pool with Autoscaling](#7-create-a-docker-agent-pool-with-autoscaling)
8. [Register Workspace Images](#8-register-workspace-images)
9. [End-to-End Validation](#9-end-to-end-validation)
10. [Windows RDP Server Pool (Optional)](#10-windows-rdp-server-pool-optional)
11. [Troubleshooting](#11-troubleshooting)
12. [References](#12-references)

---

## 1. Gather Credentials

Before touching any UI, collect these values. You will need them repeatedly.

### 1.1 Kasm Admin Credentials

```bash
# Admin password
kubectl -n kasm get secret kasm-secrets \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Manager token (used by agents to register)
kubectl -n kasm get secret kasm-secrets \
  -o jsonpath='{.data.manager-token}' | base64 -d; echo
```

Login: `https://kasm.<DOMAIN>` as `admin@kasm.local`.

### 1.2 Keycloak OIDC Client Secret

The `setup-keycloak.sh` script already created a `kasm` OIDC client in the
`<KC_REALM>` realm (default realm name = first segment of DOMAIN, e.g.
`example` for `example.com`).

```bash
# If you saved the secrets file during setup:
jq -r '.kasm' scripts/oidc-client-secrets.json

# Or retrieve directly from Keycloak:
# Keycloak Admin > Clients > kasm > Credentials tab > Client Secret
```

### 1.3 Keycloak OIDC Endpoints

All endpoints derive from the well-known URL. Replace `<DOMAIN>` and
`<KC_REALM>` with your values:

| Endpoint | URL |
|----------|-----|
| Issuer | `https://keycloak.<DOMAIN>/realms/<KC_REALM>` |
| Authorization | `https://keycloak.<DOMAIN>/realms/<KC_REALM>/protocol/openid-connect/auth` |
| Token | `https://keycloak.<DOMAIN>/realms/<KC_REALM>/protocol/openid-connect/token` |
| Userinfo | `https://keycloak.<DOMAIN>/realms/<KC_REALM>/protocol/openid-connect/userinfo` |

You can verify these by fetching the discovery document:

```bash
curl -sk "https://keycloak.<DOMAIN>/realms/<KC_REALM>/.well-known/openid-configuration" | jq .
```

### 1.4 Harvester KubeConfig

You will need three values from the Harvester KubeConfig YAML:

1. Log into the **Harvester UI** (not Rancher).
2. Click **Support** (bottom-left gear icon) > **Download KubeConfig**.
3. Open the downloaded YAML and extract:
   - **server** field → this is the Harvester API Host
   - **certificate-authority-data** → base64-encoded SSL certificate
   - **token** (under `user:`) → API bearer token

Keep this file safe -- it contains full Harvester admin credentials.

---

## 2. Configure Keycloak OIDC (SSO)

### 2.1 Verify / Create the Keycloak Group Membership Mapper

The `setup-keycloak.sh` script creates the `kasm` client but does NOT
create a group membership mapper automatically. You must add one.

1. **Keycloak Admin Console** > select your realm (`<KC_REALM>`).
2. **Clients** > click `kasm` > **Client scopes** tab.
3. Click `kasm-dedicated` (the dedicated scope for this client).
4. **Mappers** tab > **Configure a new mapper** > select **Group Membership**.
5. Configure:

   | Field | Value |
   |-------|-------|
   | Name | `groups` |
   | Token Claim Name | `groups` |
   | Full group path | **OFF** |
   | Add to ID token | ON |
   | Add to access token | ON |
   | Add to userinfo | ON |
   | Add to token introspection | ON |

6. **Save**.

> **Why Full group path = OFF?** With it ON, Keycloak sends `/group-name`
> (prefixed with `/`). With it OFF, it sends `group-name`. This SOP assumes
> OFF for cleaner KASM mapping. If you set it ON, you must prefix every group
> name with `/` in KASM's SSO Group Mappings (Step 3).

### 2.2 Verify Keycloak Logout URLs

1. Still in **Clients** > `kasm` > **Settings** tab.
2. Scroll to the **Logout settings** section.
3. Set:

   | Field | Value |
   |-------|-------|
   | Front channel logout | OFF |
   | Backchannel logout URL | `https://kasm.<DOMAIN>/api/oidc_backchannel_logout` |
   | Backchannel logout session required | ON |

4. **Save**.

> Backchannel logout is recommended over front-channel. It is server-to-server
> (Keycloak calls KASM directly), more reliable than browser-redirect-based
> front-channel logout.

### 2.3 Verify Redirect URIs

1. Still in **Clients** > `kasm` > **Settings** tab.
2. Ensure **Valid redirect URIs** includes: `https://kasm.<DOMAIN>/*`
3. Ensure **Web origins** includes: `https://kasm.<DOMAIN>`
4. **Save**.

### 2.4 Configure KASM OpenID Provider

1. **KASM Admin UI** > **Access Management** > **Authentication** > **OpenID**.
2. Click **Add Config**.
3. Fill in every field exactly:

   | Field | Value |
   |-------|-------|
   | Enabled | Checked |
   | Display Name | `Continue with Keycloak` |
   | Logo URL | `https://keycloak.<DOMAIN>/resources/favicon.ico` |
   | Auto Login | Unchecked (set to checked later once validated) |
   | Hostname | *(leave empty)* |
   | Default | Checked |
   | Client ID | `kasm` |
   | Client Secret | *(from Step 1.2)* |
   | Authorization URL | `https://keycloak.<DOMAIN>/realms/<KC_REALM>/protocol/openid-connect/auth` |
   | Token URL | `https://keycloak.<DOMAIN>/realms/<KC_REALM>/protocol/openid-connect/token` |
   | User Info URL | `https://keycloak.<DOMAIN>/realms/<KC_REALM>/protocol/openid-connect/userinfo` |
   | Scope | `openid` (one per line:) |
   | | `email` |
   | | `profile` |
   | Username Attribute | `preferred_username` |
   | Groups Attribute | `groups` |
   | Redirect URL | `https://kasm.<DOMAIN>/api/oidc_callback` |
   | OpenID Connect Issuer | `https://keycloak.<DOMAIN>/realms/<KC_REALM>` |
   | Logout with OIDC Provider | Checked |
   | Debug | Checked *(enable during initial setup, disable later)* |

4. Click **Submit**.

> **CRITICAL**: If the `groups` claim is missing from the token (e.g., mapper
> not configured), authentication will **fail entirely** when Groups Attribute
> is set. If you hit login errors, temporarily clear the Groups Attribute
> field, test login, then fix the mapper and re-enable.

### 2.5 Test OIDC Login

1. Open an incognito/private browser window.
2. Navigate to `https://kasm.<DOMAIN>`.
3. You should see a **"Continue with Keycloak"** button below the local login.
4. Click it. You should be redirected to Keycloak's login page.
5. Log in with a Keycloak user.
6. On success, you are redirected back to KASM and auto-provisioned as a user.

**If login fails**, check KASM logs:

```bash
kubectl -n kasm logs deployment/kasm-api --tail=100 | grep -i oidc
```

With Debug enabled, the full token payload is logged -- check that the
`groups` claim is present.

### 2.6 Disable Debug Mode

Once OIDC is working:

1. **KASM Admin** > **Access Management** > **Authentication** > **OpenID**.
2. Edit your config > uncheck **Debug**.
3. **Submit**.

### 2.7 (Optional) Enable Auto Login

If Keycloak is your only auth source and you want users to skip the KASM
login page entirely:

1. Edit the OpenID config > check **Auto Login**.
2. **Submit**.

To reach the local admin login after enabling Auto Login, navigate to:
`https://kasm.<DOMAIN>/#/staticlogin`

---

## 3. Configure KASM Group Mappings

KASM groups control which workspace images users can access, session limits,
clipboard/file transfer policies, and admin permissions. SSO Group Mappings
link Keycloak groups to KASM groups so membership is synchronized on every
login.

### 3.1 Create KASM Groups

KASM ships with two default groups: **Administrators** and **All Users**.
Create additional groups as needed.

1. **KASM Admin** > **Access Management** > **Groups**.
2. Click **Add Group** for each:

   | KASM Group Name | Priority | Description |
   |----------------|----------|-------------|
   | Administrators | 10 | *(already exists)* Full admin access |
   | Developers | 20 | VS Code, Terminal, Desktop, Browsers |
   | All Users | 100 | *(already exists)* Browsers only |

   > **Priority**: lower number = higher priority. When a user belongs to
   > multiple groups with conflicting settings, the lowest-priority-number
   > group wins.

### 3.2 Add SSO Group Mappings

For **each** KASM group that should map to a Keycloak group:

1. **Access Management** > **Groups** > click the group name (e.g., `Administrators`).
2. Click the **SSO Group Mappings** tab.
3. Click **Add SSO Mapping**.
4. Configure:

   | Field | Value |
   |-------|-------|
   | SSO Provider | `OpenID - Continue with Keycloak` |
   | Group Attributes | *(Keycloak group name -- see table below)* |

5. Click **Submit**.

#### Mapping Table

| Keycloak Group | KASM SSO Group Attribute | KASM Group |
|---------------|-------------------------|------------|
| `aegis-admins` | `aegis-admins` | Administrators |
| `aegis-developers` | `aegis-developers` | Developers |
| `aegis-users` | `aegis-users` | All Users |

> If you set **Full group path = ON** in the Keycloak mapper (Step 2.1),
> prefix each value with `/`: `/aegis-admins`, `/aegis-developers`, etc.

### 3.3 Configure Group Permissions

For each group, configure which workspaces are accessible:

1. **Groups** > click group > **Settings** tab.
2. Key settings per group:

**Administrators** (already configured by default):
- All permissions enabled.

**Developers**:
- Allow Images: Chrome, Firefox, Ubuntu Desktop, VS Code, Terminal
- Session Time Limit: 28800 (8 hours)
- Idle Session Timeout: 1200 (20 minutes)
- Enable clipboard (both directions)
- Enable file upload/download

**All Users**:
- Allow Images: Chrome, Firefox only
- Session Time Limit: 14400 (4 hours)
- Idle Session Timeout: 600 (10 minutes)
- Clipboard: download only
- File upload: disabled
- File download: disabled

### 3.4 Verify Group Mapping

1. Log in via Keycloak as a user who belongs to `aegis-developers`.
2. In KASM Admin, navigate to **Access Management** > **Users**.
3. Find the auto-provisioned user and click their name.
4. Check the **Groups** tab -- they should be in both `All Users` and
   `Developers`.
5. On subsequent logins, group membership is re-evaluated from the Keycloak
   token. Removing a user from the Keycloak group removes them from the
   KASM group on next login.

---

## 4. Set the Zone Upstream Auth Address

Before configuring autoscaling, you **must** set the Upstream Auth Address
in the default Zone. Autoscaled agent VMs use this address to register back
to the KASM manager.

1. **KASM Admin** > **Infrastructure** > **Zones**.
2. Click the **default** zone (or your zone name).
3. Set **Upstream Auth Address** to the KASM proxy service address that
   agent VMs can reach. Options:

   - If agent VMs are on the same Harvester cluster network:
     `kasm.<DOMAIN>` (external FQDN -- routed through Traefik)
   - If using pod networking: the kasm-proxy ClusterIP won't work (VMs are
     outside K8s). You must use the external FQDN.

4. **IMPORTANT**: Do NOT leave this as `$request_host$` (the default). That
   variable resolves in the browser context, not on the agent VM. The agent
   VM needs an actual hostname/IP it can reach.

5. Click **Submit**.

---

## 5. Prepare Harvester for Autoscaling

These steps are performed in the **Harvester UI** (not Rancher, not KASM).

### 5.1 Create a Namespace for Autoscaled VMs

1. **Harvester UI** > **Namespaces**.
2. Click **Create**.
3. Name: `kasm-autoscale`.
4. **Create**.

> Keeping autoscaled VMs in a dedicated namespace makes cleanup and resource
> quota management easier.

### 5.2 Upload an Ubuntu Cloud Image

1. **Harvester UI** > **Images** (under Advanced).
2. Click **Create**.
3. Configure:

   | Field | Value |
   |-------|-------|
   | Namespace | `kasm-autoscale` |
   | Name | `ubuntu-22.04-cloud` |
   | URL | `https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img` |

4. Click **Create** and wait for the download to complete (status: Active).

> You can also use Ubuntu 24.04 (`noble`) -- the startup script is compatible.
> Rocky Linux cloud images also work but the startup script uses `apt`, so
> you would need to adapt it to `dnf`.

### 5.3 Create a VM Network (if not already present)

If your agent VMs need to be on the management network (same as worker nodes):

1. **Harvester UI** > **Networks** (under Advanced > Cluster Networks/Configs).
2. If a `vm-network` or `untagged-network` already exists on `mgmt`, skip
   this step.
3. Otherwise: **Create** > select cluster network `mgmt` > VLAN ID: leave
   empty for untagged > Name: `vm-network`.

> For pod networking (default in KASM's Harvester provider), you don't need
> a VM network -- VMs get a pod IP directly. Choose based on your network
> architecture.

### 5.4 Generate an SSH Key Pair for Agent Access

```bash
ssh-keygen -t ed25519 -f ~/.ssh/kasm-agent-key -N "" -C "kasm-agent"
cat ~/.ssh/kasm-agent-key.pub
```

Copy the public key -- you will paste it into the KASM VM Provider config.

---

## 6. Configure KASM Harvester VM Provider

This is done in the **KASM Admin UI**.

### 6.1 Create VM Provider Config

1. **KASM Admin** > **Infrastructure** > **VM Provider Configs**.
2. Click **Add Config**.
3. Select Provider: **Harvester**.
4. Fill in:

   | Field | Value | Notes |
   |-------|-------|-------|
   | Name | `harvester-docker-agents` | Descriptive name |
   | Max Instances | `10` | Upper limit on concurrent VMs |
   | Host | *(Harvester API URL from KubeConfig `server` field)* | e.g., `https://harvester.example.com/k8s/clusters/local` |
   | SSL Certificate | *(base64-decoded `certificate-authority-data` from KubeConfig)* | Paste the actual PEM cert, NOT the base64 string |
   | API Token | *(token from KubeConfig `user:` section)* | |
   | VM Namespace | `kasm-autoscale` | The namespace from Step 5.1 |
   | VM SSH Public Key | *(contents of `~/.ssh/kasm-agent-key.pub`)* | |
   | Cores | `8` | Per-VM CPU cores (adjust to your capacity) |
   | Memory (GiB) | `16` | Per-VM RAM |
   | Disk Image | `ubuntu-22.04-cloud` | Image name from Step 5.2 |
   | Disk Size (GiB) | `100` | Boot disk size |
   | Network Type | `pod` | Use `multus` if you need a specific VLAN |
   | Interface Type | `masquerade` | Use `bridge` for multus flat networks |
   | Network Name | *(leave blank for pod networking)* | Required only for multus |
   | Enable TPM | Unchecked | |
   | Enable EFI Boot | Unchecked | |
   | Enable Secure Boot | Unchecked | |

5. **Startup Script**: Paste the cloud-init YAML below (this is the
   official kasmtech startup script for Harvester Docker Agents):

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

> **Template variables** (`{ssh_key}`, `{upstream_auth_address}`, `{server_id}`,
> `{provider_name}`, `{manager_token}`) are replaced automatically by KASM
> at provisioning time. Do NOT replace them manually.

6. Click **Save**.

### 6.2 Verify Connectivity

After saving, KASM will attempt to validate the Harvester API connection.
If it fails:

- Check the Host URL is correct (include the full path, e.g.,
  `/k8s/clusters/local` if applicable).
- Check the SSL Certificate is the PEM-decoded cert (not base64-encoded).
- Check the API Token has not expired.
- Check network connectivity: the KASM API pod must be able to reach the
  Harvester API. Test from within the cluster:

```bash
kubectl -n kasm exec deployment/kasm-api -- \
  curl -sk -H "Authorization: Bearer <TOKEN>" \
  "https://<HARVESTER_HOST>/v1/harvester/namespaces"
```

---

## 7. Create a Docker Agent Pool with Autoscaling

### 7.1 Create the Pool

1. **KASM Admin** > **Infrastructure** > **Pools**.
2. Click **Add**.
3. Configure:

   | Field | Value |
   |-------|-------|
   | Name | `harvester-agents` |
   | Type | Docker Agent |

4. **Save**.

### 7.2 Attach AutoScale Config

1. In the pool you just created, click **AutoScale** tab.
2. Click **Add AutoScale Config**.
3. Configure the **AutoScale Details** section:

   | Field | Value | Notes |
   |-------|-------|-------|
   | VM Provider | `harvester-docker-agents` | The provider from Step 6.1 |
   | Enabled | Checked | |
   | Aggressive Scaling | Unchecked | Check only if you want faster scale-up |
   | Standby Cores | `8` | Scale up when fewer than 8 idle cores |
   | Standby Memory (MB) | `8000` | Scale up when less than 8GB idle RAM |
   | Standby GPUs | `0` | Set if using GPU passthrough |
   | Downscale Backoff (seconds) | `900` | Wait 15 min before destroying idle VMs |
   | Agent Cores Override | *(leave blank)* | Uses VM Provider cores value |
   | Agent Memory Override | *(leave blank)* | Uses VM Provider memory value |
   | Register DNS | Unchecked | Only for environments with dynamic DNS |

4. Configure the **Scheduling** section (optional):

   - Leave defaults for always-on autoscaling.
   - Or set a schedule for business-hours-only scaling (e.g., Mon-Fri 07:00-19:00).

5. Click **Save**.

### 7.3 Verify Autoscaling

After saving the autoscale config, KASM should begin provisioning a VM
within a few minutes (since there are 0 standby cores, it will immediately
try to scale up to meet the standby threshold).

**Watch the provisioning**:

1. **KASM Admin** > **Infrastructure** > **Docker Agents**.
   - You should see a new agent appear with status **Provisioning**.
   - After ~5-10 minutes (cloud-init + Docker + KASM agent install), status
     changes to **Online**.

2. **Harvester UI** > **Virtual Machines** > namespace `kasm-autoscale`.
   - You should see a new VM spinning up.
   - Once the QEMU Guest Agent is running, the VM's IP will be visible.

3. If the agent never comes online, SSH into the VM and check cloud-init:

```bash
ssh -i ~/.ssh/kasm-agent-key kasm-admin@<VM_IP>
sudo cat /var/log/cloud-init-output.log
sudo journalctl -u kasm_agent
```

---

## 8. Register Workspace Images

Once at least one Docker Agent is **Online**, you can launch workspaces.

### 8.1 Add Workspace Registry (Recommended)

KASM maintains a public workspace registry with pre-built images:

1. **KASM Admin** > **Workspaces** > **Registry**.
2. If no registry is configured, click **Add Registry**:
   - URL: `https://registry.kasmweb.com/1.0/`
3. Browse available images and click **Install** on the ones you want.

### 8.2 Manual Image Registration

Alternatively, add images manually:

1. **KASM Admin** > **Workspaces** > **Workspaces** > **Add Workspace**.
2. For each image:

   | Friendly Name | Docker Image | Description |
   |--------------|-------------|-------------|
   | Chrome Browser | `kasmweb/chrome:1.18.0` | Isolated web browsing |
   | Firefox Browser | `kasmweb/firefox:1.18.0` | Alternative browser |
   | Ubuntu Desktop | `kasmweb/desktop:1.18.0` | Full Linux desktop |
   | VS Code | `kasmweb/vs-code:1.18.0` | Development IDE |
   | Terminal | `kasmweb/terminal:1.18.0` | CLI access |

3. For each workspace, configure:
   - **Cores**: `2`
   - **Memory (MB)**: `2768`
   - **Docker Registry**: leave blank (pulls from Docker Hub) or set to
     `harbor.<DOMAIN>/dockerhub` for Harbor proxy cache
   - **Persistent Profile Path**: `/home/kasm-user` (if persistent profiles
     are configured)
   - **Assign to groups**: select which KASM groups can access this workspace

### 8.3 Assign Workspaces to Groups

For each workspace image:

1. Click the workspace name > **Groups** tab.
2. **Add Group** > select the appropriate group(s).
3. The "All Users" group grants access to everyone. More restrictive access
   uses specific groups.

---

## 9. End-to-End Validation

### 9.1 Test as Admin (Local Login)

1. Login as `admin@kasm.local` at `https://kasm.<DOMAIN>`.
2. Click a workspace (e.g., Chrome).
3. A session should be provisioned on one of the Docker Agent VMs.
4. The desktop streams to your browser via WebSocket.
5. Verify: clipboard works, keyboard/mouse respond, session terminates cleanly.

### 9.2 Test as SSO User (Keycloak Login)

1. Open incognito browser > `https://kasm.<DOMAIN>`.
2. Click **Continue with Keycloak**.
3. Log in as a Keycloak user (e.g., one in `aegis-developers`).
4. You should see only the workspaces assigned to your group.
5. Launch a workspace and verify it streams correctly.

### 9.3 Test Autoscaling

1. Launch enough concurrent sessions to exhaust the standby capacity.
2. Watch **Infrastructure** > **Docker Agents** -- a new VM should begin
   provisioning.
3. After all sessions end, wait for the downscale backoff (15 min default).
4. The idle agent VM should be destroyed.

### 9.4 Test Logout

1. In the KASM session, click your username (top-right) > **Logout**.
2. You should be logged out of both KASM and Keycloak (backchannel logout).
3. Verify by navigating to `https://keycloak.<DOMAIN>` -- you should be on
   the Keycloak login page (not already authenticated).

---

## 10. Windows RDP Server Pool (Optional)

For Windows VDI desktops via RDP. This requires a pre-built Windows template
in Harvester.

### 10.1 Create Windows VM Template in Harvester

1. **Harvester UI** > **Images**: Upload Windows Server 2022 ISO and the
   [VirtIO drivers ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso).
2. **Virtual Machines** > **Create**:
   - Namespace: `kasm-autoscale`
   - Name: `win2022-template-builder`
   - CPU: 4, Memory: 8 GiB
   - Volumes:
     - Boot disk: 60 GiB, bus type VirtIO, provisioner Longhorn
     - CD-ROM 1: Windows Server 2022 ISO (bus type SATA)
     - CD-ROM 2: VirtIO drivers ISO (bus type SATA)
   - Network: vm-network (or pod)
3. Boot the VM and install Windows:
   - During disk selection, click **Load driver** > browse to VirtIO CD >
     `viostor\2k22\amd64` > install the VirtIO SCSI driver.
   - Complete Windows installation.
4. Post-install inside the Windows VM:
   - Install all VirtIO drivers (Device Manager > Update driver > VirtIO CD).
   - Install **QEMU Guest Agent**: `D:\guest-agent\qemu-ga-x86_64.msi`
     (from VirtIO CD).
   - Install **Cloudbase-Init**: download from
     [cloudbase.it](https://cloudbase.it/cloudbase-init/#download).
     During install: run as LocalSystem, do NOT sysprep, do NOT shutdown.
   - **Enable Remote Desktop**: Settings > System > Remote Desktop > On.
   - **Enable audio service**: `Set-Service Audiosrv -StartupType Automatic`
5. Shut down the VM.
6. Remove the two CD-ROM volumes from the VM config.
7. **Virtual Machines** > click the VM > **Generate Template** > check
   **With Data** > name: `win2022-kasm-rdp`.

### 10.2 Create KASM Server Pool VM Provider

1. **KASM Admin** > **Infrastructure** > **VM Provider Configs** > **Add Config**.
2. Select: **Harvester**.
3. Configure same as Step 6.1, but:

   | Field | Value |
   |-------|-------|
   | Name | `harvester-windows-rdp` |
   | Cores | `4` |
   | Memory (GiB) | `8` |
   | Disk Image | `win2022-kasm-rdp` *(template name)* |
   | Disk Size (GiB) | `60` |
   | Enable TPM | Optional |
   | Enable EFI Boot | Checked (for Windows 11 / Secure Boot) |

4. **Startup Script**: Use the PowerShell scripts from
   [kasmtech/workspaces-autoscale-startup-scripts/windows_vms](https://github.com/kasmtech/workspaces-autoscale-startup-scripts/tree/release/1.18.1/windows_vms).

   The entry point script (`Init-VM-Task.ps1`) and all supporting scripts
   must be bundled and referenced via Cloudbase-Init's userdata mechanism.
   See the repository README for details.

### 10.3 Create Server Pool

1. **Infrastructure** > **Pools** > **Add**.
2. Type: **Server**.
3. Connection Type: **RDP**.
4. Attach AutoScale config with the `harvester-windows-rdp` VM provider.
5. Set **Minimum Available Sessions**: `2` (always have 2 ready desktops).

---

## 11. Troubleshooting

### OIDC Login Fails ("Authentication Error")

**Symptom**: Clicking "Continue with Keycloak" redirects back to KASM with
an error.

**Checklist**:
1. Is the `groups` mapper configured in Keycloak? If KASM's Groups Attribute
   is set but the claim is missing from the token, auth fails entirely.
   - **Quick fix**: temporarily clear the Groups Attribute field in KASM
     OIDC config, test login, then fix the Keycloak mapper.
2. Check KASM API logs:
   ```bash
   kubectl -n kasm logs deployment/kasm-api --tail=200 | grep -i "oidc\|openid\|auth"
   ```
3. With Debug enabled, the full token is logged. Verify the `groups` claim
   is present and contains the expected group names.
4. Verify redirect URI matches exactly: `https://kasm.<DOMAIN>/api/oidc_callback`
5. Check TLS: if KASM can't verify Keycloak's TLS cert, auth fails silently.
   Enable Debug mode which also disables TLS verification for OIDC endpoints.

### Groups Not Mapping Correctly

**Symptom**: User logs in via Keycloak but only appears in "All Users", not
their expected group.

**Checklist**:
1. Check the Keycloak token claims (Debug mode logs them):
   - Is the `groups` claim present?
   - Does it contain the exact group name you put in the SSO mapping?
2. **Slash prefix**: If Keycloak mapper has Full group path = ON, groups
   appear as `/aegis-admins`. KASM mapping must match exactly.
3. The SSO provider name in the mapping must match the OpenID config name
   exactly: `OpenID - Continue with Keycloak`.

### Agent VM Never Comes Online

**Symptom**: VM provisions in Harvester but KASM shows it as "Provisioning"
indefinitely.

**Checklist**:
1. SSH into the VM: `ssh -i ~/.ssh/kasm-agent-key kasm-admin@<VM_IP>`
2. Check cloud-init: `sudo cat /var/log/cloud-init-output.log`
3. Common issues:
   - **QEMU Guest Agent not running**: Harvester can't detect the VM's IP.
     Check: `systemctl status qemu-guest-agent`
   - **Upstream Auth Address wrong**: The agent can't reach the KASM manager.
     Check: `curl -sk https://kasm.<DOMAIN>/api/__healthcheck`
   - **Manager token wrong/expired**: Check the install.sh output in
     cloud-init log.
   - **DNS resolution**: The VM must be able to resolve `kasm.<DOMAIN>`.
     Check: `nslookup kasm.<DOMAIN>`
   - **Download failure**: `kasm_release_1.18.1.tar.gz` download failed
     (check internet access from VM).

### Desktop Sessions Timeout After 10 Minutes

Traefik's default `readTimeout` was reduced in Traefik 3.x. Desktop WebSocket
streaming requires a long timeout.

**Fix**: Ensure the Traefik timeout HelmChartConfig is applied:

```bash
kubectl apply -f services/harbor/traefik-timeout-helmchartconfig.yaml
```

This sets `readTimeout: 1800s` and `respondingTimeouts.readTimeout: 1800s`.

### Accessing Local Admin After Auto-Login

If Auto Login is enabled and you need the local login page:

```
https://kasm.<DOMAIN>/#/staticlogin
```

---

## 12. References

### Official Documentation
- [KASM Keycloak OIDC Setup](https://www.kasmweb.com/docs/develop/guide/oidc/keycloak.html)
- [KASM OpenID Authentication](https://www.kasmweb.com/docs/latest/guide/oidc.html)
- [KASM Harvester AutoScale Provider](https://www.kasmweb.com/docs/develop/how_to/infrastructure_components/autoscale_providers/harvester.html)
- [KASM AutoScale Config (Docker Agent Pool)](https://kasmweb.com/docs/develop/how_to/infrastructure_components/autoscale_config_docker_agent.html)
- [KASM AutoScale Config (Server Pool)](https://kasm.com/docs/latest/how_to/infrastructure_components/autoscale_config_server.html)
- [KASM Groups and Permissions](https://www.kasmweb.com/docs/latest/guide/groups.html)
- [KASM Deployment Zones](https://www.kasmweb.com/docs/develop/guide/zones/deployment_zones.html)
- [KASM VM Provider Configs](https://www.kasmweb.com/docs/latest/guide/compute/vm_providers.html)
- [KASM Workspace Registry](https://www.kasmweb.com/docs/latest/guide/workspace_registry.html)
- [KASM Persistent Profiles](https://www.kasmweb.com/docs/latest/guide/persistent_data/persistent_profiles.html)
- [KASM Kubernetes Installation](https://www.kasmweb.com/docs/develop/install/kubernetes.html)

### GitHub
- [kasmtech/kasm-helm](https://github.com/kasmtech/kasm-helm) -- Helm chart
- [kasmtech/workspaces-autoscale-startup-scripts](https://github.com/kasmtech/workspaces-autoscale-startup-scripts) -- Startup scripts for Docker Agents, Linux VMs, Windows VMs
- [kasmtech/workspaces-issues](https://github.com/kasmtech/workspaces-issues) -- Issue tracker (see #834 for TLS issues)

### Architecture / Blog
- [VDI on Kubernetes: Rancher + Harvester + KASM](https://medium.kasm.com/vdi-on-kubernetes-for-enterprises-rancher-harvester-kasm-92652d46d8ca)
- [Installing KASM on Rancher Using Official Helm Chart](https://medium.kasm.com/installing-kasm-workspaces-on-rancher-using-the-official-helm-chart-a4c4ef918e35)
- [Rancher GA Announcement of KASM Helm Chart (Dec 2025)](https://www.einpresswire.com/article/876608994/rancher-announces-general-availability-of-kasm-kubernetes-helm-partner-chart)
