# --- Puppet Server (EC2 1) ---
output "puppet_server_id" {
  description = "EC2 Instance ID of the dedicated Puppet Server"
  value       = module.ec2.puppet_server_id
}

output "puppet_server_public_ip" {
  description = "Public IPv4 address of the Puppet Server"
  value       = module.ec2.puppet_server_public_ip
}

output "puppet_server_private_ip" {
  description = "Private IPv4 address of the Puppet Server"
  value       = module.ec2.puppet_server_private_ip
}

output "puppet_server_private_dns" {
  description = "Private DNS name of the Puppet Server"
  value       = module.ec2.puppet_server_private_dns
}

# --- Application and Monitoring Server (EC2 2) ---
output "app_server_id" {
  description = "EC2 Instance ID of the Application & Monitoring Server"
  value       = module.ec2.app_server_id
}

output "app_server_public_ip" {
  description = "Public IPv4 address of the Application & Monitoring Server"
  value       = module.ec2.app_server_public_ip
}

output "app_server_public_dns" {
  description = "Public DNS of the Application & Monitoring Server"
  value       = module.ec2.app_server_public_dns
}

output "app_server_private_ip" {
  description = "Private IPv4 address of the Application & Monitoring Server"
  value       = module.ec2.app_server_private_ip
}

# --- CI/CD and Analysis Server (EC2 3) ---
output "cicd_server_id" {
  description = "EC2 Instance ID of the CI/CD & Analysis Server"
  value       = module.ec2.cicd_server_id
}

output "cicd_server_public_ip" {
  description = "Public IPv4 address of the CI/CD & Analysis Server"
  value       = module.ec2.cicd_server_public_ip
}

output "cicd_server_private_ip" {
  description = "Private IPv4 address of the CI/CD & Analysis Server"
  value       = module.ec2.cicd_server_private_ip
}

# --- Ansible Inventory Helper Output ---
output "ansible_inventory_template" {
  description = "Pre-formatted Ansible inventory block based on provisioned instances"
  value       = module.ec2.ansible_inventory_template
}
