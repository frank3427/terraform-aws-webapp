# AWS Web Application Infrastructure with Terraform

This Terraform project deploys a highly available web application infrastructure on AWS with the following components:

## Architecture

- **Load Balancer**: Application Load Balancer (ALB) distributing traffic across 3 web servers
- **Web Servers**: 3 EC2 instances running Apache with latest PHP in private subnets
- **Shared Storage**: EFS (Elastic File System) mounted on all web servers for shared website files
- **Database**: 2 MariaDB servers configured in master-master replication
- **Bastion Host**: Secure jump server for management access to private instances
- **Network**: Multi-AZ VPC with public, private, and database subnets

## Features

- **High Availability**: Resources distributed across multiple Availability Zones
- **Security**: Web servers and databases in private subnets, security groups with minimal required access
- **Scalability**: Load balancer with health checks, shared EFS storage
- **Database Replication**: Master-master MariaDB setup for high availability
- **Monitoring**: CloudWatch agent installed on all instances

## Prerequisites

1. AWS CLI configured with appropriate credentials
2. Terraform >= 1.0 installed
3. An existing AWS Key Pair for EC2 instance access

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
   - Set strong database passwords
   - Adjust instance types and network CIDRs as needed

3. **Initialize Terraform**
   ```bash
   terraform init
   ```

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

## Infrastructure Components

### Network Architecture
- **VPC**: 10.0.0.0/16 (customizable)
- **Public Subnets**: 10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24 (for ALB)
- **Private Subnets**: 10.0.11.0/24, 10.0.12.0/24, 10.0.13.0/24 (for web servers)
- **Database Subnets**: 10.0.21.0/24, 10.0.22.0/24 (for MariaDB servers)

### Security Groups
- **ALB Security Group**: Allows HTTP (80) and HTTPS (443) from internet
- **Web Server Security Group**: Allows HTTP from ALB, SSH from VPC, NFS for EFS
- **Database Security Group**: Allows MySQL (3306) from web servers and between DB servers
- **EFS Security Group**: Allows NFS (2049) from web servers

### Web Servers
- **OS**: Ubuntu 22.04 LTS
- **Web Server**: Apache 2.4 (latest) with virtual host support
- **PHP**: PHP 8.1 with common extensions
- **Storage**: EFS mounted at `/var/www/shared` for shared website files and configurations
- **Virtual Hosts**: Automated vhost management with EFS-based content sharing
- **Instance Type**: t3.medium (customizable)

### Database Servers
- **Database**: MariaDB 10.6+ with master-master replication
- **Configuration**: Optimized for replication with GTID
- **Backup**: Automated daily backups via cron
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
# Create a basic HTTP virtual host
sudo vhost create example.com

# Create an HTTPS virtual host (requires SSL certificates)
sudo vhost create secure.com ssl admin@secure.com
```

#### Managing Virtual Hosts
```bash
# List all virtual hosts
sudo vhost list

# Synchronize vhosts across all servers (usually automatic)
sudo vhost sync

# Remove a virtual host
sudo vhost remove example.com
```

#### EFS Directory Structure
```
/var/www/shared/
├── vhosts/                    # Website content for each domain
│   ├── example.com/
│   │   ├── public_html/       # Document root
│   │   └── logs/              # Per-vhost logs
│   └── default/               # Default vhost content
├── vhost-configs/             # Apache configuration files
│   ├── example.com.conf
│   └── default.conf
└── ssl-certs/                 # SSL certificates
    ├── example.com.crt
    └── example.com.key
```

#### Automatic Synchronization
- Virtual host configurations are automatically synchronized across all web servers
- The `vhost-watcher` service monitors EFS for configuration changes
- Changes made on any server are automatically applied to all servers
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
- Automated daily backups at 2 AM via cron
- Backups stored locally in `/var/backups/mariadb/`
- 7-day retention policy

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

- All instances use encrypted EBS volumes
- Database servers are isolated in private subnets
- Security groups follow principle of least privilege
- Consider implementing SSL/TLS termination at the load balancer
- Regularly update and patch all instances

## Costs

Estimated monthly costs (us-west-2):
- EC2 instances (5 × t3.medium/large): ~$150-300
- Application Load Balancer: ~$20
- EFS storage (variable): ~$10-50
- NAT Gateways: ~$100
- Data transfer: Variable

Total estimated: $280-470/month (excluding data transfer)

## Cleanup

To destroy all resources:
```bash
terraform destroy
```

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