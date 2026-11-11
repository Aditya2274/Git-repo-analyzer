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

  instance_type    = var.instance_type
  allowed_ssh_cidr = var.allowed_ssh_cidr
}