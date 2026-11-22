terraform {
  backend "s3" {
    bucket       = "git-repo-analyzer-terraform-state-2026"
    key          = "git-repo-analyzer/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }

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

module "ec2" {
  source = "./modules/ec2"

  allowed_ssh_cidr     = var.allowed_ssh_cidr
  key_name             = var.key_name
  puppet_instance_type = var.puppet_instance_type
  puppet_volume_size   = var.puppet_volume_size
  app_instance_type    = var.app_instance_type
  app_volume_size      = var.app_volume_size
  cicd_instance_type   = var.cicd_instance_type
  cicd_volume_size     = var.cicd_volume_size
}
