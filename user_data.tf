locals {
  # MySQL host patterns for the application user, derived from the web
  # server subnets (e.g. "10.0.11.0/24" -> "10.0.11.%"). Assumes /24
  # subnets, matching the defaults in variables.tf.
  web_db_host_patterns = [for cidr in var.private_subnet_cidrs : replace(cidr, ".0/24", ".%")]

  web_user_data = base64encode(templatefile("${path.module}/scripts/web_server_setup.sh", {
    efs_id = aws_efs_file_system.main.id
    region = var.aws_region
  }))

  # NOTE: no passwords are passed into user data. The database instances
  # fetch secrets from SSM Parameter Store at boot using their IAM role.
  db_master1_user_data = base64encode(templatefile("${path.module}/scripts/mariadb_master1_setup.sh", {
    region              = var.aws_region
    ssm_prefix          = local.ssm_prefix
    db_replication_user = var.db_replication_user
    master2_ip          = "10.0.22.10"
    web_host_patterns   = local.web_db_host_patterns
    backup_bucket       = aws_s3_bucket.db_backups.bucket
  }))

  db_master2_user_data = base64encode(templatefile("${path.module}/scripts/mariadb_master2_setup.sh", {
    region              = var.aws_region
    ssm_prefix          = local.ssm_prefix
    db_replication_user = var.db_replication_user
    master1_ip          = "10.0.21.10"
    web_host_patterns   = local.web_db_host_patterns
    backup_bucket       = aws_s3_bucket.db_backups.bucket
  }))

  bastion_user_data = base64encode(file("${path.module}/scripts/bastion_setup.sh"))
}
