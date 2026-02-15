locals {
  # ---------------------------------------------------------------------------
  # Network Info: CP (single NIC) vs Worker (dual NIC)
  # ---------------------------------------------------------------------------
  network_info_cp = jsonencode({
    interfaces = [{
      networkName = "${var.harvester_network_namespace}/${var.harvester_network_name}"
    }]
  })

  network_info_worker = jsonencode({
    interfaces = [
      { networkName = "${var.harvester_network_namespace}/${var.harvester_network_name}" },
      { networkName = "${var.harvester_services_network_namespace}/${var.harvester_services_network_name}" },
    ]
  })

  # ---------------------------------------------------------------------------
  # Conditional image reference
  # ---------------------------------------------------------------------------
  image_full_name = var.use_golden_image ? (
    "${var.vm_namespace}/${data.harvester_image.golden[0].name}"
  ) : (
    "${var.vm_namespace}/${harvester_image.rocky9[0].name}"
  )

  # ---------------------------------------------------------------------------
  # Conditional cloud-init: golden (minimal) vs full (vanilla Rocky 9)
  # ---------------------------------------------------------------------------
  user_data_cp     = var.use_golden_image ? local._user_data_cp_golden : local._user_data_cp_full
  user_data_worker = var.use_golden_image ? local._user_data_worker_golden : local._user_data_worker_full

  # ---------------------------------------------------------------------------
  # Golden mode: SSH keys + Cilium manifests only (CP), SSH keys only (workers)
  # ---------------------------------------------------------------------------
  _user_data_cp_golden = <<-EOF
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
            - start: "198.51.100.2"
              stop: "198.51.100.20"

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

  _user_data_worker_golden = <<-EOF
    #cloud-config

    ssh_authorized_keys:
    ${join("\n", [for key in var.ssh_authorized_keys : "  - ${key}"])}
  EOF

  # ---------------------------------------------------------------------------
  # Full mode: complete cloud-init for vanilla Rocky 9 (current behavior)
  # ---------------------------------------------------------------------------
  iptables_rules = chomp(<<-EOT
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
-A INPUT -p tcp --dport 2379:2381 -j ACCEPT
-A INPUT -p tcp --dport 10250 -j ACCEPT
-A INPUT -p tcp --dport 10257 -j ACCEPT
-A INPUT -p tcp --dport 10259 -j ACCEPT
-A INPUT -p tcp --dport 30000:32767 -j ACCEPT
-A INPUT -p udp --dport 30000:32767 -j ACCEPT
-A INPUT -p tcp --dport 4240 -j ACCEPT
-A INPUT -p udp --dport 8472 -j ACCEPT
-A INPUT -p tcp --dport 4244 -j ACCEPT
-A INPUT -p tcp --dport 4245 -j ACCEPT
-A INPUT -p tcp --dport 9962 -j ACCEPT
COMMIT
EOT
  )

  _user_data_cp_full = <<-EOF
    #cloud-config
    package_update: true
    package_upgrade: true

    ssh_authorized_keys:
    ${join("\n", [for key in var.ssh_authorized_keys : "  - ${key}"])}

    packages:
    - qemu-guest-agent
    - iptables
    - iptables-services
    - container-selinux
    - policycoreutils-python-utils
    - audit

    write_files:
    - path: /etc/yum.repos.d/rancher-rke2-common.repo
      permissions: '0644'
      content: |
        [rancher-rke2-common]
        name=Rancher RKE2 Common
        baseurl=https://rpm.rancher.io/rke2/latest/common/centos/9/noarch
        enabled=1
        gpgcheck=1
        gpgkey=https://rpm.rancher.io/public.key

    - path: /etc/yum.repos.d/rancher-rke2-1-34.repo
      permissions: '0644'
      content: |
        [rancher-rke2-1-34]
        name=Rancher RKE2 1.34
        baseurl=https://rpm.rancher.io/rke2/latest/1.34/centos/9/x86_64
        enabled=1
        gpgcheck=1
        gpgkey=https://rpm.rancher.io/public.key

    - path: /etc/yum.repos.d/epel.repo
      permissions: '0644'
      content: |
        [epel]
        name=Extra Packages for Enterprise Linux 9
        metalink=https://mirrors.fedoraproject.org/metalink?repo=epel-9&arch=x86_64
        enabled=1
        gpgcheck=1
        gpgkey=https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-9

    - path: /etc/sysconfig/iptables
      permissions: '0600'
      content: |
        ${indent(4, local.iptables_rules)}

    - path: /var/lib/rancher/rke2/server/manifests/cilium-lb-ippool.yaml
      permissions: '0644'
      content: |
        apiVersion: "cilium.io/v2alpha1"
        kind: CiliumLoadBalancerIPPool
        metadata:
          name: ingress-pool
        spec:
          blocks:
            - start: "198.51.100.2"
              stop: "198.51.100.20"

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

    runcmd:
    - mkdir -p /var/lib/rancher/rke2/server/manifests
    - systemctl enable --now qemu-guest-agent.service
    - systemctl disable --now firewalld || true
    - dnf install -y rke2-selinux
    - systemctl enable --now iptables
  EOF

  _user_data_worker_full = <<-EOF
    #cloud-config
    package_update: true
    package_upgrade: true

    ssh_authorized_keys:
    ${join("\n", [for key in var.ssh_authorized_keys : "  - ${key}"])}

    packages:
    - qemu-guest-agent
    - iptables
    - iptables-services
    - container-selinux
    - policycoreutils-python-utils
    - audit

    write_files:
    - path: /etc/yum.repos.d/rancher-rke2-common.repo
      permissions: '0644'
      content: |
        [rancher-rke2-common]
        name=Rancher RKE2 Common
        baseurl=https://rpm.rancher.io/rke2/latest/common/centos/9/noarch
        enabled=1
        gpgcheck=1
        gpgkey=https://rpm.rancher.io/public.key

    - path: /etc/yum.repos.d/rancher-rke2-1-34.repo
      permissions: '0644'
      content: |
        [rancher-rke2-1-34]
        name=Rancher RKE2 1.34
        baseurl=https://rpm.rancher.io/rke2/latest/1.34/centos/9/x86_64
        enabled=1
        gpgcheck=1
        gpgkey=https://rpm.rancher.io/public.key

    - path: /etc/yum.repos.d/epel.repo
      permissions: '0644'
      content: |
        [epel]
        name=Extra Packages for Enterprise Linux 9
        metalink=https://mirrors.fedoraproject.org/metalink?repo=epel-9&arch=x86_64
        enabled=1
        gpgcheck=1
        gpgkey=https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-9

    - path: /etc/sysconfig/iptables
      permissions: '0600'
      content: |
        ${indent(4, local.iptables_rules)}

    - path: /etc/sysctl.d/90-arp.conf
      permissions: '0644'
      content: |
        net.ipv4.conf.all.arp_ignore=1
        net.ipv4.conf.all.arp_announce=2

    - path: /etc/NetworkManager/dispatcher.d/10-ingress-routing
      permissions: '0755'
      content: |
        #!/bin/bash
        # Policy routing for ingress NIC (eth1)
        # Ensures traffic from eth1's IP replies via eth1
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

    runcmd:
    - systemctl enable --now qemu-guest-agent.service
    - systemctl disable --now firewalld || true
    - dnf install -y rke2-selinux
    - systemctl enable --now iptables
    - sysctl --system
    - restorecon -R /etc/NetworkManager/dispatcher.d/ || true
  EOF
}

# -----------------------------------------------------------------------------
# Control Plane Nodes
# -----------------------------------------------------------------------------
resource "rancher2_machine_config_v2" "controlplane" {
  generate_name = "${var.cluster_name}-cp"

  harvester_config {
    vm_namespace         = var.vm_namespace
    cpu_count            = var.controlplane_cpu
    memory_size          = var.controlplane_memory
    reserved_memory_size = "-1"
    ssh_user             = var.ssh_user
    user_data            = var.user_data_cp_file != "" ? file(var.user_data_cp_file) : local.user_data_cp

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.controlplane_disk_size
        bootOrder = 1
      }]
    })

    network_info = local.network_info_cp
  }
}

# -----------------------------------------------------------------------------
# General Worker Nodes
# -----------------------------------------------------------------------------
resource "rancher2_machine_config_v2" "general" {
  generate_name = "${var.cluster_name}-general"

  harvester_config {
    vm_namespace         = var.vm_namespace
    cpu_count            = var.general_cpu
    memory_size          = var.general_memory
    reserved_memory_size = "-1"
    ssh_user             = var.ssh_user
    user_data            = var.user_data_worker_file != "" ? file(var.user_data_worker_file) : local.user_data_worker

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.general_disk_size
        bootOrder = 1
      }]
    })

    network_info = local.network_info_worker
  }
}

# -----------------------------------------------------------------------------
# Compute Worker Nodes
# -----------------------------------------------------------------------------
resource "rancher2_machine_config_v2" "compute" {
  generate_name = "${var.cluster_name}-compute"

  harvester_config {
    vm_namespace         = var.vm_namespace
    cpu_count            = var.compute_cpu
    memory_size          = var.compute_memory
    reserved_memory_size = "-1"
    ssh_user             = var.ssh_user
    user_data            = var.user_data_worker_file != "" ? file(var.user_data_worker_file) : local.user_data_worker

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.compute_disk_size
        bootOrder = 1
      }]
    })

    network_info = local.network_info_worker
  }
}

# -----------------------------------------------------------------------------
# Database Worker Nodes
# -----------------------------------------------------------------------------
resource "rancher2_machine_config_v2" "database" {
  generate_name = "${var.cluster_name}-database"

  harvester_config {
    vm_namespace         = var.vm_namespace
    cpu_count            = var.database_cpu
    memory_size          = var.database_memory
    reserved_memory_size = "-1"
    ssh_user             = var.ssh_user
    user_data            = var.user_data_worker_file != "" ? file(var.user_data_worker_file) : local.user_data_worker

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.database_disk_size
        bootOrder = 1
      }]
    })

    network_info = local.network_info_worker
  }
}
