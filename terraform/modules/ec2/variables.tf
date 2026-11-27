variable "allowed_ssh_cidr" {
  description = "Public IP CIDR block allowed to SSH into EC2 instances"
  type        = string
}

variable "key_name" {
  description = "EC2 Key Pair name for SSH access"
  type        = string
  default     = "git-repo-analyzer"
}

variable "puppet_instance_type" {
  description = "Instance type for Puppet Server (EC2 1)"
  type        = string
  default     = "t3.small"
}

variable "puppet_volume_size" {
  description = "Root gp3 volume size in GB for Puppet Server (EC2 1)"
  type        = number
  default     = 15
}

variable "app_instance_type" {
  description = "Instance type for Application and Monitoring Server (EC2 2)"
  type        = string
  default     = "t3.micro"
}

variable "app_volume_size" {
  description = "Root gp3 volume size in GB for Application Server (EC2 2)"
  type        = number
  default     = 15
}

variable "cicd_instance_type" {
  description = "Instance type for CI/CD and Analysis Server (EC2 3)"
  type        = string
  default     = "t3.small"
}

variable "cicd_volume_size" {
  description = "Root gp3 volume size in GB for CI/CD Server (EC2 3)"
  type        = number
  default     = 20
}
