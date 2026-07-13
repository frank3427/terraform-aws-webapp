# AWS Web Application Infrastructure with Terraform

This Terraform project deploys a highly available web application infrastructure on AWS with the following components:

## Architecture

- **Load Balancer**: Application Load Balancer (ALB) with optional HTTPS termination (ACM) and AWS WAF, distributing traffic across 3 web servers
- **Web Servers**: 3 EC2 instances running Apache with latest PHP in private subnets
- **Shared Storage**: EFS (Elastic File System) mounted on all web servers for shared website files
- **Database**: 2 MariaDB servers configured in master-master replication
- **Bastion Host**: Secure jump server for management access to private instances
- **Network**: Multi-AZ VPC with public, private, and database subnets; VPC Flow Logs enabled

## Features

- **High Availability**: Resources distributed across multiple Availability Zones
- **Security**: Secrets in SSM Parameter Store, IMDSv2 enforced, WAF managed rules, restricted egress on all security groups, encrypted storage — see SECURITY.md
- **Scalability**: Load balancer with health checks, shared EFS storage
- **Database Replication**: Master-master MariaDB setup for high availability
- **Backups**: Nightly encrypted database backups to S3 with lifecycle retention
- **Monitoring**: CloudWatch agent and SSM Session Manager on all instances (via IAM instance roles)

## Prerequisites

1. AWS CLI configured with appropriate credentials
2. Terraform >= 1.0 installed
3. An existing AWS Key Pair for EC2 instance access
4. Your admin IP ranges for bastion SSH access (`bastion_allowed_cidrs` is required; `0.0.0.0/0` is rejected)
5. Optional: an ACM certificate in the deployment region for HTTPS

## Deployment

1. **Clone and navigate to the project directory**
   ```bash
   cd terraform-aws-webapp
   ```

2. **Copy and customize the variables file**
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
   
   Edit `terraform.tfvars` with your specific values:
   - Set your AWS region
   - Specify your EC2 Key Pair name
   - Set strong, distinct database passwords (`db_root_password`, `db_replication_password`, `db_app_password`)
   - Set `bastion_allowed_cidrs` to your admin IP ranges (required)
   - Optionally set `acm_certificate_arn` for HTTPS at the load balancer
   - Adjust instance types and network CIDRs as needed

3. **Initialize Terraform**
   ```bash
   terraform init
   ```
   For production, configure the encrypted S3 state backend first (see the
   commented block in `main.tf`) — the state file contains secret values.

4. **Review the deployment plan**
   ```bash
   terraform plan
   ```

5. **Deploy the infrastructure**
   ```bash
   terraform apply
   ```

6. **Access your application**
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

### Security Groups
- **ALB Security Group**: HTTP (80) and HTTPS (443) in from internet; egress only to web servers on 80
- **Web Server Security Group**: HTTP from ALB, SSH from bastion; egress restricted to package mirrors/AWS APIs, VPC DNS, NTP, EFS (2049), and MySQL (3306)
- **Database Security Group**: MySQL (3306) from web servers, bastion, and between DB servers; SSH from bastion; egress restricted as above
- **EFS Security Group**: NFS (2049) from web servers only; no egress
- **Bastion Security Group**: SSH only from `bastion_allowed_cidrs`; egress restricted to SSH within the VPC, MySQL to DB servers, package mirrors/AWS APIs, DNS, and NTP

### Web Servers
- **OS**: Ubuntu 26.04 LTS (Resolute Raccoon)
- **Web Server**: Apache 2.4 (latest) with virtual host support and hardened defaults (security headers, no version banners)
- **PHP**: OS-default PHP (unversioned metapackages) with common extensions
- **Storage**: EFS mounted at `/var/www/shared` for shared website files and configurations
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
- **Health Checks**: HTTP health checks on port 80
- **Distribution**: Round-robin across healthy targets

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
# Quick aliases available on bastion host
web1    # Connect to web server 1
web2    # Connect to web server 2  
web3    # Connect to web server 3
db1     # Connect to database server 1
db2     # Connect to database server 2

# Or use interactive menus
connect-web    # Interactive web server selection
connect-db     # Interactive database server selection
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
WEB_SERVERS="10.0.11.10 10.0.12.10 10.0.13.10"  # From terraform output
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
db1  # Connect to database master 1
db2  # Connect to database master 2

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

- **CloudWatch Agent**: Installed on all instances for system metrics
- **Apache Logs**: Available in `/var/log/apache2/`
- **MariaDB Logs**: Available in `/var/log/mysql/`
- **System Logs**: Available via CloudWatch Logs

## Backup and Recovery

### Database Backups
- Automated nightly backups at 2 AM via cron (compressed with mysqldump)
- Shipped to a dedicated S3 bucket (KMS-encrypted, versioned, public access blocked) with 35-day lifecycle retention — see the `db_backup_bucket` output
- Last 7 days also kept locally in `/var/backups/mariadb/`
- Test restores periodically — an untested backup is not a backup

### EFS Backups
Consider enabling AWS Backup for EFS filesystem protection.

## Scaling

### Horizontal Scaling
To add more web servers:
1. Increase the count in `ec2.tf`
2. Update load balancer target group attachments
3. Apply Terraform changes

### Vertical Scaling
Modify instance types in `terraform.tfvars` and apply changes.

## Security Considerations

See **SECURITY.md** for the full security model. Highlights:

- Database secrets in SSM Parameter Store (never in EC2 user data); least-privilege DB users
- AWS WAF with managed rules on the ALB; HTTPS via ACM; hardened ALB and Apache headers
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
- EFS storage (variable): ~$10-50
- NAT Gateways (3): ~$100
- VPC Flow Logs + CloudWatch: ~$5-20 (traffic dependent)
- S3 backup storage: ~$1-5
- Data transfer: Variable

Total estimated: $300-510/month (excluding data transfer)

## Cleanup

To destroy all resources:
```bash
# 1. Disable ALB deletion protection first
terraform apply -var="alb_deletion_protection=false"

# 2. Then destroy
terraform destroy
```

Note: the S3 backup bucket must be emptied before destroy will remove it,
and SSM parameters are deleted with the stack.

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