#!/bin/bash
set -e

# Update system
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Install Apache, PHP, and EFS utilities
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apache2 \
    php \
    php-cli \
    php-common \
    php-mysql \
    php-zip \
    php-gd \
    php-mbstring \
    php-curl \
    php-xml \
    php-bcmath \
    libapache2-mod-php \
    nfs-common \
    jq

# Install AWS CLI v2 (awscli deb was removed from the Ubuntu archive in 24.04+)
snap install aws-cli --classic

# Enable Apache modules
a2enmod rewrite
a2enmod headers
a2enmod vhost_alias
a2enmod remoteip

# Trust X-Forwarded-For from the ALB so logs show real client IPs
cat > /etc/apache2/conf-available/remoteip-alb.conf << 'EOL'
RemoteIPHeader X-Forwarded-For
RemoteIPInternalProxy 10.0.0.0/16
EOL
a2enconf remoteip-alb

# ---------------------------------------------------------------------------
# Security hardening
# ---------------------------------------------------------------------------

# Don't advertise server software/version details
cat > /etc/apache2/conf-available/security-hardening.conf << 'EOL'
ServerTokens Prod
ServerSignature Off
TraceEnable Off

# Baseline security headers for all vhosts
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set Referrer-Policy "strict-origin-when-cross-origin"

# HSTS, only on requests that arrived over HTTPS at the load balancer
Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains" "expr=%%{HTTP:X-Forwarded-Proto} == 'https'"
EOL
a2enconf security-hardening

# Hide PHP version and disable remote code inclusion
for ini in /etc/php/*/apache2/php.ini /etc/php/*/cli/php.ini; do
    [ -f "$ini" ] || continue
    sed -i 's/^expose_php = On/expose_php = Off/' "$ini"
    sed -i 's/^allow_url_include = On/allow_url_include = Off/' "$ini"
done

# Create mount point for EFS
mkdir -p /var/www/shared

# Mount EFS file system
echo "${efs_id}.efs.${region}.amazonaws.com:/ /var/www/shared nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 0 0" >> /etc/fstab
mount -a

# Create EFS directory structure if it doesn't exist
if [ ! -d /var/www/shared/vhosts ]; then
    mkdir -p /var/www/shared/vhosts
    mkdir -p /var/www/shared/vhost-configs
fi

# Create symlink for local vhosts directory
# -n treats an existing directory symlink as a file so the link is replaced,
# not created inside it
ln -sfn /var/www/shared/vhosts /var/www/vhosts

# Set proper permissions on web content
chown -R www-data:www-data /var/www/shared/vhosts
chmod -R 755 /var/www/shared/vhosts

# Create default vhost if it doesn't exist
if [ ! -d /var/www/shared/vhosts/default ]; then
    mkdir -p /var/www/shared/vhosts/default
    cat > /var/www/shared/vhosts/default/index.php << 'EOL'
<?php
echo "<h1>Web Server: " . gethostname() . "</h1>";
echo "<h2>Server Information</h2>";
phpinfo();
?>
EOL
    chown -R www-data:www-data /var/www/shared/vhosts/default
fi

# Disable default Apache site
a2dissite 000-default

# Create default virtual host configuration
cat > /etc/apache2/sites-available/000-default-vhost.conf << 'EOL'
<VirtualHost *:80>
    ServerName default.local
    DocumentRoot /var/www/vhosts/default
    
    ErrorLog $${APACHE_LOG_DIR}/default_error.log
    CustomLog $${APACHE_LOG_DIR}/default_access.log combined
    
    <Directory /var/www/vhosts/default>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOL

# Enable the default vhost
a2ensite 000-default-vhost

# Create vhost management directory
mkdir -p /usr/local/bin/vhost-manager

# Create vhost management script
cat > /usr/local/bin/vhost-manager/create-vhost.sh << 'EOL'
#!/bin/bash

# Virtual Host Creation Script
# Usage: ./create-vhost.sh <domain> [admin-email]
#
# TLS is terminated at the load balancer (ACM certificate), so all
# instance-level vhosts listen on port 80 only.

DOMAIN=$1
ADMIN_EMAIL=$2

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 <domain> [admin-email]"
    echo "Example: $0 example.com admin@example.com"
    exit 1
fi

# Sanitize domain name
SAFE_DOMAIN=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9.-]//g')
VHOST_DIR="/var/www/shared/vhosts/$SAFE_DOMAIN"
CONFIG_FILE="/var/www/shared/vhost-configs/$SAFE_DOMAIN.conf"

echo "Creating virtual host for: $DOMAIN"

# Create vhost directory structure
mkdir -p "$VHOST_DIR/public_html"

# Create default index.php
cat > "$VHOST_DIR/public_html/index.php" << INDEXEOF
<?php
echo "<h1>Welcome to $DOMAIN</h1>";
echo "<p>Virtual host is working correctly!</p>";
echo "<p>Server: " . gethostname() . "</p>";
echo "<p>Document Root: " . __DIR__ . "</p>";
?>
INDEXEOF

# Set permissions
chown -R www-data:www-data "$VHOST_DIR"
chmod -R 755 "$VHOST_DIR"

# Create Apache configuration
# Logs are written to local disk (not EFS) because multiple servers writing
# to the same NFS log file interleaves and corrupts entries. Local logs are
# rotated by the /etc/logrotate.d/apache2-custom policy.
cat > "$CONFIG_FILE" << CONFEOF
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    $([ -n "$ADMIN_EMAIL" ] && echo "ServerAdmin $ADMIN_EMAIL")
    DocumentRoot $VHOST_DIR/public_html

    ErrorLog /var/log/apache2/$SAFE_DOMAIN-error.log
    CustomLog /var/log/apache2/$SAFE_DOMAIN-access.log combined

    <Directory $VHOST_DIR/public_html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
CONFEOF

echo "Virtual host configuration created at: $CONFIG_FILE"
echo "Document root: $VHOST_DIR/public_html"
echo ""
echo "This server will pick it up immediately; the other web servers"
echo "sync automatically within one minute (vhost-sync.timer)."
/usr/local/bin/vhost-manager/sync-vhosts.sh
EOL

# Create vhost synchronization script
cat > /usr/local/bin/vhost-manager/sync-vhosts.sh << 'EOL'
#!/bin/bash

# Virtual Host Synchronization Script
# This script syncs vhost configurations from EFS to local Apache.
# It is idempotent and safe to run repeatedly (vhost-sync.timer runs it
# every minute on every web server).

VHOST_CONFIG_DIR="/var/www/shared/vhost-configs"
APACHE_SITES_DIR="/etc/apache2/sites-available"
APACHE_ENABLED_DIR="/etc/apache2/sites-enabled"

# Refuse to run if EFS is not mounted, otherwise we would tear down
# every vhost just because the share was briefly unavailable
if ! mountpoint -q /var/www/shared; then
    echo "EFS is not mounted at /var/www/shared; skipping sync."
    exit 1
fi

echo "Synchronizing virtual hosts..."

# Remove old symlinks in sites-available
find "$APACHE_SITES_DIR" -name "vhost-*.conf" -type l -delete

# Remove dangling symlinks in sites-enabled left behind by removed vhosts;
# a dangling include makes apache2ctl configtest fail and blocks reloads
find "$APACHE_ENABLED_DIR" -xtype l -delete

# Create symlinks for all vhost configs in EFS
for config_file in "$VHOST_CONFIG_DIR"/*.conf; do
    if [ -f "$config_file" ]; then
        filename=$(basename "$config_file")
        domain=$(echo "$filename" | sed 's/\.conf$//')
        link_name="vhost-$domain.conf"

        ln -sf "$config_file" "$APACHE_SITES_DIR/$link_name"

        # Enable the site (quiet: it is usually already enabled)
        a2ensite -q "$link_name" > /dev/null
    fi
done

# Test Apache configuration
if apache2ctl configtest > /dev/null 2>&1; then
    systemctl reload apache2
    echo "Virtual hosts synchronized successfully!"
else
    echo "Apache configuration test failed. Please check the configurations:"
    apache2ctl configtest
    exit 1
fi
EOL

# Create vhost listing script
cat > /usr/local/bin/vhost-manager/list-vhosts.sh << 'EOL'
#!/bin/bash

# List all virtual hosts

echo "=== Available Virtual Hosts ==="
echo ""

VHOST_DIR="/var/www/shared/vhosts"
CONFIG_DIR="/var/www/shared/vhost-configs"

if [ -d "$VHOST_DIR" ]; then
    for vhost in "$VHOST_DIR"/*; do
        if [ -d "$vhost" ]; then
            domain=$(basename "$vhost")
            config_file="$CONFIG_DIR/$domain.conf"
            
            echo "Domain: $domain"
            echo "  Document Root: $vhost/public_html"
            echo "  Configuration: $config_file"
            
            if [ -f "$config_file" ]; then
                if grep -q "SSLEngine on" "$config_file"; then
                    echo "  SSL: Enabled"
                else
                    echo "  SSL: Disabled"
                fi
            else
                echo "  Status: Configuration missing"
            fi
            
            if apache2ctl -S 2>/dev/null | grep -q "$domain"; then
                echo "  Apache Status: Enabled"
            else
                echo "  Apache Status: Disabled"
            fi
            
            echo ""
        fi
    done
else
    echo "No virtual hosts directory found."
fi
EOL

# Create vhost removal script
cat > /usr/local/bin/vhost-manager/remove-vhost.sh << 'EOL'
#!/bin/bash

# Virtual Host Removal Script
# Usage: ./remove-vhost.sh <domain> [--purge]
#
# By default website content is PRESERVED. Pass --purge to also delete
# the content directory, or answer the interactive prompt.

DOMAIN=$1
PURGE=$2

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 <domain> [--purge]"
    echo "Example: $0 example.com"
    exit 1
fi

SAFE_DOMAIN=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9.-]//g')
VHOST_DIR="/var/www/shared/vhosts/$SAFE_DOMAIN"
CONFIG_FILE="/var/www/shared/vhost-configs/$SAFE_DOMAIN.conf"
APACHE_LINK="/etc/apache2/sites-available/vhost-$SAFE_DOMAIN.conf"

echo "Removing virtual host for: $DOMAIN"

# Disable Apache site on this server
if [ -f "$APACHE_LINK" ] || [ -L "$APACHE_LINK" ]; then
    a2dissite -q "vhost-$SAFE_DOMAIN.conf" > /dev/null 2>&1
    rm -f "$APACHE_LINK"
fi

# Remove configuration from EFS (other servers clean up on their next
# vhost-sync.timer run, within one minute)
if [ -f "$CONFIG_FILE" ]; then
    rm -f "$CONFIG_FILE"
    echo "Removed configuration file: $CONFIG_FILE"
fi

# Decide whether to remove content
REMOVE_CONTENT="no"
if [ "$PURGE" = "--purge" ]; then
    REMOVE_CONTENT="yes"
elif [ -t 0 ]; then
    read -p "Do you want to remove the website content in $VHOST_DIR? (y/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] && REMOVE_CONTENT="yes"
fi

if [ "$REMOVE_CONTENT" = "yes" ]; then
    rm -rf "$VHOST_DIR"
    echo "Removed website content: $VHOST_DIR"
else
    echo "Website content preserved: $VHOST_DIR"
    echo "(run with --purge to delete it)"
fi

# Reload Apache
systemctl reload apache2
echo "Virtual host removed and Apache reloaded."
EOL

# Make all scripts executable
chmod +x /usr/local/bin/vhost-manager/*.sh

# Create main vhost management command
cat > /usr/local/bin/vhost << 'EOL'
#!/bin/bash

# Main vhost management command

case "$1" in
    create)
        shift
        /usr/local/bin/vhost-manager/create-vhost.sh "$@"
        ;;
    sync)
        /usr/local/bin/vhost-manager/sync-vhosts.sh
        ;;
    list)
        /usr/local/bin/vhost-manager/list-vhosts.sh
        ;;
    remove)
        shift
        /usr/local/bin/vhost-manager/remove-vhost.sh "$@"
        ;;
    *)
        echo "Usage: vhost {create|sync|list|remove}"
        echo ""
        echo "Commands:"
        echo "  create <domain> [admin-email]  - Create a new virtual host"
        echo "  sync                           - Synchronize vhosts from EFS to this server"
        echo "  list                           - List all virtual hosts"
        echo "  remove <domain> [--purge]      - Remove a virtual host (--purge deletes content)"
        echo ""
        echo "TLS is terminated at the load balancer (ACM); vhosts serve HTTP on port 80."
        echo "Other web servers pick up changes automatically within one minute."
        echo ""
        echo "Examples:"
        echo "  vhost create example.com"
        echo "  vhost create example.com admin@example.com"
        echo "  vhost sync"
        echo "  vhost list"
        echo "  vhost remove example.com"
        exit 1
        ;;
esac
EOL

chmod +x /usr/local/bin/vhost

# Create vhost sync timer for automatic synchronization.
#
# NOTE: inotify cannot be used here. inotify only reports changes made by
# the local NFS client; edits made on *other* web servers (or via EFS
# directly) never generate events. A short polling interval is the reliable
# way to converge all servers on the shared configuration.
cat > /etc/systemd/system/vhost-sync.service << 'EOL'
[Unit]
Description=Synchronize Apache virtual hosts from EFS
RequiresMountsFor=/var/www/shared
After=remote-fs.target apache2.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vhost-manager/sync-vhosts.sh
EOL

cat > /etc/systemd/system/vhost-sync.timer << 'EOL'
[Unit]
Description=Run vhost sync every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOL

# Enable and start the sync timer
systemctl daemon-reload
systemctl enable --now vhost-sync.timer

# Initial vhost sync
/usr/local/bin/vhost-manager/sync-vhosts.sh

# Install CloudWatch agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E ./amazon-cloudwatch-agent.deb

# Configure log rotation
cat > /etc/logrotate.d/apache2-custom << 'EOL'
/var/log/apache2/*.log {
    weekly
    missingok
    rotate 52
    compress
    delaycompress
    notifempty
    create 640 root adm
    sharedscripts
    postrotate
        systemctl reload apache2
    endscript
}
EOL

echo "Web server setup completed successfully"