variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "webapp"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "db_subnet_cidrs" {
  description = "CIDR blocks for database subnets"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "instance_type" {
  description = "EC2 instance type for web servers"
  type        = string
  default     = "t3.medium"
}

variable "db_instance_type" {
  description = "EC2 instance type for database servers"
  type        = string
  default     = "t3.large"
}

variable "key_name" {
  description = "AWS Key Pair name"
  type        = string
}

variable "db_root_password" {
  description = "Root password for MariaDB"
  type        = string
  sensitive   = true
}

variable "db_replication_user" {
  description = "Replication user for MariaDB"
  type        = string
  default     = "replicator"
}

variable "db_replication_password" {
  description = "Replication password for MariaDB"
  type        = string
  sensitive   = true
}

variable "bastion_instance_type" {
  description = "EC2 instance type for bastion host"
  type        = string
  default     = "t3.micro"
}

variable "bastion_allowed_cidrs" {
  description = "CIDR blocks allowed to SSH to the bastion host. Must be set explicitly (e.g. your office/VPN ranges); 0.0.0.0/0 is rejected."
  type        = list(string)

  validation {
    condition     = length(var.bastion_allowed_cidrs) > 0 && alltrue([for c in var.bastion_allowed_cidrs : c != "0.0.0.0/0" && c != "::/0"])
    error_message = "bastion_allowed_cidrs must list specific CIDR ranges; exposing SSH to 0.0.0.0/0 is not allowed."
  }
}

variable "db_app_password" {
  description = "Password for the application database user (webapp_user). Must differ from the root password."
  type        = string
  sensitive   = true
}

variable "acm_certificate_arn" {
  description = "ARN of an ACM certificate for HTTPS termination at the load balancer. When set, the ALB serves HTTPS on 443 and redirects HTTP to HTTPS. Leave empty to serve HTTP only."
  type        = string
  default     = ""
}

variable "enable_waf" {
  description = "Attach an AWS WAFv2 web ACL (AWS managed common, known-bad-inputs, SQLi and IP-reputation rules) to the load balancer. Recommended for transactional workloads. Adds ~USD 10-15/month."
  type        = bool
  default     = true
}

variable "alb_deletion_protection" {
  description = "Enable deletion protection on the load balancer. Must be disabled before terraform destroy."
  type        = bool
  default     = true
}