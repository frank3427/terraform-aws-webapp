# ---------------------------------------------------------------------------
# Web tier: launch template + Auto Scaling Group.
#
# Replacements roll through the fleet (instance_refresh) instead of
# happening all at once, the ALB health check gates each step, and a
# failed instance is replaced automatically. Capacity is fixed at
# web_server_count; add scaling policies later if load warrants.
# ---------------------------------------------------------------------------

resource "aws_launch_template" "web" {
  name_prefix   = "${var.project_name}-${var.environment}-web-"
  image_id      = var.web_ami_id != "" ? var.web_ami_id : data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.web.id]

  # Stable S3 bootstrap (see provisioning.tf): script edits don't create a
  # new template version, so they never trigger an instance refresh
  user_data = local.web_user_data

  iam_instance_profile {
    name = aws_iam_instance_profile.web.name
  }

  # Require IMDSv2: blocks SSRF-based credential theft from the metadata
  # service, a primary attack path on web-facing instances
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_type           = "gp3"
      volume_size           = 20
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "volume"

    tags = {
      Name        = "${var.project_name}-${var.environment}-web"
      Environment = var.environment
    }
  }

  update_default_version = true

  lifecycle {
    # A new Ubuntu AMI release must not silently roll the fleet on the
    # next apply. To adopt a new AMI deliberately: set web_ami_id (baked
    # AMI) or temporarily remove this ignore and apply.
    ignore_changes = [image_id]
  }
}

resource "aws_autoscaling_group" "web" {
  name                = "${var.project_name}-${var.environment}-web"
  desired_capacity    = var.web_server_count
  min_size            = var.web_server_count
  max_size            = var.web_server_count
  vpc_zone_identifier = aws_subnet.private[*].id

  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 600 # first boot installs packages; give it time
  wait_for_capacity_timeout = "20m"

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  # Launch-template changes roll through the fleet gradually, gated on ALB
  # health, instead of replacing every instance at once
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 66
    }
  }

  # Prometheus EC2 service discovery and the bastion fleet tools find web
  # servers via these tags
  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-web"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  tag {
    key                 = "Type"
    value               = "WebServer"
    propagate_at_launch = true
  }

  depends_on = [
    aws_efs_mount_target.main,
    aws_nat_gateway.main,
    aws_s3_object.provisioning
  ]
}

resource "aws_instance" "database" {
  count = 2

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.db_instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.database.id]
  subnet_id              = aws_subnet.database[count.index].id
  # Pinned host address (.10) derived from each DB subnet's CIDR so custom
  # network ranges don't break replication wiring
  private_ip           = cidrhost(var.db_subnet_cidrs[count.index], 10)
  user_data            = count.index == 0 ? local.db_master1_user_data : local.db_master2_user_data
  iam_instance_profile = aws_iam_instance_profile.database.name

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

  lifecycle {
    # Never replace a live database master because a setup script or AMI
    # changed. New user_data/AMI applies only to deliberately replaced
    # instances (`terraform apply -replace`).
    ignore_changes = [ami, user_data]
  }

  # Secrets must exist in SSM before the instance boots and fetches them
  depends_on = [
    aws_ssm_parameter.db_root_password,
    aws_ssm_parameter.db_replication_password,
    aws_ssm_parameter.db_app_password,
    aws_nat_gateway.main
  ]
}
