resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.bastion_instance_type
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  subnet_id                   = aws_subnet.public[0].id
  associate_public_ip_address = true
  user_data                   = local.bastion_user_data
  iam_instance_profile        = aws_iam_instance_profile.bastion.name

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
    Name        = "${var.project_name}-${var.environment}-bastion"
    Environment = var.environment
    Type        = "BastionHost"
  }

  lifecycle {
    # A new Ubuntu AMI release must not silently replace the bastion on
    # the next apply; replace deliberately via `terraform apply -replace`
    ignore_changes = [ami]
  }

  depends_on = [
    aws_internet_gateway.main,
    aws_s3_object.provisioning
  ]
}

resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"

  tags = {
    Name        = "${var.project_name}-${var.environment}-bastion-eip"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.main]
}