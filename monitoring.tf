# ---------------------------------------------------------------------------
# Prometheus + Alertmanager + Grafana monitoring (toggle: var.enable_monitoring)
#
# A dedicated instance in a private subnet scrapes:
#   - node_exporter (:9100) on every host - CPU, RAM, disk, network
#   - mysqld_exporter (:9104) on the MariaDB masters - incl. replication
#   - apache_exporter (:9117) on the web servers - via mod_status
#
# Targets are discovered from EC2 tags (same scheme as the bastion tools),
# so monitoring follows fleet scaling automatically. Alerts flow through
# Alertmanager (:9093) to SNS (see alerting.tf). Grafana (:3000),
# Prometheus (:9090) and Alertmanager UIs are reachable only from the
# bastion - access via SSH tunnel or SSM port forwarding; nothing is
# exposed publicly.
#
# Prometheus data lives on a dedicated EBS volume so metrics history
# survives instance replacement.
# ---------------------------------------------------------------------------

resource "aws_security_group" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  name_prefix = "${var.project_name}-${var.environment}-monitoring-"
  description = "Monitoring server: Grafana/Prometheus UI from bastion, scrapes exporters"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-monitoring-sg"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Security group rules, generated from maps: adding a UI port or an exporter
# is a one-line change instead of four hand-written rule resources.
# ---------------------------------------------------------------------------

locals {
  # UI ports on the monitoring host, reachable only from the bastion
  monitoring_ui_ports = var.enable_monitoring ? {
    grafana      = 3000
    prometheus   = 9090
    alertmanager = 9093
  } : {}

  # Scrape paths: monitoring host -> exporter port on the target SG
  monitoring_scrapes = var.enable_monitoring ? {
    node_web     = { port = 9100, target_sg = aws_security_group.web.id, description = "node_exporter on web servers" }
    node_db      = { port = 9100, target_sg = aws_security_group.database.id, description = "node_exporter on database servers" }
    node_bastion = { port = 9100, target_sg = aws_security_group.bastion.id, description = "node_exporter on bastion" }
    apache_web   = { port = 9117, target_sg = aws_security_group.web.id, description = "apache_exporter on web servers" }
    mysqld_db    = { port = 9104, target_sg = aws_security_group.database.id, description = "mysqld_exporter on database servers" }
  } : {}
}

# --- UI access from bastion ---

resource "aws_security_group_rule" "monitoring_ui_in" {
  for_each = local.monitoring_ui_ports

  description              = "${each.key} UI from bastion (tunnel access)"
  type                     = "ingress"
  from_port                = each.value
  to_port                  = each.value
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = aws_security_group.monitoring[0].id
}

resource "aws_security_group_rule" "bastion_ui_out" {
  for_each = local.monitoring_ui_ports

  description              = "${each.key} UI on monitoring server"
  type                     = "egress"
  from_port                = each.value
  to_port                  = each.value
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.monitoring[0].id
  security_group_id        = aws_security_group.bastion.id
}

# --- Scrape paths: monitoring -> exporters ---

resource "aws_security_group_rule" "monitoring_scrape_out" {
  for_each = local.monitoring_scrapes

  description              = "Scrape ${each.value.description}"
  type                     = "egress"
  from_port                = each.value.port
  to_port                  = each.value.port
  protocol                 = "tcp"
  source_security_group_id = each.value.target_sg
  security_group_id        = aws_security_group.monitoring[0].id
}

resource "aws_security_group_rule" "scrape_target_in" {
  for_each = local.monitoring_scrapes

  description              = "${each.value.description} scraped from monitoring"
  type                     = "ingress"
  from_port                = each.value.port
  to_port                  = each.value.port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.monitoring[0].id
  security_group_id        = each.value.target_sg
}

# Prometheus discovers itself via EC2 service discovery, so the monitoring
# host also scrapes its own node_exporter over the VPC
resource "aws_security_group_rule" "monitoring_self_node" {
  count = var.enable_monitoring ? 1 : 0

  description       = "Scrape own node_exporter via EC2 service discovery"
  type              = "ingress"
  from_port         = 9100
  to_port           = 9100
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.monitoring[0].id
}

resource "aws_security_group_rule" "monitoring_self_node_out" {
  count = var.enable_monitoring ? 1 : 0

  description       = "Scrape own node_exporter via EC2 service discovery"
  type              = "egress"
  from_port         = 9100
  to_port           = 9100
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.monitoring[0].id
}

# --- State moves from the pre-for_each rule layout (v1) ---

moved {
  from = aws_security_group_rule.monitoring_in_grafana[0]
  to   = aws_security_group_rule.monitoring_ui_in["grafana"]
}

moved {
  from = aws_security_group_rule.monitoring_in_prometheus[0]
  to   = aws_security_group_rule.monitoring_ui_in["prometheus"]
}

moved {
  from = aws_security_group_rule.bastion_out_grafana[0]
  to   = aws_security_group_rule.bastion_ui_out["grafana"]
}

moved {
  from = aws_security_group_rule.bastion_out_prometheus[0]
  to   = aws_security_group_rule.bastion_ui_out["prometheus"]
}

moved {
  from = aws_security_group_rule.monitoring_out_node_web[0]
  to   = aws_security_group_rule.monitoring_scrape_out["node_web"]
}

moved {
  from = aws_security_group_rule.monitoring_out_node_db[0]
  to   = aws_security_group_rule.monitoring_scrape_out["node_db"]
}

moved {
  from = aws_security_group_rule.monitoring_out_node_bastion[0]
  to   = aws_security_group_rule.monitoring_scrape_out["node_bastion"]
}

moved {
  from = aws_security_group_rule.monitoring_out_apache_exporter[0]
  to   = aws_security_group_rule.monitoring_scrape_out["apache_web"]
}

moved {
  from = aws_security_group_rule.monitoring_out_mysqld_exporter[0]
  to   = aws_security_group_rule.monitoring_scrape_out["mysqld_db"]
}

moved {
  from = aws_security_group_rule.web_in_node_exporter[0]
  to   = aws_security_group_rule.scrape_target_in["node_web"]
}

moved {
  from = aws_security_group_rule.web_in_apache_exporter[0]
  to   = aws_security_group_rule.scrape_target_in["apache_web"]
}

moved {
  from = aws_security_group_rule.db_in_node_exporter[0]
  to   = aws_security_group_rule.scrape_target_in["node_db"]
}

moved {
  from = aws_security_group_rule.db_in_mysqld_exporter[0]
  to   = aws_security_group_rule.scrape_target_in["mysqld_db"]
}

moved {
  from = aws_security_group_rule.bastion_in_node_exporter[0]
  to   = aws_security_group_rule.scrape_target_in["node_bastion"]
}

# --- Baseline egress for the monitoring host (apt, GitHub releases, AWS) ---

resource "aws_security_group_rule" "monitoring_out_http" {
  count = var.enable_monitoring ? 1 : 0

  description       = "HTTP out (apt mirrors)"
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.monitoring[0].id
}

resource "aws_security_group_rule" "monitoring_out_https" {
  count = var.enable_monitoring ? 1 : 0

  description       = "HTTPS out (GitHub releases, Grafana repo, AWS APIs incl. S3/SNS/SSM)"
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.monitoring[0].id
}

resource "aws_security_group_rule" "monitoring_out_dns_udp" {
  count = var.enable_monitoring ? 1 : 0

  description       = "DNS to VPC resolver"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.monitoring[0].id
}

resource "aws_security_group_rule" "monitoring_out_dns_tcp" {
  count = var.enable_monitoring ? 1 : 0

  description       = "DNS to VPC resolver (TCP fallback)"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.monitoring[0].id
}

resource "aws_security_group_rule" "monitoring_out_ntp" {
  count = var.enable_monitoring ? 1 : 0

  description       = "NTP time sync"
  type              = "egress"
  from_port         = 123
  to_port           = 123
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.monitoring[0].id
}

resource "aws_security_group_rule" "monitoring_in_ssh_from_bastion" {
  count = var.enable_monitoring ? 1 : 0

  description              = "SSH from bastion"
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = aws_security_group.monitoring[0].id
}

# --- IAM: EC2 service discovery for Prometheus ---

resource "aws_iam_role" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  name_prefix        = "${var.project_name}-${var.environment}-monitoring-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "monitoring_ssm" {
  count = var.enable_monitoring ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "monitoring_discovery" {
  count = var.enable_monitoring ? 1 : 0

  name_prefix = "prometheus-ec2-sd-"
  role        = aws_iam_role.monitoring[0].id
  policy      = data.aws_iam_policy_document.bastion_discovery.json
}

resource "aws_iam_instance_profile" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  name_prefix = "${var.project_name}-${var.environment}-monitoring-"
  role        = aws_iam_role.monitoring[0].name
}

# --- Persistent metrics storage ---

# Separate volume so 30 days of Prometheus history survive instance
# replacement (user-data/AMI changes). Formatted and mounted at
# /var/lib/prometheus by monitoring_setup.sh.
resource "aws_ebs_volume" "prometheus_data" {
  count = var.enable_monitoring ? 1 : 0

  availability_zone = aws_subnet.private[0].availability_zone
  size              = 20
  type              = "gp3"
  encrypted         = true

  tags = {
    Name        = "${var.project_name}-${var.environment}-prometheus-data"
    Environment = var.environment
  }
}

resource "aws_volume_attachment" "prometheus_data" {
  count = var.enable_monitoring ? 1 : 0

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.prometheus_data[0].id
  instance_id = aws_instance.monitoring[0].id
}

# --- The monitoring instance ---

resource "aws_instance" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.monitoring_instance_type
  key_name               = aws_key_pair.role["monitoring"].key_name
  vpc_security_group_ids = [aws_security_group.monitoring[0].id]
  subnet_id              = aws_subnet.private[0].id
  iam_instance_profile   = aws_iam_instance_profile.monitoring[0].name

  user_data = local.monitoring_user_data

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Metrics live on the separate prometheus_data volume; the root volume
  # only holds the OS and binaries.
  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-monitoring"
    Environment = var.environment
    Type        = "Monitoring"
  }

  lifecycle {
    # A new Ubuntu AMI release must not silently replace the instance on
    # the next apply; replace deliberately via `terraform apply -replace`
    ignore_changes = [ami]
  }

  depends_on = [
    aws_nat_gateway.main,
    aws_s3_object.provisioning
  ]
}
