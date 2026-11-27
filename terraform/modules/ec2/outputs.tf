# --- Puppet Server (EC2 1) ---
output "puppet_server_id" {
  description = "EC2 Instance ID of Puppet Server"
  value       = aws_instance.puppet_server.id
}

output "puppet_server_public_ip" {
  description = "Public IPv4 address of Puppet Server"
  value       = aws_instance.puppet_server.public_ip
}

output "puppet_server_private_ip" {
  description = "Private IPv4 address of Puppet Server"
  value       = aws_instance.puppet_server.private_ip
}

output "puppet_server_private_dns" {
  description = "Private DNS of Puppet Server"
  value       = aws_instance.puppet_server.private_dns
}

# --- Application and Monitoring Server (EC2 2) ---
output "app_server_id" {
  description = "EC2 Instance ID of Application & Monitoring Server"
  value       = aws_instance.app_monitoring.id
}

output "app_server_public_ip" {
  description = "Public IPv4 address of Application & Monitoring Server"
  value       = aws_instance.app_monitoring.public_ip
}

output "app_server_public_dns" {
  description = "Public DNS of Application & Monitoring Server"
  value       = aws_instance.app_monitoring.public_dns
}

output "app_server_private_ip" {
  description = "Private IPv4 address of Application & Monitoring Server"
  value       = aws_instance.app_monitoring.private_ip
}

# --- CI/CD and Analysis Server (EC2 3) ---
output "cicd_server_id" {
  description = "EC2 Instance ID of CI/CD & Analysis Server"
  value       = aws_instance.cicd_analysis.id
}

output "cicd_server_public_ip" {
  description = "Public IPv4 address of CI/CD & Analysis Server"
  value       = aws_instance.cicd_analysis.public_ip
}

output "cicd_server_private_ip" {
  description = "Private IPv4 address of CI/CD & Analysis Server"
  value       = aws_instance.cicd_analysis.private_ip
}

# --- Ansible Inventory Helper Output ---
output "ansible_inventory_template" {
  description = "Pre-formatted Ansible inventory block based on provisioned instances"
  value       = <<-EOT
    [puppet_server]
    puppet-server ansible_host=${aws_instance.puppet_server.public_ip} private_ip=${aws_instance.puppet_server.private_ip}

    [application]
    app-server ansible_host=${aws_instance.app_monitoring.public_ip} private_ip=${aws_instance.app_monitoring.private_ip}

    [cicd]
    cicd-server ansible_host=${aws_instance.cicd_analysis.public_ip} private_ip=${aws_instance.cicd_analysis.private_ip}

    [puppet_agents:children]
    application
    cicd
  EOT
}
