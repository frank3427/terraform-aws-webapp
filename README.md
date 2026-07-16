# AWS Web Application Infrastructure with Terraform

This Terraform project deploys a highly available web application infrastructure on AWS with the following components:

## Architecture

- **Load Balancer**: Application Load Balancer (ALB) with optional HTTPS termination (ACM) and AWS WAF, distributing traffic across the web tier with cookie stickiness
- **Web Servers**: Auto Scaling Group (default 3 instances) running Apache with latest PHP in private subnets, rolling instance refresh
- **Shared Storage**: EFS (Elastic File System) mounted on all web servers for shared website files
- **Database**: 2 MariaDB servers configured in master-master replication
- **Bastion Host**: Secure jump server for management access to private instances
- **Network**: Multi-AZ VPC with public, private, and database subnets; VPC Flow Logs enabled

## Project Structure

```
├── main.tf                  # Provider, AMI lookup, remote state backend (see bootstrap/)
├── variables.tf             # Input variables incl. security and cost toggles
├── vpc.tf                   # VPC, subnets, routing, NAT (per-AZ or single), S3 gateway endpoint
├── flow_logs.tf             # VPC Flow Logs to CloudWatch
├── security_groups.tf       # All SGs and rules (restricted egress)
├── iam.tf                   # Instance roles/profiles, SSM SecureString secrets
├── ec2.tf                   # Web launch template + ASG, database instances (IMDSv2)
├── bastion.tf               # Bastion host
├── efs.tf                   # Shared storage + automatic AWS Backup
├── load_balancer.tf         # ALB, HTTP/HTTPS listeners, target group
├── alb_logs.tf              # ALB access-log S3 bucket and delivery policy
├── waf.tf                   # WAFv2 web ACL, rate limiting, logging
├── backups.tf               # Encrypted S3 bucket for database backups
├── monitoring.tf            # Prometheus + Grafana instance, SGs, discovery IAM, metrics EBS volume
├── alerting.tf              # SNS alert topic, email subscription, Alertmanager IAM
├── provisioning.tf          # S3 bucket serving instance setup scripts at boot
├── user_data.tf             # Instance bootstrap wiring (no secrets)
├── outputs.tf               # Deployment outputs
├── scripts/                 # Instance setup + management scripts
├── bootstrap/               # One-time config creating the Terraform state bucket
├── packer/                  # Optional pre-baked web AMI (fast, download-free boots)
├── SECURITY.md              # Security model and responsibilities
├── MONITORING.md            # Prometheus/Grafana monitoring guide
├── VHOST_MANAGEMENT.md      # Virtual host system guide
└── BASTION_MANAGEMENT.md    # Bastion usage guide
```

## Features

- **High Availability**: Resources distributed across multiple Availability Zones; self-healing web tier (ASG replaces failed instances automatically)
- **Security**: Secrets in SSM Parameter Store, IMDSv2 enforced, WAF managed rules, restricted egress on all security groups, encrypted storage — see SECURITY.md
- **Scalability**: Auto Scaling Group web tier behind the ALB with local-disk health checks (`/healthz`) and rolling instance refresh; shared EFS storage (elastic throughput, infrequent-access lifecycle)
- **Safe operations**: Provisioning scripts served from S3, so script edits never force instance replacement; launch-template changes roll through the fleet gradually, gated on ALB health
- **Database Replication**: Master-master MariaDB setup for high availability
- **Backups**: Nightly encrypted database backups to S3 with lifecycle retention; EFS content via AWS Backup
- **Monitoring & Alerting**: Prometheus + Alertmanager + Grafana with per-server CPU/RAM/disk, Apache, and MariaDB replication metrics; alert delivery via SNS email (see MONITORING.md); SSM Session Manager on all instances
- **Fast boots (optional)**: Packer-baked web AMI with packages and exporters preinstalled (see packer/README.md)

## Prerequisites

1. AWS CLI configured with appropriate credentials
2. Terraform >= 1.10 installed (S3 state locking via `use_lockfile`)
3. An existing AWS Key Pair for EC2 instance access
4. Your admin IP ranges for bastion SSH access (`bastion_allowed_cidrs` is required; `0.0.0.0/0` is rejected)
5. Optional: an ACM certificate in the deployment region for HTTPS
6. Optional: Packer, if you want to pre-bake the web AMI (see packer/README.md)

## Deployment

1. **Clone and navigate to the project directory**
   ```bash
   cd terraform-aws-webapp
   ```

2. **Create the state bucket (one-time)** — the state file contains the
   database passwords, so production state must live in the encrypted S3
   backend:
   ```bash
   cd bootstrap
   terraform init && terraform apply
   cd ..
   ```
   Paste the `backend_block` output into the `terraform` block in
   `main.tf` (replacing the commented example).

3. **Copy and customize the variables file**
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
   
   Edit `terraform.tfvars` with your specific values:
   - Set your AWS region
   - Specify your EC2 Key Pair name
   - Set strong, distinct database passwords (`db_root_password`, `db_replication_password`, `db_app_password`)
   - Set `bastion_allowed_cidrs` to your admin IP ranges (required)
   - Set `alert_email` to receive Prometheus alerts (confirm the
     subscription email AWS sends after apply)
   - Optionally set `acm_certificate_arn` for HTTPS at the load balancer
   - Optionally set `single_nat_gateway = true` (cost) or `web_ami_id`
     (pre-baked AMI, see packer/README.md)
   - Adjust instance types and network CIDRs as needed

   `terraform.tfvars` contains real passwords — it is listed in `.gitignore`
   and must never be committed.

4. **Initialize Terraform**
   ```bash
   terraform init            # or: terraform init -migrate-state, if you
                             # previously used local state
   ```

5. **Review the deployment plan**
   ```bash
   terraform plan
   ```

6. **Deploy the infrastructure**
   ```bash
   terraform apply
   ```

7. **Access your application**
   After deployment, the load balancer DNS name will be displayed in the outputs. You can access your web application at:
   ```
   http://[load-balancer-dns-name]
   ```
   With an ACM certificate configured, HTTP redirects to HTTPS automatically.

## Infrastructure Components

### Network Architecture
- **VPC**: 10.0.0.0/16 (customizable)
- **Public Subnets**: 10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24 (for ALB)
- **Private Subnets**: 10.0.11.0/24, 10.0.12.0/24, 10.0.13.0/24 (for web servers)
- **Database Subnets**: 10.0.21.0/24, 10.0.22.0/24 (for MariaDB servers)
- **NAT**: One NAT gateway per AZ by default; `single_nat_gateway = true` shares one (~$65/mo cheaper, single-AZ egress dependency)
- **S3 Gateway Endpoint**: S3 traffic from private/database subnets (backups, provisioning scripts, mirrors) bypasses the NAT gateways — free and more resilient

### Security Groups
- **ALB Security Group**: HTTP (80) and HTTPS (443) in from internet; egress only to web servers on 80
- **Web Server Security Group**: HTTP from ALB, SSH from bastion; egress restricted to package mirrors/AWS APIs, VPC DNS, NTP, EFS (2049), and MySQL (3306)
- **Database Security Group**: MySQL (3306) from web servers, bastion, and between DB servers; SSH from bastion; egress restricted as above
- **EFS Security Group**: NFS (2049) from web servers only; no egress
- **Bastion Security Group**: SSH only from `bastion_allowed_cidrs`; egress restricted to SSH within the VPC, MySQL to DB servers, package mirrors/AWS APIs, DNS, and NTP

### Web Servers
- **Lifecycle**: Auto Scaling Group (`web_server_count` capacity) with launch template, ELB health checks, and rolling instance refresh; provisioning scripts fetched from S3 at boot (16 KB user-data limit, no replacement on script edits)
- **OS**: Ubuntu 26.04 LTS (Resolute Raccoon), or the pre-baked web AMI (`web_ami_id`, see packer/)
- **Web Server**: Apache 2.4 (latest) with virtual host support and hardened defaults (security headers, no version banners)
- **PHP**: OS-default PHP (unversioned metapackages) with common extensions; OPcache tuned for code served from EFS (60s revalidation)
- **Storage**: EFS mounted at `/var/www/shared` for shared website files and configurations (elastic throughput; content idle 30+ days moves to Infrequent Access)
- **Virtual Hosts**: Automated vhost management with EFS-based content sharing
- **Instance Type**: t3.medium (customizable)

### Database Servers
- **Database**: MariaDB (OS default) with master-master replication
- **Configuration**: Optimized for replication with GTID
- **Secrets**: Passwords fetched from SSM Parameter Store at boot; never in user data
- **Backup**: Nightly compressed dumps shipped to an encrypted S3 bucket (35-day retention), plus 7 days kept locally
- **Instance Type**: t3.large (customizable)
- **Storage**: 50GB root + 100GB data volume (encrypted)

### Load Balancer
- **Type**: Application Load Balancer
- **HTTPS**: Optional TLS termination with an ACM certificate (`acm_certificate_arn`); HTTP redirects to HTTPS when enabled
- **WAF**: AWS WAFv2 with rate limiting and AWS managed rules (`enable_waf`), decisions logged to CloudWatch
- **Health Checks**: HTTP health checks on `/healthz`, served from each instance's local disk so an EFS stall can't fail the whole fleet at once
- **Session Stickiness**: duration-based cookie stickiness (24h) so PHP file-based sessions survive load balancing
- **Access Logs**: Request-level logs to a dedicated encrypted S3 bucket (90-day retention)
- **Hardening**: Drops malformed headers; deletion protection enabled by default
- **Distribution**: Round-robin across healthy targets (sticky per client via cookie); 60s deregistration drain on instance replacement

## Management

### Accessing Instances

#### Bastion Host Access
The infrastructure includes a bastion host for secure access to private instances. After deployment, use the bastion host to access web and database servers:

1. **Connect to bastion host**:
```bash
ssh -i your-key.pem ubuntu@[bastion-public-ip]
```

2. **From bastion host, connect to private instances**:
```bash
# Fleet is discovered automatically from EC2 tags - works with any count
hosts          # List all discovered web and database servers
web 1          # SSH to web server 1 (web 2, web 3, ... for others)
db 1           # SSH to database server 1

# Or use interactive menus
connect-web    # Interactive web server selection
connect-db     # Interactive database server selection
refresh-hosts  # Force re-discovery after scaling or instance replacement
```

3. **Direct SSH with ProxyCommand** (from your local machine):
```bash
# Web servers
ssh -i your-key.pem -o ProxyCommand="ssh -i your-key.pem -W %h:%p ubuntu@[bastion-ip]" ubuntu@[web-server-private-ip]

# Database servers  
ssh -i your-key.pem -o ProxyCommand="ssh -i your-key.pem -W %h:%p ubuntu@[bastion-ip]" ubuntu@[db-server-private-ip]
```

#### Bastion Host Features
The bastion host comes pre-configured with:
- **Management Tools**: Scripts for infrastructure management
- **SSH Configuration**: Optimized for internal server access
- **Virtual Host Management**: Remote vhost management capabilities
- **Health Monitoring**: Infrastructure status checking
- **Database Tools**: MySQL client for database access
- **AWS CLI**: For AWS resource management

### Virtual Host Management

The infrastructure includes a comprehensive virtual host management system that automatically synchronizes configurations across all web servers using EFS.

#### Creating Virtual Hosts
On any web server:
```bash
# Create a virtual host
sudo vhost create example.com

# Optionally set a ServerAdmin email
sudo vhost create example.com admin@example.com
```

HTTPS is terminated at the load balancer using an ACM certificate (set
`acm_certificate_arn` in `terraform.tfvars`); instances serve HTTP only.
See VHOST_MANAGEMENT.md for details.

#### Managing Virtual Hosts
```bash
# List all virtual hosts
sudo vhost list

# Synchronize vhosts on this server now (automatic every minute)
sudo vhost sync

# Remove a virtual host (content preserved; add --purge to delete it)
sudo vhost remove example.com
```

#### EFS Directory Structure
```
/var/www/shared/
├── vhosts/                    # Website content for each domain
│   ├── example.com/
│   │   └── public_html/       # Document root
│   └── default/               # Default vhost content
└── vhost-configs/             # Apache configuration files
    ├── example.com.conf
    └── default.conf
```

Per-vhost logs live on each server's local disk at
`/var/log/apache2/<domain>-{access,error}.log`, not on EFS.

#### Automatic Synchronization
- Virtual host configurations are automatically synchronized across all web servers
- Each server runs a `vhost-sync.timer` that applies the shared EFS configuration every minute
- Changes made on any server are applied to all servers within one minute
- No manual intervention required for most operations

#### Remote Management

**Option 1: From Bastion Host (Recommended)**
```bash
# SSH to bastion host first
ssh -i your-key.pem ubuntu@[bastion-public-ip]

# Use built-in vhost management
vhost create example.com
vhost list
vhost remove example.com
vhost sync
```

**Option 2: Direct from Local Machine**
Use the provided `vhost-helper.sh` script:

1. Configure the script with your Terraform outputs:
```bash
# Edit the script variables
JUMP_HOST="[bastion-public-ip]"           # From terraform output
WEB_SERVERS="auto"  # auto-discovers via AWS CLI, or list IPs from terraform output
SSH_KEY="/path/to/your-key.pem"
```

2. Use the script:
```bash
./scripts/vhost-helper.sh create example.com
./scripts/vhost-helper.sh list
./scripts/vhost-helper.sh remove example.com
```

### Database Management

#### From Bastion Host
```bash
# Interactive database connection
mysql-connect

# Direct connection to specific server
mysql -h 10.0.21.10 -u root -p  # Master 1
mysql -h 10.0.22.10 -u root -p  # Master 2
```

#### SSH to Database Servers
```bash
# From bastion host
db 1  # Connect to database master 1
db 2  # Connect to database master 2

# Then on database server
mysql -u root -p
```

#### Check Replication Status
```sql
SHOW SLAVE STATUS\G
SHOW MASTER STATUS\G
```

### EFS Management
The EFS filesystem is automatically mounted on web servers at `/var/www/shared`. To manually mount:
```bash
sudo mount -t nfs4 [efs-dns-name]:/ /var/www/shared
```

## Monitoring and Logs

- **Metrics (Prometheus + Grafana)**: CPU/RAM/disk on every server, Apache workers/requests, MariaDB and replication lag — dashboards via bastion tunnel, see **MONITORING.md**

- **ALB Access Logs**: Request-level HTTP logs (client IP, URL, status, latency) in the dedicated S3 bucket (see `alb_logs.tf`), 90-day retention
- **WAF Logs**: Allow/block decisions per rule in CloudWatch log group `aws-waf-logs-<project>-<environment>`, 90-day retention
- **VPC Flow Logs**: Network traffic metadata in CloudWatch log group `/vpc/<project>-<environment>/flow-logs`, 90-day retention
- **Apache Logs**: `/var/log/apache2/` on each web server; per-vhost logs at `/var/log/apache2/<domain>-{access,error}.log` with real client IPs (mod_remoteip)
- **MariaDB Logs**: `/var/log/mysql/` on each database server
- **Vhost Sync Logs**: `journalctl -u vhost-sync.service` on each web server
- **SSM Session Manager**: Auditable shell access to all instances without SSH (session history in the AWS console)
- **Alerting**: Prometheus rules → Alertmanager → SNS email (`alert_email` variable); see **MONITORING.md**

## Outputs

Key Terraform outputs after `terraform apply`:

- `load_balancer_dns` — public entry point for the application
- `bastion_public_ip` / `bastion_public_dns` — admin access
- `web_asg_name` — the web tier Auto Scaling Group (instance IPs are dynamic; discover via the bastion tools or tag-filtered `describe-instances`)
- `db_backup_bucket` — S3 bucket receiving nightly database backups
- `db_secret_parameters` — SSM Parameter Store paths for the database passwords
- `provisioning_bucket` — S3 bucket serving instance setup scripts at boot
- `waf_web_acl_arn` — WAF web ACL attached to the ALB (empty if disabled)
- `monitoring_private_ip` / `grafana_tunnel_command` — access to the Grafana/Prometheus/Alertmanager UIs
- `grafana_admin_password_parameter` — SSM parameter holding the Grafana admin password
- `alerts_sns_topic_arn` — SNS topic receiving Prometheus alerts

## Backup and Recovery

### Database Backups
- Automated nightly backups at 2 AM via cron (compressed with mysqldump)
- Shipped to a dedicated S3 bucket (KMS-encrypted, versioned, public access blocked) with 35-day lifecycle retention — see the `db_backup_bucket` output
- Last 7 days also kept locally in `/var/backups/mariadb/`
- Test restores periodically — an untested backup is not a backup

### EFS Backups
EFS website content is backed up automatically via AWS Backup
(`aws_efs_backup_policy` in `efs.tf`).

## Scaling

### Horizontal Scaling
Set `web_server_count` in `terraform.tfvars` (default 3) and run
`terraform apply`. The web tier is an Auto Scaling Group: instances spread
across the private subnets/AZs, register with the target group
automatically, failed instances are replaced, and launch-template changes
roll through the fleet gradually (instance refresh, gated on ALB health).
The bastion management tools and Prometheus discover the new fleet within
minutes (or run `refresh-hosts`).

### Vertical Scaling
Modify instance types in `terraform.tfvars` and apply changes.

## Security Considerations

See **SECURITY.md** for the full security model. Highlights:

- Database secrets in SSM Parameter Store (never in EC2 user data); least-privilege DB users
- AWS WAF with rate limiting + managed rules on the ALB (decisions logged); HTTPS via ACM; hardened ALB with access logs
- Automatic security patching (unattended-upgrades) on all instances
- IMDSv2 enforced; least-privilege IAM instance roles; SSM Session Manager available
- Restricted egress on all security groups; bastion SSH limited to explicit admin CIDRs
- All EBS volumes and EFS encrypted at rest; nightly DB backups to an encrypted S3 bucket
- VPC Flow Logs enabled (90-day retention)
- If sites take card payments, use a payment processor's hosted fields — do not store card data here (see SECURITY.md)

## Costs

Estimated monthly costs (us-west-2):
- EC2 instances (6 × t3.micro/medium/large): ~$150-300
- Application Load Balancer: ~$20
- AWS WAF (if enabled): ~$10-15
- EFS storage (variable; elastic throughput billed per GB transferred, idle content transitions to cheaper IA): ~$10-50
- NAT Gateways: ~$100 for 3, or ~$35 with `single_nat_gateway = true`; the S3 gateway endpoint keeps S3 traffic (backups, provisioning) off NAT entirely
- VPC Flow Logs + CloudWatch: ~$5-20 (traffic dependent)
- Monitoring instance (t3.small + 20GB root + 20GB metrics volume): ~$20
- S3 backup/provisioning storage + SNS alerting: ~$1-5
- Data transfer: Variable

Total estimated: $320-530/month (excluding data transfer; ~$65 less with a single NAT gateway)

## Cleanup

To destroy all resources:
```bash
# 1. Disable ALB deletion protection first
terraform apply -var="alb_deletion_protection=false"

# 2. Then destroy
terraform destroy
```

Note: the S3 backup and provisioning buckets must be emptied (including
old object versions) before destroy will remove them, and SSM parameters
are deleted with the stack. The state bucket created by `bootstrap/` is
deliberately protected with `prevent_destroy`.

## Troubleshooting

### Common Issues

1. **Key Pair Not Found**: Ensure the specified key pair exists in your AWS region
2. **Permission Denied**: Check AWS credentials and IAM permissions
3. **Resource Limits**: Verify AWS service limits for your account
4. **Health Check Failures**: Check security groups and application status

### Logs
Check CloudWatch Logs and instance system logs for detailed error information.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes and test thoroughly
4. Submit a pull request

## License

This project is licensed under the MIT License.