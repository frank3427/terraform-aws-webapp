data "aws_caller_identity" "current" {}

locals {
  ssm_prefix = "/${var.project_name}/${var.environment}"
}

# ---------------------------------------------------------------------------
# Secrets: stored in SSM Parameter Store as SecureString and fetched by the
# database instances at boot. Secrets are never embedded in EC2 user data
# (user data is readable by anyone with ec2:DescribeInstanceAttribute).
#
# NOTE: values still pass through Terraform state; use an encrypted remote
# backend (see the commented backend block in main.tf).
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "db_root_password" {
  name  = "${local.ssm_prefix}/db/root_password"
  type  = "SecureString"
  value = var.db_root_password

  tags = {
    Environment = var.environment
  }
}

resource "aws_ssm_parameter" "db_replication_password" {
  name  = "${local.ssm_prefix}/db/replication_password"
  type  = "SecureString"
  value = var.db_replication_password

  tags = {
    Environment = var.environment
  }
}

resource "aws_ssm_parameter" "db_app_password" {
  name  = "${local.ssm_prefix}/db/app_password"
  type  = "SecureString"
  value = var.db_app_password

  tags = {
    Environment = var.environment
  }
}

# ---------------------------------------------------------------------------
# EC2 instance roles. All instances get SSM Session Manager (auditable
# access without SSH keys). The database role can additionally read the DB
# secrets and write backups to S3. Metrics are handled by Prometheus
# exporters (see monitoring.tf), so no CloudWatch agent permissions are
# needed.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# --- Web servers ---

resource "aws_iam_role" "web" {
  name_prefix        = "${var.project_name}-${var.environment}-web-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "web_ssm" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "web" {
  name_prefix = "${var.project_name}-${var.environment}-web-"
  role        = aws_iam_role.web.name
}

# --- Database servers ---

resource "aws_iam_role" "database" {
  name_prefix        = "${var.project_name}-${var.environment}-db-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "database_ssm" {
  role       = aws_iam_role.database.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "database_secrets" {
  statement {
    sid     = "ReadDatabaseSecrets"
    actions = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.db_root_password.arn,
      aws_ssm_parameter.db_replication_password.arn,
      aws_ssm_parameter.db_app_password.arn,
    ]
  }

  statement {
    sid       = "WriteBackups"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.db_backups.arn}/db-backups/*"]
  }

  statement {
    sid       = "ListBackupBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.db_backups.arn]
  }
}

resource "aws_iam_role_policy" "database_secrets" {
  name_prefix = "secrets-and-backups-"
  role        = aws_iam_role.database.id
  policy      = data.aws_iam_policy_document.database_secrets.json
}

resource "aws_iam_instance_profile" "database" {
  name_prefix = "${var.project_name}-${var.environment}-db-"
  role        = aws_iam_role.database.name
}

# --- Bastion host ---

resource "aws_iam_role" "bastion" {
  name_prefix        = "${var.project_name}-${var.environment}-bastion-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read-only instance discovery so bastion management tools can find the
# fleet by tags at runtime instead of relying on hardcoded IPs.
# ec2:DescribeInstances does not support resource-level scoping.
data "aws_iam_policy_document" "bastion_discovery" {
  statement {
    sid       = "DiscoverFleet"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

resource "aws_iam_role_policy" "bastion_discovery" {
  name_prefix = "fleet-discovery-"
  role        = aws_iam_role.bastion.id
  policy      = data.aws_iam_policy_document.bastion_discovery.json
}

resource "aws_iam_instance_profile" "bastion" {
  name_prefix = "${var.project_name}-${var.environment}-bastion-"
  role        = aws_iam_role.bastion.name
}
