# Bastion Host Management Guide

This document provides detailed instructions for using the bastion host to manage your AWS web application infrastructure.

## Overview

The bastion host serves as a secure jump server that provides:
- **Secure Access**: Single point of entry to private subnet resources
- **Management Tools**: Pre-installed tools for infrastructure management
- **Virtual Host Management**: Remote virtual host management capabilities
- **Database Access**: Direct access to MariaDB servers
- **Infrastructure Monitoring**: Health checking and status monitoring

## Architecture

```
Internet → Bastion Host (Public Subnet) → Private Resources
             ↓
    ┌─────────────────────────────────────────────┐
    │  🖥️  Bastion Host (Public IP)               │
    │  - Management Tools                         │
    │  - SSH Jump Server                          │
    │  - Health Monitoring                        │
    └─────────────────────────────────────────────┘
             ↓ SSH (Port 22)
    ┌─────────────────────────────────────────────┐
    │  🌐 Web Servers (Private Subnet)           │
    │  - web servers (dynamic IPs,               │
    │    count set by web_server_count)          │
    └─────────────────────────────────────────────┘
             ↓ SSH (Port 22)
    ┌─────────────────────────────────────────────┐
    │  🗄️ Database Servers (Private Subnet)       │
    │  - db masters (pinned .10 host address     │
    │    in each database subnet)                │
    └─────────────────────────────────────────────┘
```

## Connecting to the Bastion Host

### Initial Connection
```bash
ssh -i your-key.pem ubuntu@[bastion-public-ip]
```

The bastion host public IP is available in your Terraform outputs:
```bash
terraform output bastion_public_ip
```

### Welcome Screen
Upon connection, you'll see a welcome screen with quick command references:

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                           🚀 BASTION HOST                                    ║
║                     AWS Web Application Infrastructure                       ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  Hosts are discovered automatically from EC2 tags (any fleet size).         ║
║  🔧 Management Tools:       /opt/management-tools/                          ║
║                                                                              ║
║  Quick Commands:                                                             ║
║    connect-web           - Interactive web server connection                 ║
║    connect-db            - Interactive database server connection           ║
║    mysql-connect         - Connect to MariaDB                              ║
║    vhost <command>       - Manage virtual hosts remotely                   ║
║    health-check          - Check infrastructure status                      ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

## Quick Access Commands

### Server Aliases
The bastion host provides convenient aliases for quick server access:

```bash
# Web servers
hosts   # List all discovered servers with their current IPs
web 1   # SSH to web server 1 (web 2, web 3, ... for any count)

# Database servers
db 1    # SSH to database server 1
db 2    # SSH to database server 2
refresh-hosts  # Force fleet re-discovery (otherwise cached ~5 minutes)
```

### Interactive Connection Menus

#### Web Server Connection
```bash
connect-web
```

This displays an interactive menu:
```
Available Web Servers:
1. webapp-production-web (10.0.11.x)
2. webapp-production-web (10.0.12.x)
3. webapp-production-web (10.0.13.x)
(entries reflect the live fleet; ASG instances share one Name tag and are
distinguished by IP - the numbering is by discovery order)
Select server (1-3):
```

#### Database Server Connection
```bash
connect-db
```

This displays an interactive menu:
```
Available Database Servers:
1. db-master-1 (10.0.21.10)
2. db-master-2 (10.0.22.10)
Select server (1-2):
```

## Virtual Host Management

### From Bastion Host
The bastion host includes a complete virtual host management system:

```bash
# Create virtual hosts
vhost create example.com
vhost create example.com admin@example.com

# List all virtual hosts
vhost list

# Remove virtual hosts (content preserved; add --purge to delete it)
vhost remove example.com

# Synchronize configurations
vhost sync

# Check vhost sync timer status
vhost status
```

### Virtual Host Operations

#### Creating Virtual Hosts
```bash
# Virtual host (HTTPS is terminated at the load balancer via ACM)
vhost create mysite.com

# With a ServerAdmin email
vhost create mysite.com admin@mysite.com
```

#### Managing Existing Virtual Hosts
```bash
# List all configured virtual hosts
vhost list

# Output example:
=== Available Virtual Hosts ===

Domain: mysite.com
  Document Root: /var/www/shared/vhosts/mysite.com/public_html
  Configuration: /var/www/shared/vhost-configs/mysite.com.conf
  SSL: Disabled
  Apache Status: Enabled

Domain: securesite.com
  Document Root: /var/www/shared/vhosts/securesite.com/public_html
  Configuration: /var/www/shared/vhost-configs/securesite.com.conf
  SSL: Enabled
  Apache Status: Enabled
```

#### Removing Virtual Hosts
```bash
vhost remove mysite.com

# This will:
# 1. Disable the Apache site
# 2. Remove the configuration file
# 3. Ask if you want to remove website content
# 4. Reload Apache on all servers
```

## Database Management

### MySQL Client Access

#### Interactive Database Connection
```bash
mysql-connect
```

This displays a menu to select which database server to connect to:
```
Available Database Servers:
1. db-master-1 (10.0.21.10)
2. db-master-2 (10.0.22.10)
Select server (1-2): 1
Enter database username [root]: root
Enter password:
```

#### Direct Database Connection
```bash
# Connect to specific database server
mysql -h 10.0.21.10 -u root -p  # Master 1
mysql -h 10.0.22.10 -u root -p  # Master 2
```

Note: `webapp_user` is restricted to connections from the web server
subnets, so application-user logins must be tested from a web server, not
from the bastion.

Database passwords live in SSM Parameter Store (see the
`db_secret_parameters` Terraform output). Admins with permission can
retrieve one when needed:

```bash
aws ssm get-parameter --name /webapp/production/db/root_password \
    --with-decryption --query Parameter.Value --output text
```

### Database Administration

#### Check Replication Status
```sql
-- From either master server
SHOW SLAVE STATUS\G
SHOW MASTER STATUS\G

-- Check if both servers are synchronized
SELECT @@server_id;
```

#### Monitor Database Health
```bash
# SSH to database server first
db1

# Then check MariaDB status
sudo systemctl status mariadb
sudo journalctl -u mariadb -f
```

## Infrastructure Monitoring

### Health Check Command
```bash
health-check
```

This runs a comprehensive infrastructure health check:

```
=== Infrastructure Health Check ===
2024-01-15 10:30:00

=== Web Servers ===
webapp-production-web (10.0.11.x): ✓ Online
  Apache: ✓ Running
  VHost Watcher: ✓ Running

webapp-production-web (10.0.12.x): ✓ Online
  Apache: ✓ Running
  VHost Watcher: ✓ Running

webapp-production-web (10.0.13.x): ✓ Online
  Apache: ✓ Running
  VHost Watcher: ✓ Running

=== Database Servers ===
DB Server 1 (10.0.21.10): ✓ Online
  MariaDB: ✓ Running

DB Server 2 (10.0.22.10): ✓ Online
  MariaDB: ✓ Running

=== Load Balancer Health ===
Check AWS console for ALB target health

Health check completed at 2024-01-15 10:30:15
```

### Individual Service Checks

#### Check Web Server Status
```bash
# Check Apache status on all servers
for server in web1 web2 web3; do
    echo "Checking $server..."
    ssh ubuntu@10.0.1{1,2,3}.10 "sudo systemctl status apache2 --no-pager"
done
```

#### Check Database Status
```bash
# Check MariaDB status on all database servers
for server in db1 db2; do
    echo "Checking $server..."
    ssh ubuntu@10.0.2{1,2}.10 "sudo systemctl status mariadb --no-pager"
done
```

## Advanced Management

### File Transfer to/from Servers

#### Upload Files to Web Servers
```bash
# Upload to EFS (accessible by all web servers)
scp -r /local/path/to/website/ web1:/var/www/shared/vhosts/mysite.com/public_html/
```

TLS certificates live in AWS Certificate Manager and are never uploaded
to servers or EFS.

#### Download Files from Servers
```bash
# Download logs (per-vhost logs are local to each server)
scp web1:/var/log/apache2/mysite.com-access.log ./
scp web1:/var/log/apache2/error.log ./

# Download database backups
scp db1:/var/backups/mariadb/*.sql ./
```

### Log Monitoring

#### Real-time Log Monitoring
```bash
# Apache access logs
ssh web1 "tail -f /var/log/apache2/mysite.com-access.log"

# Apache error logs  
ssh web1 "tail -f /var/log/apache2/error.log"

# Database logs
ssh db1 "tail -f /var/log/mysql/error.log"

# System logs
ssh web1 "tail -f /var/log/syslog"
```

#### Log Analysis
```bash
# Check for errors in Apache logs
ssh web1 "grep -i error /var/log/apache2/error.log | tail -20"

# Check database connection errors
ssh db1 "grep -i 'connection refused' /var/log/mysql/error.log"

# Check disk usage
ssh web1 "df -h"
ssh db1 "df -h"
```

### Service Management

#### Restart Services
```bash
# Restart Apache on all web servers
source /opt/management-tools/lib/hosts.sh && ensure_hosts
for server in "${WEB_IPS[@]}"; do
    ssh ubuntu@$server "sudo systemctl restart apache2"
done

# Restart MariaDB on database servers
ssh db1 "sudo systemctl restart mariadb"
ssh db2 "sudo systemctl restart mariadb"
```

#### Update System Packages
Security updates install automatically every day on all instances via
`unattended-upgrades` (security pocket only, no automatic reboots). Manual
full upgrades are only needed for non-security package updates or to apply
kernel updates with a reboot:

```bash
# Update web servers
source /opt/management-tools/lib/hosts.sh && ensure_hosts
for server in "${WEB_IPS[@]}"; do
    ssh ubuntu@$server "sudo apt update && sudo apt upgrade -y"
done

# Update database servers (reboot one at a time to keep replication up)
for server in 10.0.21.10 10.0.22.10; do
    ssh ubuntu@$server "sudo apt update && sudo apt upgrade -y"
done
```

## Security Best Practices

### SSH Configuration
The bastion host is configured with optimized SSH settings:
- Password authentication disabled
- Public key authentication enabled
- Connection timeouts configured
- Host keys for internal servers accepted on first connection (`accept-new`) and verified thereafter

### Access Control
- Bastion SSH access is limited to the CIDR ranges in `bastion_allowed_cidrs` (required; open-to-world is rejected by validation)
- SSM Session Manager is also available on all instances as an auditable, key-less alternative to SSH
- Use IAM roles for AWS service access
- Regularly rotate SSH keys
- Monitor access logs

### Monitoring and Alerting
- node_exporter metrics scraped by the Prometheus monitoring server
- Alerting via Prometheus/Alertmanager → SNS (see MONITORING.md)
- Regular health checks and status monitoring

## Troubleshooting

### Common Issues

#### Cannot Connect to Bastion Host
1. Check security group allows your IP
2. Verify SSH key is correct
3. Check bastion host is running in AWS console

#### Cannot Connect to Private Servers from Bastion
1. Check private server security groups allow bastion access
2. Verify bastion host has proper network connectivity
3. Check if target servers are running

#### Virtual Host Changes Not Syncing
1. Check the sync timer: `ssh web1 "sudo systemctl status vhost-sync.timer"`
2. Check the last sync run: `ssh web1 "sudo journalctl -u vhost-sync.service -n 20"`
3. Manual sync: `vhost sync`
4. Check EFS mount: `ssh web1 "mountpoint /var/www/shared"`

#### Database Connection Issues
1. Check MariaDB service: `ssh db1 "sudo systemctl status mariadb"`
2. Check network connectivity: `ssh db1 "ping 10.0.22.10"`
3. Verify replication status: `mysql -h 10.0.21.10 -u root -p -e "SHOW SLAVE STATUS\G"`

### Log Locations
- **Bastion logs**: `/var/log/management/`
- **SSH logs**: `/var/log/auth.log`
- **System logs**: `/var/log/syslog`

## Tools and Scripts Location

All management tools are located in `/opt/management-tools/`:
- `connect-web.sh` - Interactive web server connection
- `connect-db.sh` - Interactive database server connection  
- `mysql-connect.sh` - Interactive MySQL connection
- `vhost-remote.sh` - Virtual host management
- `check-infrastructure.sh` - Infrastructure health check

These scripts are also available as command aliases for convenient access.