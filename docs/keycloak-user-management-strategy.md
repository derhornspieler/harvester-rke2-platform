# Keycloak User Management Strategy

## Decision: Active Directory Federation vs Standalone Keycloak

> **Implementation Note (Feb 2026)**: The current cluster implements **Option B** (Keycloak as
> sole identity provider with CNPG PostgreSQL 16.6). Option C (FreeIPA integration) remains the
> target architecture for infrastructure device authentication. See
> [security-architecture.md](engineering/security-architecture.md) for current implementation.

This document compares approaches to identity management for a platform that
spans both Kubernetes-native applications (Rancher, ArgoCD, GitLab, Harbor,
Grafana, Mattermost) AND traditional infrastructure (network switches,
firewalls, OOB management, SSH access to servers).

| Approach | User Store | Auth Protocols | Operational Owner |
|----------|-----------|----------------|-------------------|
| **Option A** | Active Directory / LDAP | OIDC + RADIUS + TACACS+ + Kerberos | AD team or Help Desk |
| **Option B** | Keycloak internal DB | OIDC only | DevOps or Help Desk via Keycloak UI/API |
| **Option C** | FreeIPA + Keycloak | OIDC + RADIUS + LDAP + Kerberos | DevOps or Help Desk via FreeIPA/Keycloak |

---

## Option A: Active Directory / LDAP Federation

### How it works

Keycloak connects to AD/LDAP as a User Federation provider. Users and groups
are synced (or queried on-demand) from AD into Keycloak. Keycloak adds the
OIDC/SAML layer that downstream apps consume.

```
User ──► Keycloak (OIDC) ──► Rancher / ArgoCD / GitLab / etc.
              │
              ▼
     Active Directory (LDAP)
     (source of truth for users)
```

### Strengths

- **Familiar tooling for Help Desk / NOC**: AD Users and Computers (ADUC) is
  the standard tool every Windows Help Desk knows. Creating a user, resetting
  a password, disabling an account — these are day-one skills for any NOC
  technician.
- **Single source of truth across the org**: If AD already exists for email,
  VPN, file shares, and workstation login, adding Keycloak as a federation
  layer avoids a second user directory.
- **Password policy enforcement**: AD handles password complexity, expiration,
  lockout, and history natively. These policies are mature and well-understood
  by security auditors.
- **Kerberos / POSIX support**: If any systems need Kerberos tickets (SSH,
  NFS, CIFS, sudo) or POSIX attributes (UID/GID), AD provides these natively.
  Keycloak alone cannot.
- **Compliance**: Many compliance frameworks (SOC 2, HIPAA, FedRAMP) expect a
  centralized directory service. AD satisfies this requirement cleanly.

### Weaknesses

- **Infrastructure overhead**: AD requires at minimum 2 domain controllers
  (Windows Server VMs), DNS integration, and ongoing patching. If no AD exists
  today, standing one up adds significant infrastructure and licensing cost.
- **Sync lag and caching**: Federation can be configured as sync (periodic
  import) or on-demand (LDAP query per login). Sync mode introduces delay
  between AD changes and Keycloak visibility. On-demand mode adds latency per
  login.
- **Group mapping complexity**: AD groups must be mapped to Keycloak roles or
  groups, then those must be mapped to claims in OIDC tokens, then each app
  must map those claims to its own RBAC. This creates a 4-layer mapping chain:
  `AD Group → Keycloak Group → OIDC Claim → App Role`.
- **Split administration**: User lifecycle is in AD, but OIDC client
  configuration, role mappings, and protocol settings live in Keycloak. Two
  systems to maintain, two teams to coordinate.
- **Not cloud-native**: AD is a stateful Windows service that does not fit
  naturally into a Kubernetes-native workflow. It resists GitOps, IaC, and
  container-based deployment patterns.

### When to choose Option A

- AD already exists and is actively managed
- The org has a Help Desk / NOC team trained on AD tooling
- Non-web systems (SSH, NFS, Windows file shares) need the same identities
- Compliance requires a centralized directory service
- The platform team does not want to own user lifecycle

---

## Option B: Keycloak as Sole Identity Provider

### How it works

Keycloak's internal database stores all users, groups, and roles. There is no
external directory. Keycloak is both the IdP and the user store.

```
User ──► Keycloak (OIDC) ──► Rancher / ArgoCD / GitLab / etc.
              │
              ▼
     Keycloak Internal DB
     (PostgreSQL)
     (source of truth for users)
```

### Strengths

- **Zero external dependencies**: No AD, no LDAP, no FreeIPA. One fewer system
  to deploy, patch, monitor, and back up.
- **Full RBAC built in**: Keycloak natively supports:
  - Realm roles (global)
  - Client roles (per-application)
  - Groups (hierarchical, with role inheritance)
  - Composite roles (role-of-roles)
  - Fine-grained authorization (resources, scopes, policies)
- **Built-in Admin Console**: Keycloak ships with a full admin UI for user
  management — create, disable, delete, reset password, assign groups/roles,
  view sessions, impersonate. No custom frontend required for basic operations.
- **Admin REST API**: Every operation in the UI is available via REST API,
  enabling automation, Terraform (`mrparkers/keycloak` provider), and CI/CD
  pipelines.
- **Cloud-native**: Runs as a container, backs onto PostgreSQL, fits naturally
  into Kubernetes, supports GitOps for realm/client configuration via
  `keycloak-config-cli` or Terraform.
- **Self-service flows**: Built-in registration, email verification, password
  reset, OTP enrollment, and account management — all configurable without
  custom code.

### Weaknesses

- **No Kerberos / POSIX**: If any systems need Kerberos tickets or POSIX
  attributes (UID/GID for NFS), Keycloak cannot provide them. This is the
  single biggest functional gap.
- **Help Desk familiarity**: NOC technicians are unlikely to know the Keycloak
  Admin Console. Training is required. The UI is powerful but has a learning
  curve compared to ADUC.
- **No native desktop/OS integration**: Keycloak cannot handle Windows domain
  join, macOS directory binding, or Linux PAM/SSSD authentication (without
  adding an LDAP backend, which circles back to Option A).
- **Backup criticality**: Keycloak's database becomes the single source of
  truth for all identities. Database corruption or loss without backup means
  all users are gone. (This is equally true of AD, but AD admins are more
  accustomed to treating it as critical infrastructure.)

### When to choose Option B

- No AD exists today and standing one up adds unjustified complexity
- All applications are web-based and support OIDC or SAML
- No need for Kerberos, POSIX, or OS-level directory integration
- The team prefers Kubernetes-native, GitOps-friendly tooling
- User count is small-to-medium (< 1000) and doesn't justify AD licensing

---

## Operational Comparison: Help Desk / NOC vs DevOps

This is the core tension. Who creates and manages user accounts day-to-day?

### Scenario: NOC / Help Desk manages accounts

| Task | Option A (AD) | Option B (Keycloak only) |
|------|--------------|-------------------------|
| Create user | ADUC → New User (familiar) | Keycloak Admin Console → Add User (training needed) |
| Reset password | ADUC → Reset Password | Keycloak → Credentials → Set Password |
| Disable account | ADUC → Disable Account | Keycloak → User → toggle Enabled off |
| Add to group | ADUC → Member Of → Add | Keycloak → Users → Groups → Join |
| Bulk operations | PowerShell scripts | Admin REST API or `kcadm.sh` CLI |
| Audit trail | AD event logs (Event Viewer) | Keycloak Admin Events (built-in) |
| Training required | Low (standard IT skill) | Medium (new UI, new concepts like realms/clients) |

**Key insight:** The Keycloak Admin Console is a fully functional user
management UI. A Help Desk technician can perform all standard account
operations through it without any custom development. The gap is training, not
tooling.

### Scenario: DevOps manages accounts as code

| Task | Option A (AD) | Option B (Keycloak only) |
|------|--------------|-------------------------|
| Create user | Terraform AD provider or PowerShell in CI | Terraform Keycloak provider |
| Manage groups/roles | Terraform AD + Terraform Keycloak (two providers) | Terraform Keycloak (one provider) |
| Bootstrap realm config | Keycloak realm export/import | Same |
| GitOps workflow | Partial (AD resists IaC) | Full (everything is API-driven) |
| Drift detection | Difficult (AD has side-channel changes) | Terraform state tracks everything |

**Key insight:** Option B is strictly simpler for DevOps-as-code workflows
because there is one system to manage instead of two.

---

## Does Keycloak Need a Custom Frontend?

### Short answer: No, for most use cases.

Keycloak ships with three built-in UIs:

| UI | Purpose | Audience |
|----|---------|----------|
| **Admin Console** (`/admin`) | Full user/group/role/client management | Admins, Help Desk |
| **Account Console** (`/realms/{realm}/account`) | Self-service profile, password, OTP, sessions | End users |
| **Login Theme** (`/realms/{realm}/protocol/openid-connect/auth`) | Login, registration, password reset | End users |

All three are themeable (CSS, Freemarker templates in Keycloak < 24, or React
SPA in Keycloak 24+) without writing a separate application.

### When a custom frontend IS justified

| Scenario | Why Keycloak UI falls short | Complexity |
|----------|---------------------------|------------|
| **Delegated admin per tenant** | Keycloak's admin permissions are realm-wide. If you need "Team Lead can manage only their team's users," the built-in admin roles are too coarse. | Medium — use Admin REST API with a thin wrapper that enforces scope. |
| **Approval workflows** | "User requests access to Project X, manager approves" is not built in. Keycloak has Required Actions but not multi-step approval chains. | Medium-High — need a workflow engine or custom app calling the Admin API. |
| **Branded self-service portal** | The Account Console is functional but generic. If the org wants a polished, branded portal with custom fields, dashboards, or integrated help, a custom SPA is needed. | Medium — React/Vue app calling Account and Admin REST APIs. |
| **Non-technical Help Desk** | If the Help Desk finds the Admin Console too complex, a simplified "create user / reset password / disable" UI with guardrails can reduce errors. | Low-Medium — thin wrapper around 4-5 Admin API endpoints. |
| **Audit / reporting dashboard** | Keycloak stores admin events and login events but the built-in UI for browsing them is basic. Custom reporting often needs direct DB queries or event export. | Medium — export events to Elasticsearch/Loki and build Grafana dashboards. |

### Complexity of building a custom frontend

If a custom frontend is needed, the typical approach is:

```
Custom SPA (React/Vue)
    │
    ▼
Keycloak Admin REST API (/admin/realms/{realm}/users, /groups, /roles)
    │
    ▼
Keycloak (validates admin token, performs operation)
```

**Estimated effort:**
- Simple CRUD portal (create/disable/reset/group assign): 2-4 weeks
- Approval workflow integration: 4-8 weeks
- Full branded portal with reporting: 8-16 weeks

**Ongoing maintenance:**
- Keycloak major version upgrades can change Admin API behavior
- The custom app becomes another service to deploy, monitor, and patch
- Every new Keycloak feature (passkeys, social login, etc.) must be manually
  wired into the custom UI

**Recommendation:** Start with the built-in Admin Console. Train the Help Desk
on it. Only build a custom frontend if a specific gap is identified after
real-world use. Premature custom UI development is a common source of tech
debt in Keycloak deployments.

---

## Infrastructure and Network Device Authentication

This section addresses authentication for systems that do NOT speak OIDC:
network switches, firewalls, OOB management (iDRAC/iLO/IPMI), VPN
concentrators, and SSH access to servers.

### Protocol Requirements by Device Type

| Device / System | Auth Protocol | What It Needs | Keycloak Alone? |
|----------------|--------------|---------------|-----------------|
| Cisco IOS/NX-OS switches | TACACS+ or RADIUS | Centralized login, command authorization, accounting | No |
| Cisco ISE | RADIUS + LDAP backend | User store for 802.1X, device profiling, posture | No |
| Palo Alto firewalls | RADIUS or LDAP | Admin auth, GlobalProtect VPN, User-ID | No |
| pfSense / OPNsense | RADIUS or LDAP | Admin auth, OpenVPN, captive portal | No |
| Aruba / HP switches | RADIUS or TACACS+ | 802.1X port auth, admin login | No |
| iDRAC / iLO / IPMI | LDAP or RADIUS | OOB server management console login | No |
| SSH to Linux servers | PAM + SSSD (Kerberos/LDAP) | Centralized user login, sudo authorization | No |
| SSH with short-lived keys | SSH CA signing | Temporary access without persistent keys | Partial (via Vault SSH CA) |
| VPN concentrators | RADIUS + MFA | User auth with second factor | No |
| Wi-Fi (WPA-Enterprise) | RADIUS (802.1X) | Certificate or credential-based wireless auth | No |

**Key takeaway:** Keycloak speaks OIDC and SAML. Infrastructure devices speak
RADIUS, TACACS+, LDAP, and Kerberos. These are fundamentally different
protocol families. Keycloak alone cannot authenticate network infrastructure.

### What Each Protocol Does

**RADIUS** (Remote Authentication Dial-In User Service)
- The universal protocol for network device authentication
- Every enterprise switch, firewall, wireless controller, and VPN supports it
- Provides Authentication, Authorization, and Accounting (AAA)
- Cisco ISE, FreeRADIUS, and Microsoft NPS are common RADIUS servers
- Typically backed by LDAP/AD for the user store

**TACACS+** (Terminal Access Controller Access-Control System Plus)
- Cisco-proprietary (but widely supported) protocol for device administration
- Separates authentication, authorization, and accounting (unlike RADIUS which
  bundles auth+authz)
- Enables per-command authorization ("user X can run `show` but not `config`")
- Critical for NOC environments where different tiers have different access
- Backed by LDAP/AD or local user database

**LDAP** (Lightweight Directory Access Protocol)
- The query protocol for directory services (AD, FreeIPA, OpenLDAP)
- Used by ISE, firewalls, and OOB devices to look up users and group
  memberships directly
- Many devices that "support LDAP" use it for authentication (LDAP bind) even
  though LDAP is technically a directory protocol, not an auth protocol

**Kerberos**
- Ticket-based SSO protocol for host-level authentication
- Required for SSH with centralized credentials via SSSD/PAM
- Provided by AD or FreeIPA (not Keycloak)

### Architecture: How It All Fits Together

```
                    ┌──────────────────────────────────────────────┐
                    │          Web Applications (OIDC)             │
                    │  Rancher, ArgoCD, GitLab, Harbor, Grafana    │
                    └──────────────────┬───────────────────────────┘
                                       │ OIDC
                                       ▼
                               ┌───────────────┐
                               │   Keycloak     │
                               │   (OIDC IdP)   │
                               └───────┬───────┘
                                       │ LDAP Federation
                                       ▼
┌──────────────────────────────────────────────────────────────────┐
│                    Directory Service                             │
│              (AD  /  FreeIPA  /  OpenLDAP)                       │
│         Source of truth: users, groups, passwords                │
└────────┬─────────────────┬──────────────────┬────────────────────┘
         │ RADIUS           │ TACACS+           │ Kerberos + LDAP
         ▼                  ▼                   ▼
┌─────────────────┐ ┌───────────────┐ ┌─────────────────────────┐
│ RADIUS Server   │ │ TACACS+ Server│ │ Linux Servers (SSH)     │
│ (FreeRADIUS /   │ │ (tac_plus /   │ │ via SSSD + PAM          │
│  ISE / NPS)     │ │  Cisco ISE)   │ │                         │
└────────┬────────┘ └──────┬────────┘ └─────────────────────────┘
         │                  │
         ▼                  ▼
┌──────────────────────────────────────────────────────────────────┐
│              Network Infrastructure                              │
│  Switches, Firewalls, Wireless, VPN, OOB (iDRAC/iLO)           │
│  Cisco, Palo Alto, pfSense, Aruba, Dell, HPE                   │
└──────────────────────────────────────────────────────────────────┘
```

The directory service (AD or FreeIPA) is the hub. Keycloak federates it for
web apps. RADIUS/TACACS+ servers query it for network devices. SSSD queries it
for Linux host auth.

### Option C: FreeIPA + Keycloak (Linux-Native Alternative to AD)

Since the environment is Linux/Kubernetes-native with no existing AD, FreeIPA
is the open-source alternative that provides the directory service hub.

**FreeIPA provides:**
- LDAP directory (389 Directory Server) — user store for everything
- Kerberos KDC — SSH, NFS, host-level SSO
- SSSD integration — Linux PAM/NSS for SSH and sudo
- HBAC (Host-Based Access Control) — which users can SSH to which hosts
- Sudo rules — centralized sudo policy per user/group/host
- DNS — integrated DNS (optional, can be disabled if using external DNS)
- Certificate Authority (Dogtag) — host certificates, user certificates

**FreeIPA does NOT provide:**
- RADIUS — need FreeRADIUS alongside, backed by FreeIPA's LDAP
- TACACS+ — need tac_plus or Cisco ISE alongside, backed by FreeIPA's LDAP
- OIDC/SAML — Keycloak fills this gap

**Combined FreeIPA + Keycloak architecture:**

| Component | Role | Backed by |
|-----------|------|-----------|
| FreeIPA | User directory, Kerberos, SSH/sudo | 389 DS (LDAP) |
| Keycloak | OIDC IdP for web apps | Federates FreeIPA via LDAP |
| FreeRADIUS | RADIUS for network devices | Queries FreeIPA LDAP |
| tac_plus (or ISE) | TACACS+ for Cisco device admin | Queries FreeIPA LDAP |
| SSSD | Linux host auth | Joins FreeIPA domain |
| Vault SSH CA | Short-lived SSH certificates | Optional, complements FreeIPA |

### SSH Key Management: Temporary Keys and Certificates

Three approaches for SSH access control:

**1. FreeIPA + SSSD (traditional)**
- Users SSH with their FreeIPA password or Kerberos ticket
- SSSD on each host resolves users, enforces HBAC and sudo rules
- Keys stored in LDAP (`sshPublicKey` attribute), distributed via SSSD
- Revocation: disable user in FreeIPA, access revoked immediately
- Complexity: Low — standard Linux tooling, well-documented

**2. Vault SSH CA (short-lived certificates) -- Implemented via Identity Portal**
- Vault acts as an SSH Certificate Authority (`ssh-client-signer/` secrets engine)
- User authenticates to Identity Portal (via OIDC → Keycloak), then requests an SSH certificate
- Vault signs a temporary SSH certificate (TTL: 2--12 hours depending on role)
- Server trusts the Vault CA public key, no per-user key distribution
- Revocation: certificates expire automatically, no CRL needed
- Complexity: Medium — requires Vault SSH secret engine, client tooling
- **Status**: Implemented via the [Identity Portal](identity-portal.md). See [SSH Certificate Authentication](ssh-certificate-auth.md) for full details.

```
User ──► Identity Portal (authenticate via Keycloak OIDC)
              │ paste SSH public key
              ▼
         Identity Portal ──► Vault (sign with SSH CA)
              │
              ▼
         Temporary SSH Certificate (e.g. 4-hour TTL)
              │
              ▼
         SSH to server (server trusts Vault CA)
```

**3. Teleport / Boundary (dedicated access proxy)**
- HashiCorp Boundary or Gravitational Teleport as SSH access gateway
- Centralizes SSH access with session recording, RBAC, and audit
- Integrates with OIDC (Keycloak) for authentication
- Eliminates direct SSH key management entirely
- Complexity: High — another service to deploy and manage

**Recommendation for SSH:** Start with FreeIPA + SSSD for standard SSH access.
Add Vault SSH CA for privileged/temporary access patterns. Defer Teleport/
Boundary unless session recording or compliance requires it.

### Network Device Auth: RADIUS and TACACS+

**FreeRADIUS + FreeIPA for network device authentication:**

FreeRADIUS queries FreeIPA's LDAP backend for user credentials and group
memberships. RADIUS group mappings control what level of access each user gets
on the network device.

```
Switch login ──► RADIUS ──► FreeRADIUS ──► FreeIPA LDAP
                                                │
                                    ┌───────────┴───────────┐
                                    │ Group: network-admins  │ → Privilege 15
                                    │ Group: network-readonly│ → Privilege 1
                                    │ Group: noc-tier1       │ → Custom shell
                                    └────────────────────────┘
```

**TACACS+ for Cisco command authorization:**

If per-command authorization is needed (e.g., "NOC Tier 1 can `show` but
cannot `configure`"), TACACS+ with tac_plus is the answer.

```
Cisco switch ──► TACACS+ ──► tac_plus ──► FreeIPA LDAP
                                               │
                                  ┌────────────┴────────────┐
                                  │ network-admins: all cmds │
                                  │ noc-tier1: show only     │
                                  │ noc-tier2: show + config │
                                  └─────────────────────────┘
```

**Cisco ISE integration:**

If Cisco ISE is in the environment, it serves as both RADIUS and TACACS+
server and can query FreeIPA's LDAP directly for user/group lookups. ISE also
handles:
- 802.1X port authentication (wired/wireless)
- Device profiling and posture assessment
- Guest access portals
- BYOD onboarding

ISE uses LDAP or AD as its identity source. FreeIPA's 389 DS works as the
LDAP backend for ISE.

### Palo Alto / pfSense / OPNsense Integration

**Palo Alto firewalls:**
- Admin authentication: RADIUS or LDAP → FreeIPA
- GlobalProtect VPN: RADIUS → FreeRADIUS → FreeIPA (with MFA via TOTP)
- User-ID for policy: LDAP query or syslog from FreeIPA/RADIUS
- Admin role mapping: RADIUS VSAs (Vendor-Specific Attributes) or LDAP group
  membership → Palo Alto admin roles

**pfSense / OPNsense:**
- Admin authentication: RADIUS or LDAP → FreeIPA
- OpenVPN: RADIUS → FreeRADIUS → FreeIPA
- Captive portal: RADIUS → FreeRADIUS → FreeIPA
- Group-based firewall rules: LDAP group query

### OOB Management (iDRAC, iLO, IPMI)

- Dell iDRAC: Supports LDAP and RADIUS — point at FreeIPA's LDAP or
  FreeRADIUS. Map LDAP groups to iDRAC privilege levels (Administrator,
  Operator, Read Only).
- HPE iLO: Same — LDAP or RADIUS backed by FreeIPA. LDAP groups map to iLO
  directory roles.
- Supermicro IPMI: RADIUS or LDAP (limited). Older BMCs may only support
  RADIUS.

For all OOB devices, the pattern is the same: LDAP bind or RADIUS auth against
FreeIPA, with group-to-role mapping configured on each device.

---

## Tech Debt Comparison

| Debt Category | Option A (AD + Keycloak) | Option B (Keycloak only) | Option C (FreeIPA + Keycloak) |
|--------------|-------------------------|-------------------------|-------------------------------|
| Infrastructure | 2 DC VMs + Keycloak | Keycloak + PostgreSQL | 2 FreeIPA VMs + Keycloak + FreeRADIUS |
| Patching | Windows Server + Keycloak | Keycloak only | RHEL/Rocky + FreeIPA + Keycloak |
| Backup | AD system state + KC DB | Keycloak DB only | FreeIPA + Keycloak DB |
| Config drift | High (ADUC side-channel) | Low (API-driven) | Medium (FreeIPA CLI changes) |
| Mapping layers | AD→KC→OIDC→App (4) | KC→OIDC→App (3) | IPA→KC→OIDC→App (4, but IPA→RADIUS is direct) |
| Knowledge silos | AD + Keycloak + RADIUS | Keycloak only | FreeIPA + Keycloak + FreeRADIUS |
| Network device auth | Yes (via NPS/RADIUS) | **No** | Yes (via FreeRADIUS) |
| SSH centralized auth | Yes (Kerberos/SSSD) | **No** | Yes (Kerberos/SSSD) |
| OOB management auth | Yes (LDAP/RADIUS) | **No** | Yes (LDAP/RADIUS) |
| Licensing cost | Windows Server CALs | Free | Free |
| OS alignment | Windows-centric | N/A | Linux-native |
| Disaster recovery | AD replication + KC DB | KC DB restore | FreeIPA replication + KC DB |

---

## Recommendation

Given the requirement for both web application auth (OIDC) AND infrastructure
auth (RADIUS, TACACS+, SSH, OOB), Keycloak alone is insufficient. A directory
service backend is required.

> **Note**: The [Identity Portal](identity-portal.md) now provides admin and
> self-service user management, SSH certificate issuance via Vault, and
> kubeconfig generation -- covering the most common identity tasks through a web
> UI without requiring direct Keycloak or Vault CLI access.

> **Use FreeIPA + Keycloak + FreeRADIUS (Option C).**

This provides a fully open-source, Linux-native identity stack that covers
every authentication protocol needed: OIDC for web apps, RADIUS/TACACS+ for
network devices, Kerberos/SSSD for SSH, and LDAP for OOB management.

### Why Option C over Option A (AD)?

- No Windows Server licensing or infrastructure
- Linux-native, aligns with the existing RHEL/Rocky + Kubernetes stack
- FreeIPA's HBAC and sudo rules are more granular than AD's GPO for Linux
- FreeIPA replication is simpler than AD multi-site replication
- The team already manages Linux — no Windows admin skills required

### Why not Option B (Keycloak only)?

Option B cannot authenticate network switches, firewalls, OOB management, or
SSH. Once infrastructure devices are in scope, a directory service is not
optional — it is the backbone.

### FreeIPA considerations

FreeIPA adds real complexity. Be aware of these trade-offs:

- **DNS conflict**: FreeIPA wants to own DNS. If external DNS is already
  managed (e.g., by the network team or a cloud provider), configure FreeIPA
  as a DNS forwarder or disable its DNS entirely and manage records externally.
- **CA conflict**: FreeIPA includes Dogtag CA. Since Vault already handles PKI,
  use FreeIPA's CA only for internal host certificates and Kerberos. Do not use
  it for TLS certificates that Vault already manages.
- **Not Kubernetes-native**: FreeIPA runs on dedicated VMs (2 minimum for HA).
  It is a stateful service that resists containerization. Plan for VM-based
  deployment on Harvester.
- **Replication**: FreeIPA uses multi-master replication. Two replicas are
  sufficient. Add a third only if geographic redundancy is needed.

### Phased approach

1. **Phase 1 — FreeIPA Foundation (Week 1-2)**
   - Deploy 2 FreeIPA replicas on Harvester VMs (Rocky 9)
   - Create user groups: `platform-admins`, `network-admins`, `noc-tier1`,
     `noc-tier2`, `developers`, `read-only`
   - Disable FreeIPA DNS if using external DNS (or configure as forwarder)
   - Configure Vault as external CA for TLS; keep FreeIPA CA for host/Kerberos
   - Enroll initial users

2. **Phase 2 — Keycloak OIDC Layer (Week 2-3)**
   - Configure Keycloak LDAP federation against FreeIPA
   - Create OIDC clients for Rancher, ArgoCD, GitLab, Harbor, Grafana,
     Mattermost
   - Map FreeIPA groups to Keycloak roles and OIDC claims
   - Test SSO across all web applications

3. **Phase 3 — Network Device Auth (Week 3-4)**
   - Deploy FreeRADIUS, backed by FreeIPA LDAP
   - Configure RADIUS on switches, firewalls, wireless controllers
   - Configure RADIUS VSAs for per-group privilege levels
   - If TACACS+ needed: deploy tac_plus backed by FreeIPA LDAP
   - Configure Palo Alto / pfSense admin auth via RADIUS or LDAP
   - Configure iDRAC / iLO / IPMI via LDAP or RADIUS

4. **Phase 4 — SSH and Host Auth (Week 4-5)**
   - Enroll Linux servers into FreeIPA domain (ipa-client-install)
   - Configure SSSD for SSH authentication via Kerberos
   - Define HBAC rules (which users can access which hosts)
   - Define sudo rules in FreeIPA (centralized sudo policy)
   - Optional: configure Vault SSH CA for short-lived privileged access

5. **Phase 5 — Self-Service and Automation (Week 5-6)**
   - Enable Keycloak self-registration with email verification
   - Configure MFA (TOTP) in Keycloak, flows through to all OIDC apps
   - FreeRADIUS MFA for VPN (TOTP via FreeIPA or Keycloak adapter)
   - Terraform providers for both FreeIPA and Keycloak configuration
   - Admin event export to monitoring stack (Grafana/Loki)

6. **Phase 6 — NOC/Help Desk Handoff (Week 6-8)**
   - Train Help Desk on FreeIPA Web UI for user CRUD and password resets
   - Train Help Desk on Keycloak Admin Console for session management
   - Document runbooks for common tasks (new hire, termination, role change)
   - If FreeIPA Web UI is insufficient → evaluate custom frontend
   - Establish break-glass procedures (local admin accounts on critical devices)

### Help Desk user management: FreeIPA vs AD

For a NOC / Help Desk team, FreeIPA provides a Web UI at
`https://ipa.example.com/ipa/ui/` that handles:
- Create / disable / delete users
- Reset passwords
- Manage group memberships
- View HBAC and sudo rules
- Manage SSH public keys per user

This is less polished than ADUC but fully functional. The learning curve for
a Help Desk tech is comparable to Keycloak Admin Console — unfamiliar UI, but
all standard operations are point-and-click.

| Task | AD (ADUC) | FreeIPA Web UI | Difficulty Delta |
|------|----------|----------------|-----------------|
| Create user | Easy | Easy | Comparable |
| Reset password | Easy | Easy | Comparable |
| Disable account | Easy | Easy (stage: disabled) | Comparable |
| Add to group | Easy | Easy | Comparable |
| Set SSH keys | N/A (not native) | Easy (user tab) | FreeIPA wins |
| Manage sudo rules | GPO (complex) | Built-in sudo rules | FreeIPA wins |
| Bulk operations | PowerShell | `ipa` CLI or API | Comparable |

---

## Summary

| Question | Answer |
|----------|--------|
| Can Keycloak replace LDAP for web apps? | Yes, fully. |
| Can Keycloak handle roles, RBAC, groups? | Yes, natively. |
| Can Keycloak auth network switches/firewalls? | **No.** Need RADIUS/TACACS+ backed by LDAP. |
| Can Keycloak handle SSH auth? | **No.** Need Kerberos/SSSD (FreeIPA or AD). |
| Can Keycloak auth OOB devices (iDRAC/iLO)? | **No.** Need LDAP or RADIUS. |
| Does Help Desk need a custom UI? | Start with FreeIPA Web UI + Keycloak Admin Console. Evaluate after use. |
| When is a custom frontend justified? | Delegated admin, approval workflows, or simplified UX after real-world use. |
| Why FreeIPA over AD? | No Windows licensing, Linux-native, better SSH/sudo integration, aligns with existing stack. |
| Why not Keycloak alone? | Infrastructure devices don't speak OIDC. Once network/SSH auth is in scope, a directory backend is required. |
| What does FreeIPA add? | LDAP directory + Kerberos KDC + SSSD + HBAC + sudo rules + SSH key management. |
| What does FreeRADIUS add? | RADIUS protocol for switches, firewalls, wireless, VPN, OOB — backed by FreeIPA's LDAP. |
| Recommended architecture? | **FreeIPA** (directory) + **Keycloak** (OIDC) + **FreeRADIUS** (network) + **Vault SSH CA** (privileged access). |
