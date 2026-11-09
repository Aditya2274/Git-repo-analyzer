terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Fetch the latest Ubuntu 24.04 LTS AMI from AWS
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# Security group for our EC2 instance
resource "aws_security_group" "analyzer_sg" {
  name        = "git-repo-analyzer-sg"
  description = "Allow SSH access to Git Repository Analyzer EC2"

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "git-repo-analyzer-sg"
    Project = "git-repo-analyzer"
  }
}

# EC2 instance
resource "aws_instance" "analyzer" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  key_name               = "git-repo-analyzer"
  vpc_security_group_ids = [aws_security_group.analyzer_sg.id]

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  tags = {
    Name    = "git-repo-analyzer"
    Project = "git-repo-analyzer"
  }
}