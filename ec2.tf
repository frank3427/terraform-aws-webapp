resource "aws_instance" "web" {
  count = 3

  ami                     = data.aws_ami.ubuntu.id
  instance_type           = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.web.id]
  subnet_id              = aws_subnet.private[count.index].id
  user_data              = local.web_user_data

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

  ami                     = data.aws_ami.ubuntu.id
  instance_type           = var.db_instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.database.id]
  subnet_id              = aws_subnet.database[count.index].id
  private_ip             = "10.0.${21 + count.index}.10"
  user_data              = count.index == 0 ? local.db_master1_user_data : local.db_master2_user_data

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
}