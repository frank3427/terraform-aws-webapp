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
