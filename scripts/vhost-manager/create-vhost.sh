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
if [ -z "$SAFE_DOMAIN" ]; then
    echo "Error: domain contains no usable characters after sanitizing."
    exit 1
fi
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
/usr/local/bin/vhost-manager/sync-vhosts.sh --force
