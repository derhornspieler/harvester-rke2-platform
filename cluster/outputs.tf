output "cluster_id" {
  description = "Rancher v2 cluster ID"
  value       = rancher2_cluster_v2.rke2.id
}

output "cluster_name" {
  description = "Cluster name"
  value       = rancher2_cluster_v2.rke2.name
}

output "cluster_v1_id" {
  description = "Rancher v1 cluster ID (c-xxxxx format)"
  value       = rancher2_cluster_v2.rke2.cluster_v1_id
}

output "image_id" {
  description = "Harvester image ID"
  value       = var.use_golden_image ? data.harvester_image.golden[0].id : harvester_image.rocky9[0].id
}

output "cloud_credential_id" {
  description = "Rancher cloud credential ID"
  value       = rancher2_cloud_credential.harvester.id
}
