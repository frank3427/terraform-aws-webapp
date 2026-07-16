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
  value       = var.enable_monitoring ? "ssh -i your-key.pem -L 3000:${aws_instance.monitoring[0].private_ip}:3000 -L 9090:${aws_instance.monitoring[0].private_ip}:9090 -L 9093:${aws_instance.monitoring[0].private_ip}:9093 ubuntu@${aws_instance.bastion.public_ip}" : ""
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

output "ssh_connection_commands" {
  description = "SSH connection commands for accessing servers (web servers: get the IP from the bastion's fleet tools or the AWS CLI, then use the same ProxyCommand pattern)"
  value = {
    bastion = "ssh -i your-key.pem ubuntu@${aws_eip.bastion.public_ip}"
    web_servers = "ASG-managed; on the bastion run refresh-hosts / health-check, or: ssh -i your-key.pem -o ProxyCommand=\"ssh -i your-key.pem -W %h:%p ubuntu@${aws_eip.bastion.public_ip}\" ubuntu@<web-private-ip>"
    database_servers = [
      for i, instance in aws_instance.database :
      "ssh -i your-key.pem -o ProxyCommand=\"ssh -i your-key.pem -W %h:%p ubuntu@${aws_eip.bastion.public_ip}\" ubuntu@${instance.private_ip}"
    ]
  }
}