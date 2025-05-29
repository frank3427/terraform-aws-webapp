resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.bastion_instance_type
  key_name                   = var.key_name
  vpc_security_group_ids     = [aws_security_group.bastion.id]
  subnet_id                  = aws_subnet.public[0].id
  associate_public_ip_address = true
  user_data                  = local.bastion_user_data

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

  depends_on = [aws_internet_gateway.main]
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