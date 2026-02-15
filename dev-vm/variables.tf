# -----------------------------------------------------------------------------
# Harvester Connection
# -----------------------------------------------------------------------------

variable "harvester_kubeconfig_path" {
  description = "Path to Harvester cluster kubeconfig"
  type        = string
}

# -----------------------------------------------------------------------------
# VM Configuration
# -----------------------------------------------------------------------------

variable "vm_namespace" {
  description = "Harvester namespace where the VM will be created"
  type        = string
  default     = "default"
}

variable "vm_name" {
  description = "Name of the developer VM"
  type        = string
  default     = "dev-vm"
}

variable "cpu" {
  description = "Number of vCPUs"
  type        = number
  default     = 8
}

variable "memory" {
  description = "Memory size (Kubernetes quantity, e.g. 16Gi)"
  type        = string
  default     = "16Gi"
}

variable "os_disk_size" {
  description = "OS disk size (Kubernetes quantity)"
  type        = string
  default     = "50Gi"
}

variable "data_disk_size" {
  description = "Encrypted data disk size (Kubernetes quantity)"
  type        = string
  default     = "200Gi"
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "network_name" {
  description = "Harvester VM network in namespace/name format"
  type        = string
  default     = "default/vm-network"
}

# -----------------------------------------------------------------------------
# SSH
# -----------------------------------------------------------------------------

variable "ssh_user" {
  description = "SSH user for the cloud image"
  type        = string
  default     = "rocky"
}

variable "ssh_authorized_keys" {
  description = "List of SSH public keys to add to the VM"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Rocky 9 Image
# -----------------------------------------------------------------------------

variable "rocky_image_url" {
  description = "Download URL for Rocky 9 GenericCloud qcow2 image"
  type        = string
  default     = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
}
