# ---------------------------------------------------------------------------
# Off-instance database backups. The MariaDB backup cron ships nightly dumps
# here so a compromised or destroyed instance cannot take the backups with it.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "db_backups" {
  bucket_prefix = "${var.project_name}-${var.environment}-db-backups-"

  tags = {
    Name        = "${var.project_name}-${var.environment}-db-backups"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {
      prefix = "db-backups/"
    }

    expiration {
      days = 35
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}
