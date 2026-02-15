terraform {
  required_version = ">= 1.5.0"

  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "~> 0.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  backend "kubernetes" {
    secret_suffix = "golden-image"
    namespace     = "terraform-state"
    config_path   = "kubeconfig-harvester.yaml"
  }
}
