# Golden Image Plan: Pre-Baked Rocky 9 for Faster Node Provisioning

> **Historical Document**: This planning document describes the original design for the golden
> image build system. The actual implementation diverged significantly (using Terraform +
> virt-customize instead of Packer) and is documented in the authoritative engineering reference:
> **[Golden Image & CI/CD Engineering Guide](engineering/golden-image-cicd.md)**.
>
> The implementation is in the `golden-image/` directory (not `packer/` as originally planned).

**Status**: Implemented
**Created**: 2026-02-11
**Goal**: Reduce node boot-to-ready time by ~100s by pre-baking all static configuration into a reusable qcow2 image, leaving only per-node/per-cluster config for runtime cloud-init.

---

## Problem Statement

Every node provisioned today boots from a vanilla Rocky 9 GenericCloud image and runs the full cloud-init pipeline:

1. `dnf update && dnf upgrade` (~30-90s)
2. Install 6 packages (~15-30s)
3. Write config files (<1s)
4. `dnf install rke2-selinux` (~10-20s)
5. Configure services (<2s)
6. Rancher system-agent bootstrap + RKE2 download + join (~60-120s)

Steps 1-5 are **identical for every node, every time**. They account for ~55-140s of wasted time per node, repeated across all 8+ nodes and every autoscaler scale-up event.

The compute pool (scale-from-zero) is hit hardest — cold starts pay the full penalty.

---

## Solution: Single Golden Image

Bake one universal image that includes everything common to both CP and worker nodes. Worker-specific config (ARP hardening, NM dispatcher) is harmless on single-NIC CP nodes, so one image covers all pools.

### What Gets Baked (static, package-related, or generic config)

| Item | Source (current) | Notes |
|------|-----------------|-------|
| `dnf update && upgrade` | `package_update/upgrade: true` | Packages pre-patched at bake time |
| 6 packages (qemu-guest-agent, iptables, iptables-services, container-selinux, policycoreutils-python-utils, audit) | `packages:` block | Pre-installed |
| rancher-rke2-common.repo | `write_files` | Repo added, rke2-selinux installed from it |
| rke2-selinux | `runcmd: dnf install` | Pre-installed via the baked repo |
| /etc/sysconfig/iptables | `write_files` | Static firewall rules, identical all nodes |
| /etc/sysctl.d/90-arp.conf | `write_files` (worker only) | ARP hardening; no-op on single-NIC CP |
| /etc/NetworkManager/dispatcher.d/10-ingress-routing | `write_files` (worker only) | eth1 policy routing; never fires on CP (no eth1) |
| /var/lib/rancher/rke2/server/manifests/ | `runcmd: mkdir` | Directory pre-created |
| qemu-guest-agent enabled | `runcmd: systemctl enable` | Service enabled at bake time |
| firewalld disabled | `runcmd: systemctl disable` | Disabled at bake time |
| iptables enabled | `runcmd: systemctl enable` | Enabled at bake time |
| sysctl --system applied | `runcmd` (worker only) | ARP settings loaded |
| SELinux contexts restored | `runcmd: restorecon` | Dispatcher script labeled |

### What Stays in Runtime Cloud-Init

**CP nodes** (write Cilium manifests + SSH keys):

```yaml
#cloud-config
ssh_authorized_keys:
  - <dynamic from var.ssh_authorized_keys>

write_files:
- path: /var/lib/rancher/rke2/server/manifests/cilium-lb-ippool.yaml
  permissions: '0644'
  content: |
    <CiliumLoadBalancerIPPool with cluster-specific IP range>

- path: /var/lib/rancher/rke2/server/manifests/cilium-l2-policy.yaml
  permissions: '0644'
  content: |
    <CiliumL2AnnouncementPolicy>
```

**Worker nodes** (SSH keys only):

```yaml
#cloud-config
ssh_authorized_keys:
  - <dynamic from var.ssh_authorized_keys>
```

### Runtime Cloud-Init Rationale

| Item | Why runtime? |
|------|-------------|
| `ssh_authorized_keys` | May change per deployment or when keys rotate |
| Cilium L2 IP pool manifest | Contains cluster-specific IP range (`203.0.113.202-220`) |
| Cilium L2 announcement policy | Tied to cluster topology; could be baked if never changes, but safer as runtime |

---

## Image Build Process

### Option A: Manual Bake via Harvester (simplest, good for v1)

1. Create a VM in Harvester from current Rocky 9 GenericCloud image
2. SSH in, run the bake provisioner script (see below)
3. Shut down the VM
4. In Harvester UI: export the VM disk as a new image (`rke2-rocky9-golden-v1`)
5. Update `image.tf` to reference the new image (by URL or pre-existing image name)

### Option B: Packer + QEMU (reproducible, CI-friendly)

1. Write a Packer HCL template with a QEMU builder
2. Source: Rocky 9 GenericCloud qcow2 (same URL as current `rocky_image_url`)
3. Provisioner: shell script with all bake operations
4. Output: qcow2 artifact uploaded to Harvester
5. Can run in CI on a schedule (monthly) or on RKE2 version bumps

### Option C: Harvester VM Template (native)

1. Same as Option A, but save as a Harvester VM Template instead of raw image
2. Terraform references the template instead of an image
3. Requires changes to `machine_config.tf` disk_info

**Recommendation**: Start with Option A for validation, move to Option B for automation.

---

## Bake Provisioner Script

```bash
#!/bin/bash
set -euo pipefail
# golden-image-bake.sh — Run inside a Rocky 9 VM to prepare a golden image

echo "=== Phase 1: Package updates ==="
dnf update -y
dnf upgrade -y

echo "=== Phase 2: Install packages ==="
dnf install -y \
  qemu-guest-agent \
  iptables \
  iptables-services \
  container-selinux \
  policycoreutils-python-utils \
  audit

echo "=== Phase 3: RKE2 SELinux repo + package ==="
cat > /etc/yum.repos.d/rancher-rke2-common.repo << 'REPO'
[rancher-rke2-common]
name=Rancher RKE2 Common
baseurl=https://rpm.rancher.io/rke2/latest/common/centos/9/noarch
enabled=1
gpgcheck=1
gpgkey=https://rpm.rancher.io/public.key
REPO
dnf install -y rke2-selinux

echo "=== Phase 4: Iptables rules ==="
cat > /etc/sysconfig/iptables << 'IPTABLES'
*filter
:INPUT DROP [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -p tcp --dport 22 -j ACCEPT
-A INPUT -p tcp --dport 6443 -j ACCEPT
-A INPUT -p tcp --dport 9345 -j ACCEPT
-A INPUT -p tcp --dport 2379:2380 -j ACCEPT
-A INPUT -p tcp --dport 10250 -j ACCEPT
-A INPUT -p tcp --dport 10257 -j ACCEPT
-A INPUT -p tcp --dport 10259 -j ACCEPT
-A INPUT -p tcp --dport 30000:32767 -j ACCEPT
-A INPUT -p udp --dport 30000:32767 -j ACCEPT
-A INPUT -p tcp --dport 4240 -j ACCEPT
-A INPUT -p udp --dport 8472 -j ACCEPT
-A INPUT -p tcp --dport 4244 -j ACCEPT
-A INPUT -p tcp --dport 4245 -j ACCEPT
COMMIT
IPTABLES

echo "=== Phase 5: ARP hardening (harmless on single-NIC CP) ==="
cat > /etc/sysctl.d/90-arp.conf << 'ARP'
net.ipv4.conf.all.arp_ignore=1
net.ipv4.conf.all.arp_announce=2
ARP

echo "=== Phase 6: NM dispatcher for eth1 policy routing (no-op on CP) ==="
cat > /etc/NetworkManager/dispatcher.d/10-ingress-routing << 'DISPATCH'
#!/bin/bash
IFACE=$1
ACTION=$2
if [ "$IFACE" = "eth1" ] && [ "$ACTION" = "up" ]; then
  IP=$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
  SUBNET=$(ip -4 route show dev eth1 scope link | awk '{print $1}' | head -1)
  GW=$(ip -4 route show dev eth1 | grep default | awk '{print $3}')
  [ -z "$GW" ] && GW=$(ip -4 route show default | awk '{print $3}' | head -1)
  grep -q "^200 ingress" /etc/iproute2/rt_tables || echo "200 ingress" >> /etc/iproute2/rt_tables
  ip rule add from $IP table ingress priority 100 2>/dev/null || true
  ip route replace default via $GW dev eth1 table ingress 2>/dev/null || true
  [ -n "$SUBNET" ] && ip route replace $SUBNET dev eth1 table ingress 2>/dev/null || true
fi
DISPATCH
chmod 755 /etc/NetworkManager/dispatcher.d/10-ingress-routing
restorecon -R /etc/NetworkManager/dispatcher.d/ || true

echo "=== Phase 7: Pre-create RKE2 manifests directory ==="
mkdir -p /var/lib/rancher/rke2/server/manifests

echo "=== Phase 8: Service configuration ==="
systemctl enable qemu-guest-agent.service
systemctl disable firewalld || true
systemctl enable iptables
sysctl --system

echo "=== Phase 9: Clean for re-imaging ==="
dnf clean all
rm -rf /var/cache/dnf/*

# Reset cloud-init so it runs fresh on next boot
cloud-init clean --logs --seed
rm -rf /var/lib/cloud/instances/*

# Force new machine-id on next boot (critical for DHCP, systemd, Cilium)
truncate -s 0 /etc/machine-id

# Force new SSH host keys on next boot
rm -f /etc/ssh/ssh_host_*

# Remove bake-time SSH authorized_keys so cloud-init re-injects runtime keys
rm -f /home/rocky/.ssh/authorized_keys

# Clear shell history
history -c
rm -f /root/.bash_history /home/rocky/.bash_history

echo "=== Golden image ready. Shut down and export. ==="
```

---

## Terraform Changes Required

### image.tf

Two options depending on build approach:

**Option A — Pre-built image uploaded to Harvester:**

```hcl
# Reference a pre-existing golden image instead of downloading upstream Rocky
data "harvester_image" "golden" {
  name      = "rke2-rocky9-golden-v1"
  namespace = var.vm_namespace
}

locals {
  image_full_name = "${var.vm_namespace}/${data.harvester_image.golden.name}"
}
```

**Option B — Keep download-based but point to golden qcow2 (e.g., hosted on internal HTTP):**

```hcl
resource "harvester_image" "rocky9_golden" {
  name               = "${var.cluster_name}-rocky9-golden"
  namespace          = var.vm_namespace
  display_name       = "${var.cluster_name}-rocky9-golden"
  source_type        = "download"
  url                = var.golden_image_url   # new variable
  storage_class_name = "harvester-longhorn"
}
```

### machine_config.tf

Replace the large `user_data_cp` and `user_data_worker` locals:

```hcl
locals {
  # ... (keep network_info_cp, network_info_worker, image_full_name as-is) ...

  # iptables_rules local — REMOVE (baked into image)
  # user_data_worker becomes minimal:
  user_data_worker = <<-EOF
    #cloud-config

    ssh_authorized_keys:
    ${join("\n", [for key in var.ssh_authorized_keys : "  - ${key}"])}
  EOF

  # user_data_cp keeps only SSH keys + Cilium manifests:
  user_data_cp = <<-EOF
    #cloud-config

    ssh_authorized_keys:
    ${join("\n", [for key in var.ssh_authorized_keys : "  - ${key}"])}

    write_files:
    - path: /var/lib/rancher/rke2/server/manifests/cilium-lb-ippool.yaml
      permissions: '0644'
      content: |
        apiVersion: "cilium.io/v2alpha1"
        kind: CiliumLoadBalancerIPPool
        metadata:
          name: ingress-pool
        spec:
          blocks:
            - start: "203.0.113.202"
              stop: "203.0.113.220"

    - path: /var/lib/rancher/rke2/server/manifests/cilium-l2-policy.yaml
      permissions: '0644'
      content: |
        apiVersion: "cilium.io/v2alpha1"
        kind: CiliumL2AnnouncementPolicy
        metadata:
          name: l2-policy
        spec:
          serviceSelector:
            matchLabels: {}
          nodeSelector:
            matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
          interfaces:
            - ^eth1$
          externalIPs: true
          loadBalancerIPs: true
  EOF
}
```

The four `rancher2_machine_config_v2` resources remain unchanged — they already reference `local.user_data_cp` / `local.user_data_worker`.

---

## Optional Enhancement: Pre-stage RKE2 Binaries

Add to the bake script to eliminate RKE2 download time (~30-60s additional savings):

```bash
RKE2_VERSION="v1.34.2+rke2r1"
mkdir -p /var/lib/rancher/rke2/agent/images/
curl -sfL "https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/rke2-images-core.linux-amd64.tar.zst" \
  -o /var/lib/rancher/rke2/agent/images/rke2-images-core.linux-amd64.tar.zst
curl -sfL "https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/rke2-images-cilium.linux-amd64.tar.zst" \
  -o /var/lib/rancher/rke2/agent/images/rke2-images-cilium.linux-amd64.tar.zst
```

**Trade-off**: Saves 30-60s per node but locks the image to a specific RKE2 version. Must rebake on every RKE2 upgrade. Recommended only after the base golden image workflow is validated.

---

## Expected Time Savings

| Phase | Before (raw Rocky 9) | After (golden image) | Savings |
|-------|---------------------|---------------------|---------|
| cloud-init: dnf update+upgrade | 30-90s | 0s | 30-90s |
| cloud-init: package install | 15-30s | 0s | 15-30s |
| cloud-init: rke2-selinux | 10-20s | 0s | 10-20s |
| cloud-init: file writes + services | ~3s | ~1-2s (SSH keys + manifests) | ~1s |
| Rancher system-agent bootstrap | ~10s | ~10s | 0s |
| RKE2 download + install | 30-60s | 30-60s (0s if pre-staged) | 0s (or 30-60s) |
| RKE2 start + cluster join | 30-60s | 30-60s | 0s |
| **Total boot-to-ready** | **~130-260s** | **~70-130s** | **~55-140s** |
| **With RKE2 pre-stage** | **~130-260s** | **~40-70s** | **~90-200s** |

Biggest impact: **compute pool scale-from-zero** and **autoscaler cold starts** across all pools.

---

## Maintenance & Lifecycle

### When to Rebake

| Trigger | Urgency | Notes |
|---------|---------|-------|
| Monthly schedule | Low | Pick up Rocky 9 security patches |
| RKE2 version upgrade | Medium | If pre-staging RKE2 binaries |
| Iptables rule changes | Medium | Rules are baked; change = rebake |
| New packages needed | Medium | Add to bake script, rebake |
| Critical CVE in base packages | High | Rebake immediately |

### Image Versioning

Use a naming convention for traceability:

```
rke2-rocky9-golden-v{N}          # manual increments
rke2-rocky9-golden-20260211      # date-based (CI)
rke2-rocky9-golden-rke2v1.34.2   # version-tagged (if pre-staging)
```

### Drift Mitigation

- Nodes from older golden images still get patches via `dnf-automatic` or scheduled maintenance
- The golden image only accelerates initial provisioning — it doesn't replace ongoing patching
- Consider adding `package_update: true` back to runtime cloud-init if patch freshness matters more than speed (trade-off: adds ~30s back)

---

## Implementation Steps

1. **Write the bake script** — `packer/golden-image-bake.sh` (from Phase 9 above)
2. **Build v1 manually** — Create VM in Harvester, run script, export image
3. **Test with one pool** — Point the compute pool at the golden image, validate boot + join
4. **Roll out to all pools** — Update `image.tf` + slim down `machine_config.tf` cloud-init
5. **Validate autoscaler** — Trigger a scale-up, measure boot-to-ready delta
6. **Automate with Packer** (optional) — Create `packer/rocky9-golden.pkr.hcl` for CI builds
7. **Add RKE2 pre-stage** (optional) — After base workflow is solid, add binary caching

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Stale packages in golden image | Nodes boot with unpatched software | Monthly rebake schedule; `dnf-automatic` on running nodes |
| machine-id not reset properly | DHCP conflicts, Cilium node ID collisions | Bake script truncates `/etc/machine-id`; verify on first test |
| cloud-init doesn't re-run | SSH keys not injected, manifests missing | `cloud-init clean --logs --seed` + verify `cloud-init status` on test boot |
| Harvester image export breaks | Can't create golden image | Test export/import workflow before committing to this approach |
| Terraform state drift | Image resource changes unexpectedly | Use `data` source for pre-built images (no Terraform lifecycle) |
| Iptables rules change | Must remember to rebake, not just edit Terraform | Document in runbook; consider keeping iptables in runtime cloud-init if rules change often |

---

## Files to Create / Modify

| File | Action | Description |
|------|--------|-------------|
| `packer/golden-image-bake.sh` | Create | Bake provisioner script |
| `packer/rocky9-golden.pkr.hcl` | Create (later) | Packer template for CI automation |
| `cluster/image.tf` | Modify | Point to golden image instead of upstream Rocky |
| `cluster/machine_config.tf` | Modify | Slim cloud-init locals, remove `iptables_rules` local |
| `cluster/variables.tf` | Modify | Add `golden_image_url` or `golden_image_name` variable |
| `docs/golden-image-plan.md` | Create | This document |

## Related Documentation

- [System Architecture](engineering/system-architecture.md) - Node pools, infrastructure stack, autoscaling
- [Day-2 Operations](engineering/troubleshooting-sop.md#11-day-2-operations-procedures) - Node maintenance, scaling operations
- [Flow Charts](engineering/flow-charts.md) - Terraform infrastructure deployment flows
- [Troubleshooting SOP](engineering/troubleshooting-sop.md) - Node provisioning issues
