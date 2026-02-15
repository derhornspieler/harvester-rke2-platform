terraform {
  required_version = ">= 1.5.0"

  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "~> 0.6"
    }
  }

  backend "kubernetes" {
    secret_suffix = "dev-vm"
    namespace     = "terraform-state"
    config_path   = "kubeconfig-harvester.yaml"
  }
}
