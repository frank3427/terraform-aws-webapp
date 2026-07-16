locals {
  # MySQL host patterns for the application user, derived from the web
  # server subnets (e.g. "10.0.11.0/24" -> "10.0.11.%"). Assumes /24
  # subnets, matching the defaults in variables.tf.
  web_db_host_patterns = [for cidr in var.private_subnet_cidrs : replace(cidr, ".0/24", ".%")]

  # Web / bastion / monitoring user data is a small bootstrap that fetches
  # the real provisioning script from S3 (see provisioning.tf). It stays
  # under the 16 KB user-data limit and doesn't change when scripts do,
  # so script edits no longer force instance replacement.
  web_user_data = base64encode(templatefile("${path.module}/scripts/bootstrap.sh.tpl", {
    role   = "web"
    bucket = aws_s3_bucket.provisioning.bucket
    region = var.aws_region
    script = "web_server_setup.sh"
    env = {
      REGION = var.aws_region
      EFS_ID = aws_efs_file_system.main.id
    }
  }))

  bastion_user_data = base64encode(templatefile("${path.module}/scripts/bootstrap.sh.tpl", {
    role   = "bastion"
    bucket = aws_s3_bucket.provisioning.bucket
    region = var.aws_region
    script = "bastion_setup.sh"
    env    = {}
  }))

  monitoring_user_data = var.enable_monitoring ? base64encode(templatefile("${path.module}/scripts/bootstrap.sh.tpl", {
    role   = "monitoring"
    bucket = aws_s3_bucket.provisioning.bucket
    region = var.aws_region
    script = "monitoring_setup.sh"
    env = {
      REGION         = var.aws_region
      ENVIRONMENT    = var.environment
      SSM_PREFIX     = local.ssm_prefix
      SNS_TOPIC_ARN  = aws_sns_topic.alerts[0].arn
      PROM_VOLUME_ID = aws_ebs_volume.prometheus_data[0].id
    }
  })) : ""

  # Database setup scripts remain inline (they fit comfortably in user
  # data), but see the lifecycle ignore_changes on aws_instance.database:
  # editing these scripts must never replace a live database master.
  #
  # NOTE: no passwords are passed into user data. The database instances
  # fetch secrets from SSM Parameter Store at boot using their IAM role.
  db_master1_user_data = base64encode(templatefile("${path.module}/scripts/mariadb_master1_setup.sh", {
    region              = var.aws_region
    ssm_prefix          = local.ssm_prefix
    db_replication_user = var.db_replication_user
    master2_ip          = cidrhost(var.db_subnet_cidrs[1], 10)
    web_host_patterns   = local.web_db_host_patterns
    backup_bucket       = aws_s3_bucket.db_backups.bucket
  }))

  db_master2_user_data = base64encode(templatefile("${path.module}/scripts/mariadb_master2_setup.sh", {
    region              = var.aws_region
    ssm_prefix          = local.ssm_prefix
    db_replication_user = var.db_replication_user
    master1_ip          = cidrhost(var.db_subnet_cidrs[0], 10)
    web_host_patterns   = local.web_db_host_patterns
    backup_bucket       = aws_s3_bucket.db_backups.bucket
  }))
}
