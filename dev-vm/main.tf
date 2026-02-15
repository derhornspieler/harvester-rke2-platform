# -----------------------------------------------------------------------------
# Rocky 9 Image
# -----------------------------------------------------------------------------

resource "harvester_image" "rocky9" {
  name               = "${var.vm_name}-rocky9"
  namespace          = var.vm_namespace
  display_name       = "${var.vm_name}-rocky9"
  source_type        = "download"
  url                = var.rocky_image_url
  storage_class_name = "harvester-longhorn"

  timeouts {
    create = "30m"
  }
}

# -----------------------------------------------------------------------------
# Cloud-Init
# -----------------------------------------------------------------------------

locals {
  user_data = join("\n", [
    "#cloud-config",
    yamlencode({
      hostname         = var.vm_name
      manage_etc_hosts = true
      package_update   = true
      package_upgrade  = true

      ssh_authorized_keys = var.ssh_authorized_keys

      packages = [
        "qemu-guest-agent", "tmux", "htop", "tree", "unzip", "bash-completion",
        "git", "make", "gcc", "golang", "python3", "python3-pip",
        "jq", "openssl", "curl", "wget",
        "cryptsetup",
        "dnf-automatic",
      ]

      write_files = [
        {
          path = "/etc/dnf/automatic.conf"
          content = join("\n", [
            "[commands]",
            "upgrade_type = security",
            "apply_updates = yes",
            "[emitters]",
            "emit_via = stdio",
            "",
          ])
        },
      ]

      runcmd = [
        # Install critical packages explicitly (cloud-init packages: module can fail on golden images)
        "dnf install -y qemu-guest-agent cryptsetup",
        "systemctl enable --now qemu-guest-agent",
        "dd if=/dev/urandom of=/root/.luks-keyfile bs=4096 count=1",
        "chmod 0400 /root/.luks-keyfile",
        "cryptsetup luksFormat --type luks2 --batch-mode /dev/vdb /root/.luks-keyfile",
        "cryptsetup luksOpen /dev/vdb devdata --key-file /root/.luks-keyfile",
        "mkfs.ext4 -L devdata /dev/mapper/devdata",
        "mkdir -p /home/${var.ssh_user}/data",
        "mount /dev/mapper/devdata /home/${var.ssh_user}/data",
        "chown ${var.ssh_user}:${var.ssh_user} /home/${var.ssh_user}/data",
        "echo 'devdata /dev/vdb /root/.luks-keyfile luks' >> /etc/crypttab",
        "echo '/dev/mapper/devdata /home/${var.ssh_user}/data ext4 defaults 0 2' >> /etc/fstab",
        "dnf module enable -y nodejs:22 || true",
        "dnf install -y nodejs npm || (curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - && dnf install -y nodejs)",
        "npm install -g @anthropic-ai/claude-code",
        "curl -LO https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl",
        "install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl",
        "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash",
        "dnf install -y dnf-plugins-core",
        "dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo",
        "dnf install -y terraform",
        "systemctl enable --now dnf-automatic-install.timer",
        "ln -sfn /home/${var.ssh_user}/data /home/${var.ssh_user}/code",
      ]
    }),
  ])
}

# -----------------------------------------------------------------------------
# Developer VM
# -----------------------------------------------------------------------------

resource "harvester_virtualmachine" "dev" {
  name                 = var.vm_name
  namespace            = var.vm_namespace
  restart_after_update = true

  description = "Developer VM — Rocky 9 with Claude Code, LUKS data disk"

  cpu    = var.cpu
  memory = var.memory

  efi         = true
  secure_boot = false

  run_strategy = "RerunOnFailure"

  machine_type = "q35"

  network_interface {
    name           = "nic-1"
    network_name   = var.network_name
    wait_for_lease = true
  }

  disk {
    name       = "rootdisk"
    type       = "disk"
    size       = var.os_disk_size
    bus        = "virtio"
    boot_order = 1
    image      = harvester_image.rocky9.id
  }

  disk {
    name = "datadisk"
    type = "disk"
    size = var.data_disk_size
    bus  = "virtio"
  }

  cloudinit {
    user_data_secret_name = harvester_cloudinit_secret.dev.name
  }

  timeouts {
    create = "30m"
  }
}

# -----------------------------------------------------------------------------
# Cloud-Init Secret
# -----------------------------------------------------------------------------

resource "harvester_cloudinit_secret" "dev" {
  name      = "${var.vm_name}-cloudinit"
  namespace = var.vm_namespace

  user_data = local.user_data
}
