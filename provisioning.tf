# ---------------------------------------------------------------------------
# Provisioning script delivery
#
# Setup scripts are uploaded to a private S3 bucket and fetched at boot by a
# tiny user-data bootstrap (scripts/bootstrap.sh.tpl). Rationale:
#   - EC2 user data is capped at 16 KB; web_server_setup.sh and
#     bastion_setup.sh exceed it
#   - user data stays stable, so editing a provisioning script no longer
#     forces Terraform to replace the instance
#
# NOTE: running instances do not re-run provisioning when an S3 object
# changes; updates apply to newly launched instances (or run the script
# manually via SSM).
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "provisioning" {
  bucket = "${var.project_name}-${var.environment}-provisioning-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "${var.project_name}-${var.environment}-provisioning"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "provisioning" {
  bucket = aws_s3_bucket.provisioning.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "provisioning" {
  bucket = aws_s3_bucket.provisioning.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "provisioning" {
  bucket = aws_s3_bucket.provisioning.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

locals {
  # Everything under scripts/ is uploaded; the bootstrap copies the whole
  # prefix to /opt/provisioning/scripts/ on the instance.
  provisioning_scripts = {
    "scripts/web_server_setup.sh"            = "${path.module}/scripts/web_server_setup.sh"
    "scripts/bastion_setup.sh"               = "${path.module}/scripts/bastion_setup.sh"
    "scripts/monitoring_setup.sh"            = "${path.module}/scripts/monitoring_setup.sh"
    "scripts/lib/fetch-release.sh"           = "${path.module}/scripts/lib/fetch-release.sh"
    "scripts/vhost-manager/vhost"            = "${path.module}/scripts/vhost-manager/vhost"
    "scripts/vhost-manager/create-vhost.sh"  = "${path.module}/scripts/vhost-manager/create-vhost.sh"
    "scripts/vhost-manager/sync-vhosts.sh"   = "${path.module}/scripts/vhost-manager/sync-vhosts.sh"
    "scripts/vhost-manager/list-vhosts.sh"   = "${path.module}/scripts/vhost-manager/list-vhosts.sh"
    "scripts/vhost-manager/remove-vhost.sh"  = "${path.module}/scripts/vhost-manager/remove-vhost.sh"
  }
}

resource "aws_s3_object" "provisioning" {
  for_each = local.provisioning_scripts

  bucket      = aws_s3_bucket.provisioning.id
  key         = each.key
  source      = each.value
  source_hash = filemd5(each.value)
}

# Read-only access to the provisioning scripts for instance roles
data "aws_iam_policy_document" "provisioning_read" {
  statement {
    sid       = "GetProvisioningScripts"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.provisioning.arn}/scripts/*"]
  }

  statement {
    sid       = "ListProvisioningBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.provisioning.arn]
  }
}

resource "aws_iam_role_policy" "web_provisioning_read" {
  name_prefix = "provisioning-read-"
  role        = aws_iam_role.web.id
  policy      = data.aws_iam_policy_document.provisioning_read.json
}

resource "aws_iam_role_policy" "bastion_provisioning_read" {
  name_prefix = "provisioning-read-"
  role        = aws_iam_role.bastion.id
  policy      = data.aws_iam_policy_document.provisioning_read.json
}

resource "aws_iam_role_policy" "monitoring_provisioning_read" {
  count = var.enable_monitoring ? 1 : 0

  name_prefix = "provisioning-read-"
  role        = aws_iam_role.monitoring[0].id
  policy      = data.aws_iam_policy_document.provisioning_read.json
}
