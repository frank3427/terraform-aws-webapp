#!/bin/bash

# Virtual Host Synchronization Script
# Syncs vhost configurations from EFS to local Apache.
# Idempotent and safe to run repeatedly (vhost-sync.timer runs it every
# minute on every web server).
#
# To avoid reloading Apache 1,440 times a day for no reason, the script
# hashes the desired state (EFS configs) plus the actual local state
# (symlinks) and exits early when nothing changed since the last
# successful sync. Pass --force to skip the check (used by `vhost sync`).

VHOST_CONFIG_DIR="/var/www/shared/vhost-configs"
APACHE_SITES_DIR="/etc/apache2/sites-available"
APACHE_ENABLED_DIR="/etc/apache2/sites-enabled"
STATE_FILE="/var/lib/vhost-sync.state"

# Refuse to run if EFS is not mounted, otherwise we would tear down
# every vhost just because the share was briefly unavailable
if ! mountpoint -q /var/www/shared; then
    echo "EFS is not mounted at /var/www/shared; skipping sync."
    exit 1
fi

# Fingerprint of desired state (EFS config contents) and actual state
# (local symlinks, including dangling ones). Any drift changes the hash.
compute_state() {
    {
        find "$VHOST_CONFIG_DIR" -maxdepth 1 -name '*.conf' -type f -print0 2>/dev/null \
            | sort -z | xargs -0r sha256sum
        find "$APACHE_SITES_DIR" "$APACHE_ENABLED_DIR" -maxdepth 1 -name 'vhost-*.conf' 2>/dev/null | sort
        find "$APACHE_ENABLED_DIR" -maxdepth 1 -xtype l 2>/dev/null | sort
    } | sha256sum | awk '{print $1}'
}

CURRENT_STATE=$(compute_state)
if [ "$1" != "--force" ] && [ -f "$STATE_FILE" ] \
    && [ "$(cat "$STATE_FILE")" = "$CURRENT_STATE" ]; then
    # Nothing changed since the last successful sync; skip the reload.
    exit 0
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
    # Record the state we just converged to so unchanged runs can skip
    compute_state > "$STATE_FILE"
    echo "Virtual hosts synchronized successfully!"
else
    echo "Apache configuration test failed. Please check the configurations:"
    apache2ctl configtest
    rm -f "$STATE_FILE"
    exit 1
fi
