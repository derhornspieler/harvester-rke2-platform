output "vm_ip" {
  description = "VM IP address (from DHCP lease)"
  value       = harvester_virtualmachine.dev.network_interface[0].ip_address
}

output "ssh_command" {
  description = "SSH command to connect to the VM"
  value       = "ssh ${var.ssh_user}@${harvester_virtualmachine.dev.network_interface[0].ip_address}"
}
