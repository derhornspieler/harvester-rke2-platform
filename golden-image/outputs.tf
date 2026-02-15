output "utility_vm_name" {
  value = harvester_virtualmachine.utility.name
}

output "utility_vm_namespace" {
  value = harvester_virtualmachine.utility.namespace
}

output "utility_vm_ip" {
  description = "IP address of the utility VM (for HTTP download)"
  value       = harvester_virtualmachine.utility.network_interface[0].ip_address
}
