# Virtual Host Management Guide

This document provides detailed instructions for managing Apache virtual hosts in your AWS web application infrastructure.

## Overview

The infrastructure includes an automated virtual host management system that:
- Stores all website content and configurations on EFS (shared across all servers)
- Automatically synchronizes Apache configurations across all web servers (within one minute; Apache is only reloaded when something actually changed)
- Provides simple command-line tools for virtual host management
- Terminates HTTPS at the load balancer using AWS Certificate Manager (ACM)
- Survives instance turnover: web servers are an Auto Scaling Group, and every new instance installs the vhost tooling at boot and converges on the shared EFS configuration within a minute

## Architecture

```
                         Internet
                            │
              ┌─────────────┴─────────────┐
              │  Application Load Balancer │
              │  :443 HTTPS (ACM cert)     │
              │  :80  HTTP → 301 to HTTPS  │
              └─────────────┬─────────────┘
                     HTTP :80 (internal)
                            │
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│ Web Server 1│  │ Web Server 2│  │ Web Server 3│
│             │  │             │  │             │
│ vhost-sync  │  │ vhost-sync  │  │ vhost-sync  │
│ timer (1min)│  │ timer (1min)│  │ timer (1min)│
└──────┬──────┘  └──────┬──────┘  └──────┬──────┘
       └────────────────┼────────────────┘
                 NFS Mount (2049)
                        │
┌─────────────────────────────────────────────────┐
│                 EFS File System                  │
│  /var/www/shared/                                │
│  ├── vhosts/           # Website content         │
│  └── vhost-configs/    # Apache configurations   │
└─────────────────────────────────────────────────┘
```

TLS is terminated at the ALB. Instances only ever serve plain HTTP on
port 80, so there are no certificates or private keys on the servers or
on EFS. Applications that need to know the original scheme should check
the `X-Forwarded-Proto` header (set to `https` by the ALB).

## HTTPS Setup

1. Request (or import) a certificate in **AWS Certificate Manager** in the
   same region as the ALB. For multiple sites, add each domain to the
   certificate as a Subject Alternative Name, or use a wildcard.
2. Set the certificate ARN in `terraform.tfvars`:
   ```hcl
   acm_certificate_arn = "arn:aws:acm:us-west-2:123456789012:certificate/xxxx"
   ```
3. Run `terraform apply`. The ALB will serve HTTPS on 443 and redirect all
   HTTP traffic to HTTPS automatically.
4. Point your domains' DNS at the ALB (alias/CNAME to the
   `load_balancer_dns` output).

ACM renews its certificates automatically — there is no certbot, no cron,
and nothing to copy between servers.

To add a new domain later: add it to the ACM certificate (or issue a new
certificate and update `acm_certificate_arn`), then create the vhost as
described below.

## Command Reference

### Basic Commands

All virtual host management is done through the `vhost` command on any web
server:

```bash
vhost {create|sync|list|remove}
```

### Creating Virtual Hosts

```bash
sudo vhost create example.com
sudo vhost create example.com admin@example.com   # sets ServerAdmin
```

This creates:
- Directory: `/var/www/shared/vhosts/example.com/`
- Document root: `/var/www/shared/vhosts/example.com/public_html/`
- Configuration: `/var/www/shared/vhost-configs/example.com.conf`
- Default index.php with server information

The server you ran the command on picks the vhost up immediately; the
other web servers sync automatically within one minute.

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
  Apache Status: Enabled
```

### Synchronizing Virtual Hosts

Synchronization is automatic: every web server runs a `vhost-sync.timer`
systemd timer that applies the shared configuration once per minute. To
apply changes immediately on the current server:

```bash
sudo vhost sync
```

The sync:
- Exits immediately (no Apache reload) if nothing changed since the last
  successful sync — a state hash of the shared configs and local symlinks
  is kept in `/var/lib/vhost-sync.state`. `vhost sync` bypasses the check
  (`--force`); the every-minute timer uses it, so Apache is only reloaded
  when a vhost actually changed
- Scans `/var/www/shared/vhost-configs/` for configuration files
- Creates symlinks in `/etc/apache2/sites-available/` and enables them
- Cleans up links for vhosts that have been removed
- Tests the Apache configuration and reloads Apache if it is valid
- Skips (and reports) if the EFS mount is unavailable

The vhost-manager scripts are versioned in the repo under
`scripts/vhost-manager/` and installed at boot from the provisioning S3
bucket (see `provisioning.tf`). Script changes ship on the next
`terraform apply` for newly launched instances; update running servers by
re-copying via SSM or the bastion.

> **Why a timer instead of file-watching?** inotify only sees changes made
> by the local machine — changes written by *other* NFS clients never
> generate events. Polling is the reliable way to keep every server
> converged on the shared configuration.

### Removing Virtual Hosts

```bash
sudo vhost remove example.com            # keeps website content
sudo vhost remove example.com --purge    # also deletes website content
```

This disables the site, removes the shared configuration file, and reloads
Apache. Other servers stop serving the vhost on their next timer run
(within one minute). **Website content is preserved unless you pass
`--purge` or confirm the interactive prompt** — content deletion is
irreversible and affects all servers, since content lives on shared EFS.

## Directory Structure

### EFS Root: /var/www/shared/

```
/var/www/shared/
├── vhosts/                    # Website content directories
│   ├── default/               # Default virtual host (unmatched domains)
│   │   └── index.php
│   └── example.com/
│       └── public_html/       # Document root for example.com
│           ├── index.php
│           ├── .htaccess
│           └── assets/
└── vhost-configs/             # Apache configuration files
    ├── default.conf
    └── example.com.conf
```

### Logs Are Local, Not on EFS

Per-vhost Apache logs are written to the local disk of each web server at
`/var/log/apache2/<domain>-access.log` and `<domain>-error.log`, not to
EFS. Multiple servers appending to the same NFS file interleaves and
corrupts log lines, so each server keeps its own. Local logs are rotated
weekly by logrotate. To view traffic for a domain across the fleet, check
each server (or ship logs to CloudWatch Logs).

Client IPs in the logs are the real client addresses: Apache is configured
with `mod_remoteip` to trust `X-Forwarded-For` from the ALB.

## Automatic Synchronization

### vhost-sync.timer

Each web server runs a systemd timer that executes the sync script one
minute after boot and every minute thereafter. The service unit declares
`RequiresMountsFor=/var/www/shared`, so it never runs before EFS is
mounted.

Check timer status:
```bash
sudo systemctl status vhost-sync.timer
sudo systemctl list-timers vhost-sync.timer
```

View sync logs:
```bash
sudo journalctl -u vhost-sync.service -f
```

### Manual Synchronization

```bash
# On each web server
sudo vhost sync
```

## Remote Management

Use the `vhost-helper.sh` script for remote management from your local
machine, or the equivalent tooling pre-installed on the bastion host.

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

# Create with an admin email (ServerAdmin)
./scripts/vhost-helper.sh create newsite.com admin@newsite.com

# List virtual hosts
./scripts/vhost-helper.sh list

# Remove virtual host (content preserved)
./scripts/vhost-helper.sh remove oldsite.com

# Remove virtual host AND delete its content — irreversible!
./scripts/vhost-helper.sh remove oldsite.com --purge

# Force immediate synchronization on all servers
./scripts/vhost-helper.sh sync

# Check sync timer and Apache status
./scripts/vhost-helper.sh status
```

## Troubleshooting

### Common Issues

1. **Virtual host not appearing**
   - Wait one minute (timer interval), or run `sudo vhost sync` manually
   - Check if configuration exists: `ls /var/www/shared/vhost-configs/`
   - Check Apache syntax: `sudo apache2ctl configtest`
   - Check the last sync run: `sudo journalctl -u vhost-sync.service -n 20`

2. **EFS mount issues**
   - Check mount: `mountpoint /var/www/shared` or `df -h | grep shared`
   - Remount if needed: `sudo mount -a`
   - Check EFS security groups (NFS 2049 from web servers)
   - Note: sync intentionally refuses to run while EFS is unmounted, so a
     mount outage will not tear down existing vhosts

3. **Permission issues**
   - Fix ownership: `sudo chown -R www-data:www-data /var/www/shared/vhosts/`
   - Fix permissions: `sudo chmod -R 755 /var/www/shared/vhosts/`

4. **HTTPS issues**
   - Verify the ACM certificate covers the domain (check SANs)
   - Verify `acm_certificate_arn` is set and `terraform apply` has run
   - Confirm DNS points at the ALB, not at an instance
   - Remember: `curl https://<instance-ip>` will fail by design — TLS only
     exists at the ALB

### Log Files

- **Apache error logs**: `/var/log/apache2/error.log`
- **Per-vhost logs**: `/var/log/apache2/<domain>-{access,error}.log` (local to each server)
- **Sync logs**: `sudo journalctl -u vhost-sync.service`
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
3. **EFS backups are automatic** via AWS Backup (`aws_efs_backup_policy`) — verify restore procedures periodically
4. **Be careful with `--purge`** — content deletion is shared across all servers and irreversible
5. **Keep certificates in ACM** — never place private keys on EFS or instances
6. **Monitor the sync timer** (`systemctl list-timers`) to ensure automatic synchronization works

## Advanced Configuration

### Custom Apache Configurations

To add custom Apache directives to a virtual host:

1. Create the virtual host normally
2. Edit the configuration file directly:
```bash
sudo nano /var/www/shared/vhost-configs/example.com.conf
```
3. Add custom directives within the VirtualHost block
4. Changes apply locally on the next `vhost sync` and on all other servers
   within one minute

### Detecting HTTPS in Applications

Because TLS terminates at the ALB, PHP applications should trust the
forwarded scheme header rather than `$_SERVER['HTTPS']`:

```php
$isHttps = ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';
```

### Load Balancer Health Checks

The load balancer probes `/healthz` on each server over HTTP. The path is
an Apache alias to a static file on the instance's local disk — deliberately
independent of EFS and PHP, so a shared-storage stall can't fail health
checks fleet-wide. Verify on a server:

```bash
curl http://localhost/healthz    # expect: OK
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

Remember to also add the new names to the ACM certificate so HTTPS covers
them. Changes synchronize across all servers within one minute.
