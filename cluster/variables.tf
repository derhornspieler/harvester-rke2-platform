# -----------------------------------------------------------------------------
# Rancher Connection
# -----------------------------------------------------------------------------

variable "rancher_url" {
  description = "Rancher API URL (e.g. https://rancher.example.com)"
  type        = string
}

variable "rancher_token" {
  description = "Rancher API token (format: token-xxxxx:xxxxxxxxxxxx)"
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Harvester Connection
# -----------------------------------------------------------------------------

variable "harvester_kubeconfig_path" {
  description = "Path to Harvester cluster kubeconfig (for state backend and image upload)"
  type        = string
}

variable "harvester_cloud_credential_kubeconfig_path" {
  description = "Path to Harvester kubeconfig for Rancher cloud credential (uses SA token, not Rancher user token)"
  type        = string
  default     = "./kubeconfig-harvester-cloud-cred.yaml"
}

variable "harvester_cluster_id" {
  description = "Harvester management cluster ID in Rancher (e.g. c-bdrxb)"
  type        = string
}

# -----------------------------------------------------------------------------
# Cluster Configuration
# -----------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name for the RKE2 cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the RKE2 cluster"
  type        = string
  default     = "v1.34.2+rke2r1"
}

variable "cni" {
  description = "CNI plugin for the cluster"
  type        = string
  default     = "cilium"
}

variable "traefik_lb_ip" {
  description = "Static LoadBalancer IP for Traefik ingress"
  type        = string
  default     = "198.51.100.2"
}

variable "domain" {
  description = "Root domain for service FQDNs (e.g., example.com)"
  type        = string
}

variable "keycloak_realm" {
  description = "Keycloak realm name (e.g., example)"
  type        = string
}

# -----------------------------------------------------------------------------
# Harvester Networking
# -----------------------------------------------------------------------------

variable "vm_namespace" {
  description = "Harvester namespace where VMs will be created"
  type        = string
}

variable "harvester_network_name" {
  description = "Name of the Harvester VM network"
  type        = string
}

variable "harvester_network_namespace" {
  description = "Namespace of the Harvester VM network (usually same as vm_namespace)"
  type        = string
}

variable "harvester_services_network_name" {
  description = "Name of the Harvester services/ingress network (eth1, VLAN 5)"
  type        = string
  default     = "services-network"
}

variable "harvester_services_network_namespace" {
  description = "Namespace of the Harvester services network"
  type        = string
  default     = "default"
}

# -----------------------------------------------------------------------------
# Rocky 9 Image
# -----------------------------------------------------------------------------

variable "rocky_image_url" {
  description = "Download URL for Rocky 9 GenericCloud qcow2 image"
  type        = string
  default     = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
}

variable "use_golden_image" {
  description = "Use pre-baked golden image instead of vanilla Rocky 9"
  type        = bool
  default     = false
}

variable "golden_image_name" {
  description = "Name of golden image in Harvester (required when use_golden_image = true)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Control Plane Pool
# -----------------------------------------------------------------------------

variable "controlplane_count" {
  description = "Number of control plane nodes (should be odd for etcd quorum)"
  type        = number
  default     = 3
}

variable "controlplane_cpu" {
  description = "vCPUs per control plane node"
  type        = string
  default     = "8"
}

variable "controlplane_memory" {
  description = "Memory (GiB) per control plane node"
  type        = string
  default     = "32"
}

variable "controlplane_disk_size" {
  description = "Disk size (GiB) per control plane node"
  type        = number
  default     = 80
}

# -----------------------------------------------------------------------------
# General Worker Pool
# -----------------------------------------------------------------------------

variable "general_cpu" {
  description = "vCPUs per general worker node"
  type        = string
  default     = "4"
}

variable "general_memory" {
  description = "Memory (GiB) per general worker node"
  type        = string
  default     = "8"
}

variable "general_disk_size" {
  description = "Disk size (GiB) per general worker node"
  type        = number
  default     = 60
}

variable "general_min_count" {
  description = "Minimum number of general worker nodes (autoscaler)"
  type        = number
  default     = 4
}

variable "general_max_count" {
  description = "Maximum number of general worker nodes (autoscaler)"
  type        = number
  default     = 10
}

# -----------------------------------------------------------------------------
# Compute Worker Pool
# -----------------------------------------------------------------------------

variable "compute_cpu" {
  description = "vCPUs per compute worker node"
  type        = string
  default     = "8"
}

variable "compute_memory" {
  description = "Memory (GiB) per compute worker node"
  type        = string
  default     = "32"
}

variable "compute_disk_size" {
  description = "Disk size (GiB) per compute worker node"
  type        = number
  default     = 80
}

variable "compute_min_count" {
  description = "Minimum number of compute worker nodes (autoscaler, 0 = scale from zero)"
  type        = number
  default     = 0
}

variable "compute_max_count" {
  description = "Maximum number of compute worker nodes (autoscaler)"
  type        = number
  default     = 10
}

# -----------------------------------------------------------------------------
# Database Worker Pool
# -----------------------------------------------------------------------------

variable "database_cpu" {
  description = "vCPUs per database worker node"
  type        = string
  default     = "4"
}

variable "database_memory" {
  description = "Memory (GiB) per database worker node"
  type        = string
  default     = "16"
}

variable "database_disk_size" {
  description = "Disk size (GiB) per database worker node"
  type        = number
  default     = 80
}

variable "database_min_count" {
  description = "Minimum number of database worker nodes (autoscaler)"
  type        = number
  default     = 4
}

variable "database_max_count" {
  description = "Maximum number of database worker nodes (autoscaler)"
  type        = number
  default     = 10
}

# -----------------------------------------------------------------------------
# Cluster Autoscaler Behavior
# -----------------------------------------------------------------------------

variable "autoscaler_scale_down_unneeded_time" {
  description = "How long a node must be unneeded before the autoscaler removes it (e.g., 30m0s)"
  type        = string
  default     = "30m0s"
}

variable "autoscaler_scale_down_delay_after_add" {
  description = "Cooldown after adding a node before any scale-down is considered (e.g., 15m0s)"
  type        = string
  default     = "15m0s"
}

variable "autoscaler_scale_down_delay_after_delete" {
  description = "Cooldown after deleting a node before the next scale-down (e.g., 30m0s)"
  type        = string
  default     = "30m0s"
}

variable "autoscaler_scale_down_utilization_threshold" {
  description = "CPU/memory request utilization below which a node is considered unneeded (0.0–1.0)"
  type        = string
  default     = "0.5"
}

# -----------------------------------------------------------------------------
# Docker Hub Auth (rate-limit workaround until Harbor mirrors are in place)
# -----------------------------------------------------------------------------

variable "dockerhub_username" {
  description = "Docker Hub username for authenticated pulls"
  type        = string
  default     = ""
}

variable "dockerhub_token" {
  description = "Docker Hub personal access token"
  type        = string
  sensitive   = true
  default     = ""
}

# -----------------------------------------------------------------------------
# Cloud Provider
# -----------------------------------------------------------------------------

variable "harvester_cloud_credential_name" {
  description = "Name of the pre-existing Harvester cloud credential in Rancher"
  type        = string
}

variable "harvester_cloud_provider_kubeconfig_path" {
  description = "Path to the Harvester cloud provider kubeconfig file"
  type        = string
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
  description = "List of SSH public keys to add to all nodes"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Cloud-Init Override
# -----------------------------------------------------------------------------

variable "user_data_cp_file" {
  description = "Path to custom cloud-init YAML for control plane nodes (overrides built-in template)"
  type        = string
  default     = ""
}

variable "user_data_worker_file" {
  description = "Path to custom cloud-init YAML for worker nodes (overrides built-in template)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Airgapped Mode
# -----------------------------------------------------------------------------

variable "airgapped" {
  description = "Enable airgapped mode (private repos, system-default-registry)"
  type        = bool
  default     = false
}

variable "private_rocky_repo_url" {
  description = "Base URL for private Rocky 9 repo mirror (required when airgapped = true)"
  type        = string
  default     = ""
}

variable "private_rke2_repo_url" {
  description = "Base URL for private RKE2 repo mirror (required when airgapped = true)"
  type        = string
  default     = ""
}

variable "private_ca_pem" {
  description = "PEM-encoded private CA certificate (required when airgapped = true)"
  type        = string
  default     = ""
  sensitive   = true
}

# --- Airgapped Bootstrap Registry ---
variable "bootstrap_registry" {
  description = "Pre-existing container registry for airgapped bootstrap (used as system-default-registry). Must contain RKE2 system images."
  type        = string
  default     = ""
}

variable "bootstrap_registry_ca_pem" {
  description = "PEM-encoded CA cert for bootstrap registry TLS (if different from private_ca_pem)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "bootstrap_registry_username" {
  description = "Username for bootstrap registry authentication"
  type        = string
  default     = ""
}

variable "bootstrap_registry_password" {
  description = "Password for bootstrap registry authentication"
  type        = string
  default     = ""
  sensitive   = true
}
