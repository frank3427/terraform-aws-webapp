# ---------------------------------------------------------------------------
# One-time bootstrap: creates the S3 bucket that stores Terraform state for
# the main configuration. Run this FIRST, once, with local state:
#
#   cd bootstrap
#   terraform init && terraform apply
#
# Then copy the printed backend block into ../main.tf (replacing the
# commented example), and in the main configuration run:
#
#   terraform init -migrate-state
#
# The bootstrap's own tiny state file stays local (it contains nothing
# sensitive - just this bucket). State locking uses S3 native lockfiles
# (use_lockfile), which requires Terraform >= 1.10; no DynamoDB table needed.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region (must match the main configuration)"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project name (must match the main configuration)"
  type        = string
  default     = "webapp"
}

variable "environment" {
  description = "Environment name (must match the main configuration)"
  type        = string
  default     = "production"
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.project_name}-${var.environment}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  # The state file contains the database passwords; never let this bucket
  # be destroyed casually.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = local.bucket_name
    Environment = var.environment
    Purpose     = "terraform-state"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket" {
  description = "Name of the created state bucket"
  value       = aws_s3_bucket.tfstate.bucket
}

output "backend_block" {
  description = "Paste this into ../main.tf, then run: terraform init -migrate-state"
  value       = <<-EOT
    backend "s3" {
      bucket       = "${aws_s3_bucket.tfstate.bucket}"
      key          = "${var.project_name}/${var.environment}/terraform.tfstate"
      region       = "${var.aws_region}"
      encrypt      = true
      use_lockfile = true
    }
  EOT
}
