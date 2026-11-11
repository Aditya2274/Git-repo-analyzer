output "instance_id" {
  description = "EC2 instance ID"
  value       = module.ec2.instance_id
}

output "public_ip" {
  description = "Public IP address of EC2"
  value       = module.ec2.public_ip
}

output "public_dns" {
  description = "Public DNS of EC2"
  value       = module.ec2.public_dns
}