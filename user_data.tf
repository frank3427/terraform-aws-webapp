locals {
  web_user_data = base64encode(templatefile("${path.module}/scripts/web_server_setup.sh", {
    efs_id = aws_efs_file_system.main.id
    region = var.aws_region
  }))

  db_master1_user_data = base64encode(templatefile("${path.module}/scripts/mariadb_master1_setup.sh", {
    db_root_password        = var.db_root_password
    db_replication_user     = var.db_replication_user
    db_replication_password = var.db_replication_password
    master2_ip              = "10.0.22.10"
  }))

  db_master2_user_data = base64encode(templatefile("${path.module}/scripts/mariadb_master2_setup.sh", {
    db_root_password        = var.db_root_password
    db_replication_user     = var.db_replication_user
    db_replication_password = var.db_replication_password
    master1_ip              = "10.0.21.10"
  }))

  bastion_user_data = base64encode(file("${path.module}/scripts/bastion_setup.sh"))
}