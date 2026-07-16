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
if [ -z "$SAFE_DOMAIN" ]; then
    echo "Error: domain contains no usable characters after sanitizing."
    exit 1
fi
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

# Reload Apache and refresh the sync state
/usr/local/bin/vhost-manager/sync-vhosts.sh --force
echo "Virtual host removed and Apache reloaded."
