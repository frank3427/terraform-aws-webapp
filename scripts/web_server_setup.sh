#!/bin/bash
# Web server provisioning. Fetched from the provisioning S3 bucket and run
# by the user-data bootstrap, which exports:
#   EFS_ID  - EFS file system id to mount
#   REGION  - AWS region
# The vhost-manager scripts and lib/ helpers are staged by the bootstrap
# under /opt/provisioning/scripts/.
set -euo pipefail

: "${EFS_ID:?EFS_ID must be set by the bootstrap}"
: "${REGION:?REGION must be set by the bootstrap}"

source /opt/provisioning/scripts/lib/fetch-release.sh

# Update system
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Enable automatic security updates (instances are long-lived; launch-time
# patching alone leaves CVEs unpatched for the instance lifetime)
DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOL'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOL
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local << 'EOL'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOL

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
Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains" "expr=%{HTTP:X-Forwarded-Proto} == 'https'"
EOL
a2enconf security-hardening

# Hide PHP version and disable remote code inclusion
for ini in /etc/php/*/apache2/php.ini /etc/php/*/cli/php.ini; do
    [ -f "$ini" ] || continue
    sed -i 's/^expose_php = On/expose_php = Off/' "$ini"
    sed -i 's/^allow_url_include = On/allow_url_include = Off/' "$ini"
done

# ---------------------------------------------------------------------------
# PHP performance tuning for code served from EFS
#
# All vhost PHP files live on NFS. Without OPcache doing the heavy lifting,
# every request stats and re-reads scripts over the network. OPcache keeps
# compiled scripts in memory and only revalidates them every 60s, and a
# larger realpath cache avoids repeated path lookups against NFS.
# Deployed content changes appear within 60s (or run
# `systemctl reload apache2` to pick them up immediately).
# ---------------------------------------------------------------------------
for confdir in /etc/php/*/apache2/conf.d; do
    [ -d "$confdir" ] || continue
    cat > "$confdir/99-opcache-efs.ini" << 'EOL'
opcache.enable=1
opcache.memory_consumption=192
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
EOL
    cat > "$confdir/99-realpath-efs.ini" << 'EOL'
realpath_cache_size=4096K
realpath_cache_ttl=600
EOL
done

# ---------------------------------------------------------------------------
# Local-disk health check target. The ALB probes /healthz; it must not
# depend on EFS (or PHP), otherwise an EFS stall fails health checks on
# every instance simultaneously and the ALB drains the whole fleet.
# ---------------------------------------------------------------------------
mkdir -p /var/www/health
echo "OK" > /var/www/health/index.html
cat > /etc/apache2/conf-available/healthz.conf << 'EOL'
Alias /healthz /var/www/health/index.html
<Directory /var/www/health>
    Require all granted
</Directory>
EOL
a2enconf healthz

# Create mount point for EFS
mkdir -p /var/www/shared

# Mount EFS file system
echo "$EFS_ID.efs.$REGION.amazonaws.com:/ /var/www/shared nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 0 0" >> /etc/fstab
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

# Create default vhost if it doesn't exist.
# This page answers any request that doesn't match a configured domain
# (including internet scanners hitting the ALB DNS name directly), so it
# must reveal nothing about the stack. Never use phpinfo() here.
# (ALB health checks hit /healthz, served from local disk above.)
if [ ! -d /var/www/shared/vhosts/default ]; then
    mkdir -p /var/www/shared/vhosts/default
    cat > /var/www/shared/vhosts/default/index.php << 'EOL'
<?php
http_response_code(200);
echo "OK";
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

# ---------------------------------------------------------------------------
# vhost management tooling. The scripts are versioned in the repo under
# scripts/vhost-manager/ and staged from S3 by the bootstrap; installing
# them here (instead of heredocs in this script) keeps user data small and
# lets script updates ship without touching instances.
# ---------------------------------------------------------------------------
mkdir -p /usr/local/bin/vhost-manager
cp /opt/provisioning/scripts/vhost-manager/create-vhost.sh \
   /opt/provisioning/scripts/vhost-manager/sync-vhosts.sh \
   /opt/provisioning/scripts/vhost-manager/list-vhosts.sh \
   /opt/provisioning/scripts/vhost-manager/remove-vhost.sh \
   /usr/local/bin/vhost-manager/
cp /opt/provisioning/scripts/vhost-manager/vhost /usr/local/bin/vhost
chmod +x /usr/local/bin/vhost-manager/*.sh /usr/local/bin/vhost

# Create vhost sync timer for automatic synchronization.
#
# NOTE: inotify cannot be used here. inotify only reports changes made by
# the local NFS client; edits made on *other* web servers (or via EFS
# directly) never generate events. A short polling interval is the reliable
# way to converge all servers on the shared configuration. The sync script
# exits early (no Apache reload) when nothing has changed.
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
/usr/local/bin/vhost-manager/sync-vhosts.sh --force

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

# ---------------------------------------------------------------------------
# Prometheus node_exporter: host CPU / RAM / disk / network metrics (:9100).
# Scraped by the monitoring server; the port is only reachable from the
# monitoring security group.
# ---------------------------------------------------------------------------
NODE_EXPORTER_VERSION="1.8.2"
useradd --no-create-home --shell /usr/sbin/nologin node_exporter || true
# Skip the download when the binary is pre-baked into the AMI (see packer/)
if [ ! -x /usr/local/bin/node_exporter ]; then
    cd /tmp
    fetch_release "https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION" \
        "node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz"
    tar xzf node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
    mv node_exporter-$NODE_EXPORTER_VERSION.linux-amd64/node_exporter /usr/local/bin/
fi

cat > /etc/systemd/system/node_exporter.service << 'NODEEOF'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
NODEEOF

systemctl daemon-reload
systemctl enable --now node_exporter

# ---------------------------------------------------------------------------
# Apache metrics: mod_status (localhost only) + apache_exporter (:9117).
# Exposes request rate, worker/scoreboard state, throughput, and uptime.
# ---------------------------------------------------------------------------
a2enmod status
cat > /etc/apache2/conf-available/server-status-local.conf << 'STATUSEOF'
ExtendedStatus On
<Location /server-status>
    Require local
</Location>
STATUSEOF
a2enconf server-status-local
systemctl reload apache2

APACHE_EXPORTER_VERSION="1.0.8"
useradd --no-create-home --shell /usr/sbin/nologin apache_exporter || true
# Skip the download when the binary is pre-baked into the AMI (see packer/)
if [ ! -x /usr/local/bin/apache_exporter ]; then
    cd /tmp
    fetch_release "https://github.com/Lusitaniae/apache_exporter/releases/download/v$APACHE_EXPORTER_VERSION" \
        "apache_exporter-$APACHE_EXPORTER_VERSION.linux-amd64.tar.gz"
    tar xzf apache_exporter-$APACHE_EXPORTER_VERSION.linux-amd64.tar.gz
    mv apache_exporter-$APACHE_EXPORTER_VERSION.linux-amd64/apache_exporter /usr/local/bin/
fi

cat > /etc/systemd/system/apache_exporter.service << 'APACHEEOF'
[Unit]
Description=Prometheus Apache Exporter
After=network-online.target apache2.service

[Service]
User=apache_exporter
Group=apache_exporter
ExecStart=/usr/local/bin/apache_exporter --scrape_uri="http://localhost/server-status?auto" --telemetry.address=":9117"
Restart=always

[Install]
WantedBy=multi-user.target
APACHEEOF

systemctl daemon-reload
systemctl enable --now apache_exporter

echo "Web server setup completed successfully"
