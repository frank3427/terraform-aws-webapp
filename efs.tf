resource "aws_efs_file_system" "main" {
  creation_token = "${var.project_name}-${var.environment}-efs"
  encrypted      = true

  performance_mode = "generalPurpose"
  # "elastic" avoids burst-credit throttling: with "bursting", baseline
  # throughput scales with stored bytes, and a small filesystem (vhost
  # configs + site content) gets almost none once credits run out.
  throughput_mode = var.efs_throughput_mode

  # Content not read for 30 days moves to Infrequent Access (~8% of the
  # standard storage price) and returns to standard on first access.
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-efs"
    Environment = var.environment
  }
}

# Automatic daily backups of all website content via AWS Backup.
# Without this, a bad `vhost remove --purge`, ransomware on a web server,
# or an accidental rm on the shared mount is unrecoverable.
resource "aws_efs_backup_policy" "main" {
  file_system_id = aws_efs_file_system.main.id

  backup_policy {
    status = "ENABLED"
  }
}

resource "aws_efs_mount_target" "main" {
  count = length(aws_subnet.private)

  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}
