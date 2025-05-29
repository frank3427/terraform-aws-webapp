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

output "web_server_ips" {
  description = "Private IP addresses of web servers"
  value       = aws_instance.web[*].private_ip
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

output "ssh_connection_commands" {
  description = "SSH connection commands for accessing servers"
  value = {
    bastion = "ssh -i your-key.pem ubuntu@${aws_eip.bastion.public_ip}"
    web_servers = [
      for i, instance in aws_instance.web : 
      "ssh -i your-key.pem -o ProxyCommand=\"ssh -i your-key.pem -W %h:%p ubuntu@${aws_eip.bastion.public_ip}\" ubuntu@${instance.private_ip}"
    ]
    database_servers = [
      for i, instance in aws_instance.database : 
      "ssh -i your-key.pem -o ProxyCommand=\"ssh -i your-key.pem -W %h:%p ubuntu@${aws_eip.bastion.public_ip}\" ubuntu@${instance.private_ip}"
    ]
  }
}