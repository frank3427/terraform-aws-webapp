resource "aws_instance" "web" {
  count = 3

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.web.id]
  subnet_id              = aws_subnet.private[count.index].id
  user_data              = local.web_user_data
  iam_instance_profile   = aws_iam_instance_profile.web.name

  # Require IMDSv2: blocks SSRF-based credential theft from the metadata
  # service, a primary attack path on web-facing instances
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-web-${count.index + 1}"
    Environment = var.environment
    Type        = "WebServer"
  }

  depends_on = [
    aws_efs_mount_target.main,
    aws_nat_gateway.main
  ]
}

resource "aws_instance" "database" {
  count = 2

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.db_instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.database.id]
  subnet_id              = aws_subnet.database[count.index].id
  private_ip             = "10.0.${21 + count.index}.10"
  user_data              = count.index == 0 ? local.db_master1_user_data : local.db_master2_user_data
  iam_instance_profile   = aws_iam_instance_profile.database.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
    encrypted   = true
  }

  ebs_block_device {
    device_name = "/dev/sdf"
    volume_type = "gp3"
    volume_size = 100
    encrypted   = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-db-master-${count.index + 1}"
    Environment = var.environment
    Type        = "DatabaseServer"
    Role        = "Master"
  }

  # Secrets must exist in SSM before the instance boots and fetches them
  depends_on = [
    aws_ssm_parameter.db_root_password,
    aws_ssm_parameter.db_replication_password,
    aws_ssm_parameter.db_app_password,
    aws_nat_gateway.main
  ]
}
