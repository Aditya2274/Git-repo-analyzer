# Fetch the latest Ubuntu 24.04 LTS AMI from AWS SSM Parameter Store
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ==============================================================================
# Security Groups: Least-Privilege Directional Rules
# ==============================================================================

# 1. Application & Monitoring Server Security Group (EC2 2)
resource "aws_security_group" "app_monitoring_sg" {
  name        = "git-repo-analyzer-app-sg"
  description = "Security group for Application & Monitoring Server (EC2 2)"

  ingress {
    description = "SSH access from operator IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "Public HTTP web traffic"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Public HTTPS web traffic"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound internet access for apt, npm, and API calls"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "git-repo-analyzer-app-sg"
    Project = "git-repo-analyzer"
    Role    = "app-monitoring"
  }
}

# 2. CI/CD & Analysis Server Security Group (EC2 3)
resource "aws_security_group" "cicd_analysis_sg" {
  name        = "git-repo-analyzer-cicd-sg"
  description = "Security group for CI/CD & Analysis Server (EC2 3)"

  ingress {
    description = "SSH access from operator IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description     = "Jenkins API access strictly from Application Server"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.app_monitoring_sg.id]
  }

  ingress {
    description     = "NRPE monitoring checks strictly from Application Server"
    from_port       = 5666
    to_port         = 5666
    protocol        = "tcp"
    security_groups = [aws_security_group.app_monitoring_sg.id]
  }

  egress {
    description = "Outbound internet access for apt, Docker Hub, GitHub, and Groq API"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "git-repo-analyzer-cicd-sg"
    Project = "git-repo-analyzer"
    Role    = "cicd-analysis"
  }
}

# 3. Dedicated Puppet Server Security Group (EC2 1)
resource "aws_security_group" "puppet_server_sg" {
  name        = "git-repo-analyzer-puppet-sg"
  description = "Security group for Dedicated Puppet Server & CA (EC2 1)"

  ingress {
    description = "SSH access from operator IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description     = "Puppet master communication strictly from Application and CI/CD agents"
    from_port       = 8140
    to_port         = 8140
    protocol        = "tcp"
    security_groups = [
      aws_security_group.app_monitoring_sg.id,
      aws_security_group.cicd_analysis_sg.id
    ]
  }

  ingress {
    description     = "NRPE monitoring checks strictly from Application Server"
    from_port       = 5666
    to_port         = 5666
    protocol        = "tcp"
    security_groups = [aws_security_group.app_monitoring_sg.id]
  }

  egress {
    description = "Outbound internet access for apt and Puppet Forge"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "git-repo-analyzer-puppet-sg"
    Project = "git-repo-analyzer"
    Role    = "puppet-server"
  }
}

# ==============================================================================
# EC2 Instances: Dedicated 3-Node Architecture
# ==============================================================================

# EC2 1: Dedicated Puppet Server
resource "aws_instance" "puppet_server" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.puppet_instance_type
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.puppet_server_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.puppet_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name    = "puppet-server"
    Role    = "puppet-server"
    Project = "git-repo-analyzer"
  }
}

# EC2 2: Application and Monitoring Server
resource "aws_instance" "app_monitoring" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.app_instance_type
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.app_monitoring_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.app_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name    = "app-server"
    Role    = "app-monitoring"
    Project = "git-repo-analyzer"
  }
}

# EC2 3: CI/CD and Analysis Server
resource "aws_instance" "cicd_analysis" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.cicd_instance_type
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.cicd_analysis_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.cicd_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name    = "cicd-server"
    Role    = "cicd-analysis"
    Project = "git-repo-analyzer"
  }
}
