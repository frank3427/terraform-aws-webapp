#!/bin/bash
# Bastion provisioning. Fetched from the provisioning S3 bucket and run by
# the user-data bootstrap (user data is capped at 16 KB; this script is
# larger, and serving it from S3 lets edits ship without replacing the
# instance).
set -e

source /opt/provisioning/scripts/lib/fetch-release.sh

# Update system
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Enable automatic security updates
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

# Install essential packages for bastion host
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl \
    wget \
    unzip \
    git \
    htop \
    nano \
    vim \
    tree \
    jq \
    python3 \
    python3-pip \
    mysql-client \
    postgresql-client

# AWS CLI v2 is installed by the user-data bootstrap (snap install aws-cli)

# Install AWS Session Manager plugin for enhanced security
cd /tmp
wget https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb
dpkg -i session-manager-plugin.deb

# Install terraform for infrastructure management
cd /tmp
wget https://releases.hashicorp.com/terraform/1.6.0/terraform_1.6.0_linux_amd64.zip
unzip terraform_1.6.0_linux_amd64.zip
mv terraform /usr/local/bin/
chmod +x /usr/local/bin/terraform

# Create management tools directory
mkdir -p /opt/management-tools/lib
mkdir -p /var/cache/webapp
chown ubuntu:ubuntu /var/cache/webapp

# Create SSH configuration for easy access to private instances
# (covers RFC1918 ranges so custom VPC CIDRs work too)
cat > /etc/ssh/ssh_config.d/internal.conf << 'EOL'
# Configuration for internal server access
Host 10.* 172.16.* 172.17.* 172.18.* 172.19.* 172.2?.* 172.30.* 172.31.* 192.168.*
    StrictHostKeyChecking accept-new
    UserKnownHostsFile=/dev/null
    ServerAliveInterval 60
    ServerAliveCountMax 3
    LogLevel ERROR
EOL

# ---------------------------------------------------------------------------
# Dynamic fleet discovery
#
# Web servers get dynamic private IPs and their count is configurable
# (web_server_count), so management tools discover the fleet from EC2 tags
# at runtime instead of hardcoding addresses. Results are cached briefly.
# ---------------------------------------------------------------------------
cat > /opt/management-tools/lib/refresh-hosts.sh << 'EOL'
#!/bin/bash
# Discover web/database servers by tag and cache the result.
set -e
AWS=/snap/bin/aws
CACHE=/var/cache/webapp/hosts.env

# Instance identity via IMDSv2
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region)

# This bastion's Environment tag scopes discovery to its own deployment
ENVIRONMENT=$($AWS ec2 describe-instances --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].Tags[?Key==`Environment`]|[0].Value' \
    --output text)

discover() {
    local type="$1"
    $AWS ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:Type,Values=$type" \
                  "Name=tag:Environment,Values=$ENVIRONMENT" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PrivateIpAddress]' \
        --output text | sort -V
}

WEB_DATA=$(discover WebServer)
DB_DATA=$(discover DatabaseServer)

{
    echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) - do not edit (run refresh-hosts)"
    echo "HOSTS_GENERATED_AT=$(date +%s)"
    echo "WEB_NAMES=($(echo "$WEB_DATA" | awk '{printf "\"%s\" ", $1}'))"
    echo "WEB_IPS=($(echo "$WEB_DATA" | awk '{printf "\"%s\" ", $2}'))"
    echo "DB_NAMES=($(echo "$DB_DATA" | awk '{printf "\"%s\" ", $1}'))"
    echo "DB_IPS=($(echo "$DB_DATA" | awk '{printf "\"%s\" ", $2}'))"
} > "$CACHE.tmp"
mv "$CACHE.tmp" "$CACHE"

echo "Discovered ${WEB_DATA:+$(echo "$WEB_DATA" | wc -l)}${WEB_DATA:-0} web server(s), ${DB_DATA:+$(echo "$DB_DATA" | wc -l)}${DB_DATA:-0} database server(s)."
EOL

cat > /opt/management-tools/lib/hosts.sh << 'EOL'
#!/bin/bash
# Source this to load fleet host arrays (auto-refreshes stale cache).
CACHE=/var/cache/webapp/hosts.env
MAX_AGE=300

ensure_hosts() {
    local now age
    if [ -f "$CACHE" ]; then
        # shellcheck disable=SC1090
        source "$CACHE"
        now=$(date +%s)
        age=$(( now - ${HOSTS_GENERATED_AT:-0} ))
        [ "$age" -lt "$MAX_AGE" ] && return 0
    fi
    /opt/management-tools/lib/refresh-hosts.sh > /dev/null || {
        echo "WARNING: host discovery failed; using last known cache if present" >&2
    }
    [ -f "$CACHE" ] && source "$CACHE"
}

print_hosts() {
    ensure_hosts
    echo "Web servers (${#WEB_IPS[@]}):"
    for i in "${!WEB_IPS[@]}"; do
        echo "  $((i+1)). ${WEB_NAMES[$i]}  ${WEB_IPS[$i]}"
    done
    echo "Database servers (${#DB_IPS[@]}):"
    for i in "${!DB_IPS[@]}"; do
        echo "  $((i+1)). ${DB_NAMES[$i]}  ${DB_IPS[$i]}"
    done
}
EOL

# Create connection helper scripts
cat > /opt/management-tools/connect-web.sh << 'EOL'
#!/bin/bash
# Interactive connection to a web server (fleet discovered dynamically)
source /opt/management-tools/lib/hosts.sh
ensure_hosts

if [ "${#WEB_IPS[@]}" -eq 0 ]; then
    echo "No running web servers found."
    exit 1
fi

echo "Available Web Servers:"
for i in "${!WEB_IPS[@]}"; do
    echo "$((i+1)). ${WEB_NAMES[$i]} (${WEB_IPS[$i]})"
done

read -p "Select server (1-${#WEB_IPS[@]}): " choice

if [[ $choice -ge 1 && $choice -le ${#WEB_IPS[@]} ]]; then
    echo "Connecting to ${WEB_NAMES[$((choice-1))]} at ${WEB_IPS[$((choice-1))]}..."
    ssh ubuntu@${WEB_IPS[$((choice-1))]}
else
    echo "Invalid selection"
fi
EOL

cat > /opt/management-tools/connect-db.sh << 'EOL'
#!/bin/bash
# Interactive connection to a database server (fleet discovered dynamically)
source /opt/management-tools/lib/hosts.sh
ensure_hosts

if [ "${#DB_IPS[@]}" -eq 0 ]; then
    echo "No running database servers found."
    exit 1
fi

echo "Available Database Servers:"
for i in "${!DB_IPS[@]}"; do
    echo "$((i+1)). ${DB_NAMES[$i]} (${DB_IPS[$i]})"
done

read -p "Select server (1-${#DB_IPS[@]}): " choice

if [[ $choice -ge 1 && $choice -le ${#DB_IPS[@]} ]]; then
    echo "Connecting to ${DB_NAMES[$((choice-1))]} at ${DB_IPS[$((choice-1))]}..."
    ssh ubuntu@${DB_IPS[$((choice-1))]}
else
    echo "Invalid selection"
fi
EOL

# Create database connection script
cat > /opt/management-tools/mysql-connect.sh << 'EOL'
#!/bin/bash
# Connect a MySQL client to a database server (fleet discovered dynamically)
source /opt/management-tools/lib/hosts.sh
ensure_hosts

if [ "${#DB_IPS[@]}" -eq 0 ]; then
    echo "No running database servers found."
    exit 1
fi

echo "Available Database Servers:"
for i in "${!DB_IPS[@]}"; do
    echo "$((i+1)). ${DB_NAMES[$i]} (${DB_IPS[$i]})"
done

read -p "Select server (1-${#DB_IPS[@]}): " choice

if [[ $choice -ge 1 && $choice -le ${#DB_IPS[@]} ]]; then
    server=${DB_IPS[$((choice-1))]}
    echo "Connecting to MariaDB on ${DB_NAMES[$((choice-1))]} at $server..."
    read -p "Enter database username [root]: " username
    username=${username:-root}
    mysql -h $server -u $username -p
else
    echo "Invalid selection"
fi
EOL

# Create vhost management script for remote use
cat > /opt/management-tools/vhost-remote.sh << 'EOL'
#!/bin/bash
# Remote virtual host management script (fleet discovered dynamically)
source /opt/management-tools/lib/hosts.sh
ensure_hosts

if [ "${#WEB_IPS[@]}" -eq 0 ]; then
    echo "No running web servers found."
    exit 1
fi

execute_on_all_servers() {
    local command="$1"

    for server in "${WEB_IPS[@]}"; do
        echo "Executing on $server: $command"
        ssh ubuntu@$server "$command"
        echo "---"
    done
}

execute_on_first_server() {
    local command="$1"
    ssh ubuntu@${WEB_IPS[0]} "$command"
}

case "$1" in
    create)
        shift
        domain="$1"
        email="$2"

        if [ -z "$domain" ]; then
            echo "Usage: $0 create <domain> [admin-email]"
            exit 1
        fi

        cmd="sudo vhost create $domain"
        [ -n "$email" ] && cmd="$cmd $email"

        echo "Creating virtual host for: $domain"
        execute_on_first_server "$cmd"

        echo ""
        echo "Virtual host created. Remaining servers sync automatically within one minute."
        echo "Run '$0 sync' to force an immediate sync everywhere."
        ;;
    list)
        echo "Listing virtual hosts from first server..."
        execute_on_first_server "sudo vhost list"
        ;;
    remove)
        shift
        domain="$1"
        purge="$2"

        if [ -z "$domain" ]; then
            echo "Usage: $0 remove <domain> [--purge]"
            echo "By default website content is preserved; pass --purge to delete it."
            exit 1
        fi

        cmd="sudo vhost remove $domain"
        [ "$purge" = "--purge" ] && cmd="$cmd --purge"

        echo "Removing virtual host for: $domain"
        execute_on_first_server "$cmd"

        echo ""
        echo "Virtual host removed. Remaining servers sync automatically within one minute."
        echo "Run '$0 sync' to force an immediate sync everywhere."
        ;;
    sync)
        echo "Synchronizing virtual hosts across all ${#WEB_IPS[@]} servers..."
        execute_on_all_servers "sudo vhost sync"
        echo "Synchronization complete!"
        ;;
    status)
        echo "Checking virtual host status on all ${#WEB_IPS[@]} servers..."
        execute_on_all_servers "sudo systemctl status vhost-sync.timer --no-pager -l"
        ;;
    *)
        echo "Virtual Host Remote Management"
        echo "Usage: $0 {create|list|remove|sync|status}"
        echo ""
        echo "Commands:"
        echo "  create <domain> [admin-email]  - Create a new virtual host"
        echo "  list                           - List all virtual hosts"
        echo "  remove <domain> [--purge]      - Remove a virtual host (--purge deletes content)"
        echo "  sync                           - Synchronize vhosts across servers now"
        echo "  status                         - Check vhost sync timer status"
        echo ""
        echo "Examples:"
        echo "  $0 create example.com"
        echo "  $0 create example.com admin@example.com"
        echo "  $0 list"
        echo "  $0 remove example.com"
        exit 1
        ;;
esac
EOL

# Create infrastructure status script
cat > /opt/management-tools/check-infrastructure.sh << 'EOL'
#!/bin/bash
# Infrastructure health check script (fleet discovered dynamically)
source /opt/management-tools/lib/hosts.sh
ensure_hosts

echo "=== Infrastructure Health Check ==="
echo "$(date)"
echo ""

echo "=== Web Servers (${#WEB_IPS[@]}) ==="
for i in "${!WEB_IPS[@]}"; do
    server=${WEB_IPS[$i]}
    echo -n "${WEB_NAMES[$i]} ($server): "
    if timeout 5 ssh -o ConnectTimeout=5 ubuntu@$server "echo 'OK'" 2>/dev/null | grep -q "OK"; then
        echo "✓ Online"
        if ssh ubuntu@$server "systemctl is-active apache2" 2>/dev/null | grep -q "active"; then
            echo "  Apache: ✓ Running"
        else
            echo "  Apache: ✗ Not running"
        fi
        if ssh ubuntu@$server "systemctl is-active vhost-sync.timer" 2>/dev/null | grep -q "active"; then
            echo "  VHost Sync Timer: ✓ Running"
        else
            echo "  VHost Sync Timer: ✗ Not running"
        fi
    else
        echo "✗ Offline"
    fi
    echo ""
done

echo "=== Database Servers (${#DB_IPS[@]}) ==="
for i in "${!DB_IPS[@]}"; do
    server=${DB_IPS[$i]}
    echo -n "${DB_NAMES[$i]} ($server): "
    if timeout 5 ssh -o ConnectTimeout=5 ubuntu@$server "echo 'OK'" 2>/dev/null | grep -q "OK"; then
        echo "✓ Online"
        if ssh ubuntu@$server "systemctl is-active mariadb" 2>/dev/null | grep -q "active"; then
            echo "  MariaDB: ✓ Running"
        else
            echo "  MariaDB: ✗ Not running"
        fi
    else
        echo "✗ Offline"
    fi
    echo ""
done

echo "=== Load Balancer Health ==="
echo "Check AWS console for ALB target health"
echo ""

echo "Health check completed at $(date)"
EOL

# Make all scripts executable
chmod +x /opt/management-tools/*.sh /opt/management-tools/lib/*.sh

# Create convenient shell functions (dynamic: work with any fleet size)
cat >> /home/ubuntu/.bashrc << 'EOL'

# --- Fleet management (hosts discovered from EC2 tags) ---
source /opt/management-tools/lib/hosts.sh 2>/dev/null

# web <n> / db <n> connect by number; with no argument, list hosts
web() {
    ensure_hosts
    if [ -z "$1" ]; then print_hosts; return; fi
    local idx=$(( $1 - 1 ))
    if [ -n "${WEB_IPS[$idx]}" ]; then
        ssh ubuntu@${WEB_IPS[$idx]}
    else
        echo "No web server #$1 (found ${#WEB_IPS[@]})"; return 1
    fi
}
db() {
    ensure_hosts
    if [ -z "$1" ]; then print_hosts; return; fi
    local idx=$(( $1 - 1 ))
    if [ -n "${DB_IPS[$idx]}" ]; then
        ssh ubuntu@${DB_IPS[$idx]}
    else
        echo "No database server #$1 (found ${#DB_IPS[@]})"; return 1
    fi
}

alias hosts='print_hosts'
alias refresh-hosts='/opt/management-tools/lib/refresh-hosts.sh'
alias connect-web='/opt/management-tools/connect-web.sh'
alias connect-db='/opt/management-tools/connect-db.sh'
alias mysql-connect='/opt/management-tools/mysql-connect.sh'
alias vhost='/opt/management-tools/vhost-remote.sh'
alias health-check='/opt/management-tools/check-infrastructure.sh'

# Useful shortcuts
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
EOL

# Create welcome message
cat > /etc/motd << 'EOL'
╔══════════════════════════════════════════════════════════════════════════════╗
║                           🚀 BASTION HOST                                    ║
║                     AWS Web Application Infrastructure                       ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  Hosts are discovered automatically from EC2 tags (any fleet size).         ║
║                                                                              ║
║  Quick Commands:                                                             ║
║    hosts                 - List all discovered servers                       ║
║    web <n> / db <n>      - SSH to web/database server by number              ║
║    connect-web           - Interactive web server connection                 ║
║    connect-db            - Interactive database server connection            ║
║    mysql-connect         - Connect to MariaDB                                ║
║    vhost <command>       - Manage virtual hosts remotely                     ║
║    health-check          - Check infrastructure status                       ║
║    refresh-hosts         - Force fleet re-discovery                          ║
║                                                                              ║
║  Virtual Host Management:                                                    ║
║    vhost create <domain>         - Create new virtual host                   ║
║    vhost list                    - List all virtual hosts                    ║
║    vhost remove <domain>         - Remove virtual host                       ║
║    vhost sync                    - Sync vhosts across servers                ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOL

# Configure SSH for better security
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Set timezone
timedatectl set-timezone UTC

# Create log directory for management activities
mkdir -p /var/log/management
chown ubuntu:ubuntu /var/log/management


# ---------------------------------------------------------------------------
# Prometheus node_exporter: host CPU / RAM / disk / network metrics (:9100).
# Scraped by the monitoring server; the port is only reachable from the
# monitoring security group.
# ---------------------------------------------------------------------------
NODE_EXPORTER_VERSION="1.8.2"
useradd --no-create-home --shell /usr/sbin/nologin node_exporter || true
cd /tmp
fetch_release "https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION" \
    "node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz"
tar xzf node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
mv node_exporter-$NODE_EXPORTER_VERSION.linux-amd64/node_exporter /usr/local/bin/

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

echo "Bastion host setup completed successfully"