output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "load_balancer_dns" {
  description = "DNS name of the load balancer"
  value       = aws_lb.main.dns_name
}

output "load_balancer_zone_id" {
  description = "Zone ID of the load balancer"
  value       = aws_lb.main.zone_id
}

# Web servers are managed by an ASG; their IPs change as instances are
# replaced. Discover them at any time with:
#   aws ec2 describe-instances --filters "Name=tag:Type,Values=WebServer" \
#     "Name=instance-state-name,Values=running" \
#     --query 'Reservations[].Instances[].PrivateIpAddress'
# (scripts/vhost-helper.sh and the bastion tools do this automatically)
output "web_asg_name" {
  description = "Name of the web tier Auto Scaling Group"
  value       = aws_autoscaling_group.web.name
}

output "database_server_ips" {
  description = "Private IP addresses of database servers"
  value       = aws_instance.database[*].private_ip
}

output "efs_id" {
  description = "ID of the EFS file system"
  value       = aws_efs_file_system.main.id
}

output "efs_dns_name" {
  description = "DNS name of the EFS file system"
  value       = aws_efs_file_system.main.dns_name
}

output "bastion_public_ip" {
  description = "Public IP address of the bastion host"
  value       = aws_eip.bastion.public_ip
}

output "bastion_public_dns" {
  description = "Public DNS name of the bastion host"
  value       = aws_instance.bastion.public_dns
}

output "db_backup_bucket" {
  description = "S3 bucket receiving nightly encrypted database backups"
  value       = aws_s3_bucket.db_backups.bucket
}

output "waf_web_acl_arn" {
  description = "ARN of the WAF web ACL attached to the load balancer (empty if disabled)"
  value       = var.enable_waf ? aws_wafv2_web_acl.main[0].arn : ""
}

output "monitoring_private_ip" {
  description = "Private IP of the Prometheus/Grafana monitoring server (empty if disabled)"
  value       = var.enable_monitoring ? aws_instance.monitoring[0].private_ip : ""
}

output "grafana_tunnel_command" {
  description = "SSH tunnel command to open Grafana (3000), Prometheus (9090) and Alertmanager (9093) locally"
  value       = var.enable_monitoring ? "ssh -F sshcfg -L 3000:${aws_instance.monitoring[0].private_ip}:3000 -L 9090:${aws_instance.monitoring[0].private_ip}:9090 -L 9093:${aws_instance.monitoring[0].private_ip}:9093 bastion" : ""
}

output "grafana_admin_password_parameter" {
  description = "SSM parameter holding the generated Grafana admin password (aws ssm get-parameter --with-decryption --name <this>)"
  value       = var.enable_monitoring ? "${local.ssm_prefix}/monitoring/grafana_admin_password" : ""
}

output "alerts_sns_topic_arn" {
  description = "SNS topic receiving Prometheus alerts (empty if monitoring disabled)"
  value       = var.enable_monitoring ? aws_sns_topic.alerts[0].arn : ""
}

output "provisioning_bucket" {
  description = "S3 bucket holding instance provisioning scripts (fetched at boot)"
  value       = aws_s3_bucket.provisioning.bucket
}

output "db_secret_parameters" {
  description = "SSM Parameter Store paths holding the database secrets"
  value = {
    root_password        = aws_ssm_parameter.db_root_password.name
    replication_password = aws_ssm_parameter.db_replication_password.name
    app_password         = aws_ssm_parameter.db_app_password.name
  }
}

# ---------------------------------------------------------------------------
# Generated ssh config (./sshcfg) wiring the per-role generated keys and
# ProxyJump through the bastion - same approach as CR3_demo. Usage:
#   ssh -F sshcfg bastion
#   ssh -F sshcfg db1
#   ssh -F sshcfg ubuntu@<web-private-ip>   # ASG web servers, dynamic IPs
# ---------------------------------------------------------------------------

resource "local_file" "sshconfig" {
  content = <<-EOF
    Host bastion
        Hostname ${aws_eip.bastion.public_ip}
        User ubuntu
        IdentityFile ${local.ssh_key_file["bastion"]}
        ForwardAgent yes
        StrictHostKeyChecking accept-new

    Host db1
        Hostname ${aws_instance.database[0].private_ip}
        User ubuntu
        IdentityFile ${local.ssh_key_file["database"]}
        ProxyJump bastion
        StrictHostKeyChecking accept-new

    Host db2
        Hostname ${aws_instance.database[1].private_ip}
        User ubuntu
        IdentityFile ${local.ssh_key_file["database"]}
        ProxyJump bastion
        StrictHostKeyChecking accept-new
    %{if var.enable_monitoring}
    Host monitoring
        Hostname ${aws_instance.monitoring[0].private_ip}
        User ubuntu
        IdentityFile ${local.ssh_key_file["monitoring"]}
        ProxyJump bastion
        StrictHostKeyChecking accept-new
    %{endif}
    # Web servers are ASG-managed (dynamic IPs): ssh -F sshcfg ubuntu@<ip>.
    # The wildcard matches VPC addresses and jumps through the bastion.
    Host ${join(".", slice(split(".", split("/", var.vpc_cidr)[0]), 0, 2))}.*
        User ubuntu
        IdentityFile ${local.ssh_key_file["web"]}
        IdentityFile ${local.ssh_key_file["database"]}
        IdentityFile ${local.ssh_key_file["monitoring"]}
        ProxyJump bastion
        StrictHostKeyChecking accept-new
  EOF

  filename        = "${path.module}/sshcfg"
  file_permission = "0600"
}

output "ssh_connection_commands" {
  description = "SSH access via the generated ./sshcfg (per-role keys in sshkeys_generated/)"
  value = {
    bastion          = "ssh -F sshcfg bastion"
    web_servers      = "ssh -F sshcfg ubuntu@<web-private-ip>  (IPs: bastion 'hosts' tool, or tag-filtered describe-instances)"
    database_servers = ["ssh -F sshcfg db1", "ssh -F sshcfg db2"]
    monitoring       = var.enable_monitoring ? "ssh -F sshcfg monitoring" : ""
  }
}