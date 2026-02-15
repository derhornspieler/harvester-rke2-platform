# -----------------------------------------------------------------------------
# Base Rocky 9 image (temporary — used only by the builder VM)
# -----------------------------------------------------------------------------

resource "harvester_image" "rocky9_base" {
  name               = "golden-builder-rocky9-base"
  namespace          = var.vm_namespace
  display_name       = "golden-builder-rocky9-base"
  source_type        = "download"
  url                = var.rocky_image_url
  storage_class_name = "harvester-longhorn"

  timeouts {
    create = "30m"
  }
}

# -----------------------------------------------------------------------------
# Cloud-init Secret (exceeds KubeVirt 2048 byte inline limit)
# -----------------------------------------------------------------------------

resource "kubernetes_secret" "cloudinit" {
  metadata {
    name      = "${var.image_name_prefix}-builder-cloudinit"
    namespace = var.vm_namespace
  }

  data = {
    userdata = templatefile("${path.module}/templates/cloud-init.yaml.tpl", {
      ssh_authorized_keys    = var.ssh_authorized_keys
      rocky_image_url        = var.rocky_image_url
      airgapped              = var.airgapped
      private_ca_pem         = var.private_ca_pem
      private_rocky_repo_url = var.private_rocky_repo_url
      private_rke2_repo_url  = var.private_rke2_repo_url
    })
  }
}

# -----------------------------------------------------------------------------
# Utility VM — runs virt-customize and serves result via HTTP
# -----------------------------------------------------------------------------

resource "harvester_virtualmachine" "utility" {
  name      = "${var.image_name_prefix}-builder"
  namespace = var.vm_namespace
  cpu       = var.builder_cpu
  memory    = var.builder_memory

  run_strategy = "RerunOnFailure"
  hostname     = "golden-builder"
  machine_type = "q35"
  efi          = true
  secure_boot  = false

  network_interface {
    name           = "nic-1"
    network_name   = "${var.harvester_network_namespace}/${var.harvester_network_name}"
    wait_for_lease = true
  }

  disk {
    name        = "rootdisk"
    type        = "disk"
    size        = var.builder_disk_size
    bus         = "virtio"
    boot_order  = 1
    image       = harvester_image.rocky9_base.id
    auto_delete = true
  }

  cloudinit {
    user_data_secret_name = kubernetes_secret.cloudinit.metadata[0].name
  }

  lifecycle {
    precondition {
      condition     = var.airgapped == false || var.private_ca_pem != ""
      error_message = "private_ca_pem is required when airgapped is true."
    }
    precondition {
      condition     = var.airgapped == false || var.private_rocky_repo_url != ""
      error_message = "private_rocky_repo_url is required when airgapped is true."
    }
    precondition {
      condition     = var.airgapped == false || var.private_rke2_repo_url != ""
      error_message = "private_rke2_repo_url is required when airgapped is true."
    }
  }

  timeouts {
    create = "30m"
  }
}
