terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # REQUIRED for production: the state file contains the database
  # passwords (Terraform stores variable values in state even when marked
  # sensitive). Create the state bucket with the one-time bootstrap config
  # (see bootstrap/main.tf), paste its `backend_block` output here, then
  # run `terraform init -migrate-state`. Locking uses S3 native lockfiles
  # (Terraform >= 1.10; no DynamoDB table).
  #
  # backend "s3" {
  #   bucket       = "<from bootstrap output: state_bucket>"
  #   key          = "webapp/production/terraform.tfstate"
  #   region       = "us-west-2"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}