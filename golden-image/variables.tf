# -----------------------------------------------------------------------------
# Harvester Connection
# -----------------------------------------------------------------------------

variable "harvester_kubeconfig_path" {
  description = "Path to Harvester kubeconfig"
  type        = string
  default     = "./kubeconfig-harvester.yaml"
}

variable "vm_namespace" {
  description = "Harvester namespace (same as cluster VMs)"
  type        = string
}

# -----------------------------------------------------------------------------
# Base Image
# -----------------------------------------------------------------------------

variable "rocky_image_url" {
  description = "Base Rocky 9 GenericCloud qcow2 URL (or internal mirror URL when airgapped)"
  type        = string
  default     = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
}

# -----------------------------------------------------------------------------
# Builder VM
# -----------------------------------------------------------------------------

variable "builder_cpu" {
  description = "vCPUs for utility VM (more = faster dnf inside virt-customize)"
  type        = number
  default     = 4
}

variable "builder_memory" {
  description = "Memory for utility VM"
  type        = string
  default     = "4Gi"
}

variable "builder_disk_size" {
  description = "Disk for utility VM (needs space for 2x qcow2 + tools)"
  type        = string
  default     = "30Gi"
}

variable "image_name_prefix" {
  description = "Prefix for golden image name"
  type        = string
  default     = "rke2-rocky9-golden"
}

variable "ssh_authorized_keys" {
  description = "SSH keys for utility VM (debug access, NOT baked into golden image)"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Harvester Networking
# -----------------------------------------------------------------------------

variable "harvester_network_name" {
  description = "Harvester VM network name"
  type        = string
}

variable "harvester_network_namespace" {
  description = "Harvester VM network namespace"
  type        = string
}

# -----------------------------------------------------------------------------
# Airgapped Mode
# -----------------------------------------------------------------------------

variable "airgapped" {
  description = "Build in airgapped mode: use private CA + private repos instead of internet"
  type        = bool
  default     = false
}

variable "private_ca_pem" {
  description = "PEM-encoded private CA certificate (required when airgapped = true)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "private_rocky_repo_url" {
  description = "Base URL for private Rocky 9 repo mirror (BaseOS + AppStream + EPEL, required when airgapped)"
  type        = string
  default     = ""
}

variable "private_rke2_repo_url" {
  description = "Base URL for private RKE2 common repo mirror (rke2-selinux, required when airgapped)"
  type        = string
  default     = ""
}
