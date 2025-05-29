# Virtual Host Management Guide

This document provides detailed instructions for managing Apache virtual hosts in your AWS web application infrastructure.

## Overview

The infrastructure includes an automated virtual host management system that:
- Stores all website content and configurations on EFS (shared across all servers)
- Automatically synchronizes Apache configurations across all web servers
- Provides simple command-line tools for virtual host management
- Supports both HTTP and HTTPS virtual hosts
- Monitors configuration changes and auto-applies them

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     EFS File System                        │
│  /var/www/shared/                                           │
│  ├── vhosts/           # Website content                    │
│  ├── vhost-configs/    # Apache configurations             │
│  └── ssl-certs/        # SSL certificates                  │
└─────────────────────────────────────────────────────────────┘
                            │
                    NFS Mount (2049)
                            │
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│ Web Server 1│  │ Web Server 2│  │ Web Server 3│
│             │  │             │  │             │
│ vhost-      │  │ vhost-      │  │ vhost-      │
│ watcher     │  │ watcher     │  │ watcher     │
│ service     │  │ service     │  │ service     │
└─────────────┘  └─────────────┘  └─────────────┘
```

## Command Reference

### Basic Commands

All virtual host management is done through the `vhost` command:

```bash
vhost {create|sync|list|remove}
```

### Creating Virtual Hosts

#### HTTP Virtual Host
```bash
sudo vhost create example.com
```

This creates:
- Directory: `/var/www/shared/vhosts/example.com/`
- Document root: `/var/www/shared/vhosts/example.com/public_html/`
- Configuration: `/var/www/shared/vhost-configs/example.com.conf`
- Default index.php with server information

#### HTTPS Virtual Host
```bash
sudo vhost create secure.com ssl admin@secure.com
```

This creates an HTTPS virtual host with:
- HTTP to HTTPS redirect
- SSL configuration pointing to `/var/www/shared/ssl-certs/`
- Same directory structure as HTTP vhost

**Note**: You need to manually place SSL certificates in the ssl-certs directory.

### Listing Virtual Hosts
```bash
sudo vhost list
```

Sample output:
```
=== Available Virtual Hosts ===

Domain: example.com
  Document Root: /var/www/shared/vhosts/example.com/public_html
  Configuration: /var/www/shared/vhost-configs/example.com.conf
  SSL: Disabled
  Apache Status: Enabled

Domain: secure.com
  Document Root: /var/www/shared/vhosts/secure.com/public_html
  Configuration: /var/www/shared/vhost-configs/secure.com.conf
  SSL: Enabled
  Apache Status: Enabled
```

### Synchronizing Virtual Hosts
```bash
sudo vhost sync
```

This command:
- Scans `/var/www/shared/vhost-configs/` for configuration files
- Creates symlinks in `/etc/apache2/sites-available/`
- Enables all virtual host sites
- Tests Apache configuration
- Reloads Apache if configuration is valid

### Removing Virtual Hosts
```bash
sudo vhost remove example.com
```

This will:
- Disable the Apache site
- Remove the configuration file
- Ask if you want to remove website content
- Reload Apache

## Directory Structure

### EFS Root: /var/www/shared/

```
/var/www/shared/
├── vhosts/                    # Website content directories
│   ├── default/               # Default virtual host
│   │   └── index.php
│   ├── example.com/
│   │   ├── public_html/       # Document root for example.com
│   │   │   ├── index.php
│   │   │   ├── .htaccess
│   │   │   └── assets/
│   │   └── logs/              # Per-domain log files
│   │       ├── access.log
│   │       └── error.log
│   └── secure.com/
│       ├── public_html/
│       └── logs/
├── vhost-configs/             # Apache configuration files
│   ├── default.conf
│   ├── example.com.conf
│   └── secure.com.conf
└── ssl-certs/                 # SSL certificates
    ├── secure.com.crt
    ├── secure.com.key
    └── intermediate.crt
```

## SSL Certificate Management

### Adding SSL Certificates

1. **Upload certificates to EFS**:
```bash
# From any web server
sudo cp your-domain.crt /var/www/shared/ssl-certs/
sudo cp your-domain.key /var/www/shared/ssl-certs/
sudo chown www-data:www-data /var/www/shared/ssl-certs/*
sudo chmod 644 /var/www/shared/ssl-certs/*.crt
sudo chmod 600 /var/www/shared/ssl-certs/*.key
```

2. **Create or update virtual host with SSL**:
```bash
sudo vhost create your-domain.com ssl admin@your-domain.com
```

### Let's Encrypt Integration

For automated SSL certificate management, you can integrate with Let's Encrypt:

```bash
# Install certbot
sudo apt-get update
sudo apt-get install certbot python3-certbot-apache

# Get certificate
sudo certbot --apache -d your-domain.com -d www.your-domain.com

# Move certificates to EFS
sudo cp /etc/letsencrypt/live/your-domain.com/fullchain.pem /var/www/shared/ssl-certs/your-domain.com.crt
sudo cp /etc/letsencrypt/live/your-domain.com/privkey.pem /var/www/shared/ssl-certs/your-domain.com.key
```

## Automatic Synchronization

### vhost-watcher Service

Each web server runs a `vhost-watcher` service that:
- Monitors `/var/www/shared/vhost-configs/` for changes
- Automatically runs `vhost sync` when changes are detected
- Ensures all servers have the same virtual host configurations

Check service status:
```bash
sudo systemctl status vhost-watcher
```

View service logs:
```bash
sudo journalctl -u vhost-watcher -f
```

### Manual Synchronization

If automatic synchronization fails, manually sync on all servers:
```bash
# On each web server
sudo vhost sync
```

## Remote Management

Use the `vhost-helper.sh` script for remote management from your local machine.

### Setup

1. **Configure the script**:
```bash
# Edit vhost-helper.sh
WEB_SERVERS="10.0.11.10 10.0.12.10 10.0.13.10"  # Private IPs from Terraform output
SSH_KEY="/path/to/your-aws-key.pem"
JUMP_HOST="bastion-host-ip"  # Optional bastion host
```

2. **Make executable**:
```bash
chmod +x scripts/vhost-helper.sh
```

### Usage

```bash
# Create virtual host remotely
./scripts/vhost-helper.sh create newsite.com

# Create SSL virtual host remotely
./scripts/vhost-helper.sh create secure-site.com ssl admin@secure-site.com

# List virtual hosts
./scripts/vhost-helper.sh list

# Remove virtual host
./scripts/vhost-helper.sh remove oldsite.com

# Force synchronization
./scripts/vhost-helper.sh sync

# Check status
./scripts/vhost-helper.sh status
```

## Troubleshooting

### Common Issues

1. **Virtual host not appearing**
   - Check if configuration exists: `ls /var/www/shared/vhost-configs/`
   - Run manual sync: `sudo vhost sync`
   - Check Apache syntax: `sudo apache2ctl configtest`

2. **EFS mount issues**
   - Check mount: `df -h | grep shared`
   - Remount if needed: `sudo mount -a`
   - Check EFS security groups

3. **Permission issues**
   - Fix ownership: `sudo chown -R www-data:www-data /var/www/shared/`
   - Fix permissions: `sudo chmod -R 755 /var/www/shared/vhosts/`

4. **SSL certificate issues**
   - Check certificate files exist and have correct permissions
   - Verify certificate paths in vhost configuration
   - Test SSL configuration: `sudo apache2ctl configtest`

### Log Files

- **Apache error logs**: `/var/log/apache2/error.log`
- **Per-vhost logs**: `/var/www/shared/vhosts/[domain]/logs/`
- **vhost-watcher logs**: `sudo journalctl -u vhost-watcher`
- **System logs**: `/var/log/syslog`

### Checking Configuration

```bash
# List all enabled Apache sites
sudo apache2ctl -S

# Test Apache configuration
sudo apache2ctl configtest

# Check virtual host configuration
sudo apache2ctl -t -D DUMP_VHOSTS
```

## Best Practices

1. **Always use the vhost command** instead of manually editing Apache configurations
2. **Test configurations** before deploying to production
3. **Backup EFS regularly** - consider AWS Backup for EFS
4. **Monitor disk space** on EFS to avoid performance issues
5. **Use meaningful domain names** and organize content logically
6. **Keep SSL certificates updated** and automate renewal where possible
7. **Monitor vhost-watcher service** to ensure automatic synchronization works

## Advanced Configuration

### Custom Apache Configurations

To add custom Apache directives to a virtual host:

1. Create the virtual host normally
2. Edit the configuration file directly:
```bash
sudo nano /var/www/shared/vhost-configs/example.com.conf
```
3. Add custom directives within the VirtualHost block
4. The changes will automatically sync to all servers

### Load Balancer Health Checks

The load balancer performs health checks on `/` of each server. Ensure your default virtual host responds correctly:

```bash
# Check default vhost response
curl -H "Host: default.local" http://localhost/
```

### Multiple Domains per Virtual Host

To add additional domains to an existing virtual host:

```bash
# Edit the configuration
sudo nano /var/www/shared/vhost-configs/example.com.conf

# Add ServerAlias directives
ServerAlias subdomain.example.com
ServerAlias alternative-domain.com
```

Changes will automatically synchronize across all servers.