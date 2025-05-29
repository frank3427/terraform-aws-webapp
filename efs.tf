resource "aws_efs_file_system" "main" {
  creation_token = "${var.project_name}-${var.environment}-efs"
  encrypted      = true

  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = {
    Name        = "${var.project_name}-${var.environment}-efs"
    Environment = var.environment
  }
}

resource "aws_efs_mount_target" "main" {
  count = length(aws_subnet.private)

  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "web" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    gid = 33
    uid = 33
  }

  root_directory {
    path = "/var/www"
    creation_info {
      owner_gid   = 33
      owner_uid   = 33
      permissions = 755
    }
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-web-access-point"
    Environment = var.environment
  }
}