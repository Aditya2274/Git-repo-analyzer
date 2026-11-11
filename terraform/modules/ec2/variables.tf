variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "Public IP address allowed to SSH into EC2"
  type        = string
}