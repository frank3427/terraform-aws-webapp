# ---------------------------------------------------------------------------
# Security groups.
#
# All rules are defined as standalone aws_security_group_rule resources
# (not inline) because several groups reference each other, which would
# otherwise create dependency cycles.
#
# Egress is restricted everywhere: instances may reach package mirrors and
# AWS APIs (80/443), VPC DNS, and NTP, plus only the specific internal
# services they need. This limits data exfiltration paths if a host is
# compromised — important for transactional workloads.
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name_prefix = "${var.project_name}-${var.environment}-alb-"
  description = "Load balancer: public HTTP/HTTPS in, web servers only out"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-alb-sg"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "web" {
  name_prefix = "${var.project_name}-${var.environment}-web-"
  description = "Web servers: HTTP from ALB, SSH from bastion"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-web-sg"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "database" {
  name_prefix = "${var.project_name}-${var.environment}-db-"
  description = "Database servers: MySQL from web/bastion/peers, SSH from bastion"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-db-sg"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "efs" {
  name_prefix = "${var.project_name}-${var.environment}-efs-"
  description = "EFS mount targets: NFS from web servers only, no egress"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-efs-sg"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "bastion" {
  name_prefix = "${var.project_name}-${var.environment}-bastion-"
  description = "Bastion: SSH from allowed CIDRs, admin access to VPC"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-bastion-sg"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------- ALB rules --------------------------------

resource "aws_security_group_rule" "alb_in_http" {
  description       = "HTTP from internet"
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_in_https" {
  description       = "HTTPS from internet"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_out_web" {
  description              = "Forward traffic and health checks to web servers"
  type                     = "egress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.web.id
  security_group_id        = aws_security_group.alb.id
}

# ------------------------------- Web rules --------------------------------

resource "aws_security_group_rule" "web_in_http_from_alb" {
  description              = "HTTP from ALB"
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.web.id
}

resource "aws_security_group_rule" "web_in_ssh_from_bastion" {
  description              = "SSH from bastion"
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = aws_security_group.web.id
}

resource "aws_security_group_rule" "web_out_http" {
  description       = "HTTP out (apt mirrors)"
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.web.id
}

resource "aws_security_group_rule" "web_out_https" {
  description       = "HTTPS out (AWS APIs, snap, apt)"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.web.id
}

resource "aws_security_group_rule" "web_out_dns_udp" {
  description       = "DNS to VPC resolver"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.web.id
}

resource "aws_security_group_rule" "web_out_dns_tcp" {
  description       = "DNS to VPC resolver (TCP fallback)"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.web.id
}

resource "aws_security_group_rule" "web_out_ntp" {
  description       = "NTP time sync"
  type              = "egress"
  from_port         = 123
  to_port           = 123
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.web.id
}

resource "aws_security_group_rule" "web_out_nfs_to_efs" {
  description              = "NFS to EFS mount targets"
  type                     = "egress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.efs.id
  security_group_id        = aws_security_group.web.id
}

resource "aws_security_group_rule" "web_out_mysql_to_db" {
  description              = "MySQL to database servers"
  type                     = "egress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.database.id
  security_group_id        = aws_security_group.web.id
}

# ----------------------------- Database rules -----------------------------

resource "aws_security_group_rule" "db_in_mysql_from_web" {
  description              = "MySQL from web servers"
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.web.id
  security_group_id        = aws_security_group.database.id
}

resource "aws_security_group_rule" "db_in_mysql_replication" {
  description       = "MySQL replication between masters"
  type              = "ingress"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.database.id
}

resource "aws_security_group_rule" "db_in_mysql_from_bastion" {
  description              = "MySQL client access from bastion (admin)"
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = aws_security_group.database.id
}

resource "aws_security_group_rule" "db_in_ssh_from_bastion" {
  description              = "SSH from bastion"
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = aws_security_group.database.id
}

resource "aws_security_group_rule" "db_out_http" {
  description       = "HTTP out (apt mirrors)"
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.database.id
}

resource "aws_security_group_rule" "db_out_https" {
  description       = "HTTPS out (AWS APIs incl. SSM secrets and S3 backups)"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.database.id
}

resource "aws_security_group_rule" "db_out_dns_udp" {
  description       = "DNS to VPC resolver"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.database.id
}

resource "aws_security_group_rule" "db_out_dns_tcp" {
  description       = "DNS to VPC resolver (TCP fallback)"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.database.id
}

resource "aws_security_group_rule" "db_out_ntp" {
  description       = "NTP time sync"
  type              = "egress"
  from_port         = 123
  to_port           = 123
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.database.id
}

resource "aws_security_group_rule" "db_out_mysql_replication" {
  description       = "MySQL replication to peer master"
  type              = "egress"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.database.id
}

# ------------------------------- EFS rules --------------------------------
# Mount targets never initiate connections, so the EFS group has no egress.

resource "aws_security_group_rule" "efs_in_nfs_from_web" {
  description              = "NFS from web servers"
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.web.id
  security_group_id        = aws_security_group.efs.id
}

# ----------------------------- Bastion rules ------------------------------

resource "aws_security_group_rule" "bastion_in_ssh" {
  description       = "SSH from allowed admin CIDRs"
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.bastion_allowed_cidrs
  security_group_id = aws_security_group.bastion.id
}

resource "aws_security_group_rule" "bastion_out_ssh_vpc" {
  description       = "SSH to instances in the VPC"
  type              = "egress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.bastion.id
}

resource "aws_security_group_rule" "bastion_out_mysql_to_db" {
  description              = "MySQL client to database servers"
  type                     = "egress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.database.id
  security_group_id        = aws_security_group.bastion.id
}

resource "aws_security_group_rule" "bastion_out_http" {
  description       = "HTTP out (apt mirrors)"
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.bastion.id
}

resource "aws_security_group_rule" "bastion_out_https" {
  description       = "HTTPS out (AWS APIs, snap, apt)"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.bastion.id
}

resource "aws_security_group_rule" "bastion_out_dns_udp" {
  description       = "DNS to VPC resolver"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.bastion.id
}

resource "aws_security_group_rule" "bastion_out_dns_tcp" {
  description       = "DNS to VPC resolver (TCP fallback)"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.bastion.id
}

resource "aws_security_group_rule" "bastion_out_ntp" {
  description       = "NTP time sync"
  type              = "egress"
  from_port         = 123
  to_port           = 123
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.bastion.id
}
