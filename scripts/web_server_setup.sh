#!/bin/bash
set -e

# Update system
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Install Apache, PHP, and EFS utilities
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apache2 \
    php8.1 \
    php8.1-cli \
    php8.1-common \
    php8.1-mysql \
    php8.1-zip \
    php8.1-gd \
    php8.1-mbstring \
    php8.1-curl \
    php8.1-xml \
    php8.1-bcmath \
    libapache2-mod-php8.1 \
    nfs-common \
    awscli \
    jq \
    inotify-tools

# Enable Apache modules
a2enmod rewrite
a2enmod ssl
a2enmod headers
a2enmod vhost_alias

# Create mount points for EFS
mkdir -p /var/www/vhosts
mkdir -p /var/www/shared

# Mount EFS file system
echo "${efs_id}.efs.${region}.amazonaws.com:/ /var/www/shared nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,intr,timeo=600,retrans=2 0 0" >> /etc/fstab
mount -a

# Create EFS directory structure if it doesn't exist
if [ ! -d /var/www/shared/vhosts ]; then
    mkdir -p /var/www/shared/vhosts
    mkdir -p /var/www/shared/vhost-configs
    mkdir -p /var/www/shared/ssl-certs
fi

# Create symlink for local vhosts directory
ln -sf /var/www/shared/vhosts /var/www/vhosts

# Set proper permissions
chown -R www-data:www-data /var/www/shared
chmod -R 755 /var/www/shared

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
    
    ErrorLog ${APACHE_LOG_DIR}/default_error.log
    CustomLog ${APACHE_LOG_DIR}/default_access.log combined
    
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
# Usage: ./create-vhost.sh <domain> [ssl] [email]

DOMAIN=$1
SSL_ENABLED=$2
EMAIL=$3

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 <domain> [ssl] [email]"
    echo "Example: $0 example.com ssl admin@example.com"
    exit 1
fi

# Sanitize domain name
SAFE_DOMAIN=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9.-]//g')
VHOST_DIR="/var/www/shared/vhosts/$SAFE_DOMAIN"
CONFIG_FILE="/var/www/shared/vhost-configs/$SAFE_DOMAIN.conf"

echo "Creating virtual host for: $DOMAIN"

# Create vhost directory structure
mkdir -p "$VHOST_DIR"
mkdir -p "$VHOST_DIR/public_html"
mkdir -p "$VHOST_DIR/logs"

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
if [ "$SSL_ENABLED" = "ssl" ]; then
    cat > "$CONFIG_FILE" << CONFEOF
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot $VHOST_DIR/public_html
    
    ErrorLog $VHOST_DIR/logs/error.log
    CustomLog $VHOST_DIR/logs/access.log combined
    
    # Redirect HTTP to HTTPS
    Redirect permanent / https://$DOMAIN/
</VirtualHost>

<VirtualHost *:443>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot $VHOST_DIR/public_html
    
    ErrorLog $VHOST_DIR/logs/ssl_error.log
    CustomLog $VHOST_DIR/logs/ssl_access.log combined
    
    SSLEngine on
    SSLCertificateFile /var/www/shared/ssl-certs/$DOMAIN.crt
    SSLCertificateKeyFile /var/www/shared/ssl-certs/$DOMAIN.key
    
    <Directory $VHOST_DIR/public_html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
CONFEOF
else
    cat > "$CONFIG_FILE" << CONFEOF
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot $VHOST_DIR/public_html
    
    ErrorLog $VHOST_DIR/logs/error.log
    CustomLog $VHOST_DIR/logs/access.log combined
    
    <Directory $VHOST_DIR/public_html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
CONFEOF
fi

echo "Virtual host configuration created at: $CONFIG_FILE"
echo "Document root: $VHOST_DIR/public_html"
echo ""
echo "To enable this vhost on all servers, run:"
echo "sudo /usr/local/bin/vhost-manager/sync-vhosts.sh"
EOL

# Create vhost synchronization script
cat > /usr/local/bin/vhost-manager/sync-vhosts.sh << 'EOL'
#!/bin/bash

# Virtual Host Synchronization Script
# This script syncs vhost configurations from EFS to local Apache

VHOST_CONFIG_DIR="/var/www/shared/vhost-configs"
APACHE_SITES_DIR="/etc/apache2/sites-available"

echo "Synchronizing virtual hosts..."

# Remove old symlinks
find "$APACHE_SITES_DIR" -name "vhost-*.conf" -type l -delete

# Create symlinks for all vhost configs in EFS
for config_file in "$VHOST_CONFIG_DIR"/*.conf; do
    if [ -f "$config_file" ]; then
        filename=$(basename "$config_file")
        domain=$(echo "$filename" | sed 's/\.conf$//')
        link_name="vhost-$domain.conf"
        
        echo "Linking $filename to $link_name"
        ln -sf "$config_file" "$APACHE_SITES_DIR/$link_name"
        
        # Enable the site
        a2ensite "$link_name"
    fi
done

# Test Apache configuration
if apache2ctl configtest; then
    echo "Apache configuration is valid. Reloading..."
    systemctl reload apache2
    echo "Virtual hosts synchronized successfully!"
else
    echo "Apache configuration test failed. Please check the configurations."
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
# Usage: ./remove-vhost.sh <domain>

DOMAIN=$1

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 <domain>"
    echo "Example: $0 example.com"
    exit 1
fi

SAFE_DOMAIN=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9.-]//g')
VHOST_DIR="/var/www/shared/vhosts/$SAFE_DOMAIN"
CONFIG_FILE="/var/www/shared/vhost-configs/$SAFE_DOMAIN.conf"
APACHE_LINK="/etc/apache2/sites-available/vhost-$SAFE_DOMAIN.conf"

echo "Removing virtual host for: $DOMAIN"

# Disable Apache site
if [ -f "$APACHE_LINK" ]; then
    a2dissite "vhost-$SAFE_DOMAIN.conf"
    rm -f "$APACHE_LINK"
fi

# Remove configuration
if [ -f "$CONFIG_FILE" ]; then
    rm -f "$CONFIG_FILE"
    echo "Removed configuration file: $CONFIG_FILE"
fi

# Ask before removing content
read -p "Do you want to remove the website content in $VHOST_DIR? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$VHOST_DIR"
    echo "Removed website content: $VHOST_DIR"
else
    echo "Website content preserved: $VHOST_DIR"
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
        echo "  create <domain> [ssl] [email]  - Create a new virtual host"
        echo "  sync                           - Synchronize vhosts across servers"
        echo "  list                           - List all virtual hosts"
        echo "  remove <domain>                - Remove a virtual host"
        echo ""
        echo "Examples:"
        echo "  vhost create example.com"
        echo "  vhost create secure.com ssl admin@secure.com"
        echo "  vhost sync"
        echo "  vhost list"
        echo "  vhost remove example.com"
        exit 1
        ;;
esac
EOL

chmod +x /usr/local/bin/vhost

# Create vhost watcher service for automatic synchronization
cat > /etc/systemd/system/vhost-watcher.service << 'EOL'
[Unit]
Description=Virtual Host Configuration Watcher
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/vhost-manager/vhost-watcher.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

# Create the watcher script
cat > /usr/local/bin/vhost-manager/vhost-watcher.sh << 'EOL'
#!/bin/bash

# Watch for changes in vhost configurations and auto-sync

WATCH_DIR="/var/www/shared/vhost-configs"

echo "Starting vhost configuration watcher..."
echo "Watching directory: $WATCH_DIR"

# Initial sync
/usr/local/bin/vhost-manager/sync-vhosts.sh

# Watch for changes
inotifywait -m -r -e create,delete,modify,move "$WATCH_DIR" --format '%w%f %e' |
while read FILE EVENT; do
    echo "Detected change: $EVENT on $FILE"
    if [[ "$FILE" == *.conf ]]; then
        echo "Virtual host configuration changed, syncing..."
        sleep 2  # Brief delay to ensure file is completely written
        /usr/local/bin/vhost-manager/sync-vhosts.sh
    fi
done
EOL

chmod +x /usr/local/bin/vhost-manager/vhost-watcher.sh

# Enable and start the watcher service
systemctl enable vhost-watcher
systemctl start vhost-watcher

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