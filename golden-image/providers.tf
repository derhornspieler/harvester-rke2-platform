provider "harvester" {
  kubeconfig = var.harvester_kubeconfig_path
}

provider "kubernetes" {
  config_path = var.harvester_kubeconfig_path
}
