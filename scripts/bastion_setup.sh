#!/bin/bash
set -e

# Update system
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

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
    awscli \
    python3 \
    python3-pip \
    mysql-client \
    postgresql-client

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
mkdir -p /opt/management-tools

# Create SSH configuration for easy access to private instances
cat > /etc/ssh/ssh_config.d/internal.conf << 'EOL'
# Configuration for internal server access
Host 10.0.*.*
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
    ServerAliveInterval 60
    ServerAliveCountMax 3
    LogLevel ERROR
EOL

# Create connection helper scripts
cat > /opt/management-tools/connect-web.sh << 'EOL'
#!/bin/bash
# Script to connect to web servers

WEB_SERVERS=(
    "10.0.11.10:web-server-1"
    "10.0.12.10:web-server-2" 
    "10.0.13.10:web-server-3"
)

echo "Available Web Servers:"
for i in "${!WEB_SERVERS[@]}"; do
    IFS=':' read -ra ADDR <<< "${WEB_SERVERS[$i]}"
    echo "$((i+1)). ${ADDR[1]} (${ADDR[0]})"
done

read -p "Select server (1-3): " choice

if [[ $choice -ge 1 && $choice -le 3 ]]; then
    IFS=':' read -ra ADDR <<< "${WEB_SERVERS[$((choice-1))]}"
    echo "Connecting to ${ADDR[1]} at ${ADDR[0]}..."
    ssh ubuntu@${ADDR[0]}
else
    echo "Invalid selection"
fi
EOL

cat > /opt/management-tools/connect-db.sh << 'EOL'
#!/bin/bash
# Script to connect to database servers

DB_SERVERS=(
    "10.0.21.10:db-master-1"
    "10.0.22.10:db-master-2"
)

echo "Available Database Servers:"
for i in "${!DB_SERVERS[@]}"; do
    IFS=':' read -ra ADDR <<< "${DB_SERVERS[$i]}"
    echo "$((i+1)). ${ADDR[1]} (${ADDR[0]})"
done

read -p "Select server (1-2): " choice

if [[ $choice -ge 1 && $choice -le 2 ]]; then
    IFS=':' read -ra ADDR <<< "${DB_SERVERS[$((choice-1))]}"
    echo "Connecting to ${ADDR[1]} at ${ADDR[0]}..."
    ssh ubuntu@${ADDR[0]}
else
    echo "Invalid selection"
fi
EOL

# Create database connection script
cat > /opt/management-tools/mysql-connect.sh << 'EOL'
#!/bin/bash
# Script to connect to MariaDB databases

DB_SERVERS=(
    "10.0.21.10:db-master-1"
    "10.0.22.10:db-master-2"
)

echo "Available Database Servers:"
for i in "${!DB_SERVERS[@]}"; do
    IFS=':' read -ra ADDR <<< "${DB_SERVERS[$i]}"
    echo "$((i+1)). ${ADDR[1]} (${ADDR[0]})"
done

read -p "Select server (1-2): " choice

if [[ $choice -ge 1 && $choice -le 2 ]]; then
    IFS=':' read -ra ADDR <<< "${DB_SERVERS[$((choice-1))]}"
    echo "Connecting to MariaDB on ${ADDR[1]} at ${ADDR[0]}..."
    read -p "Enter database username [root]: " username
    username=${username:-root}
    mysql -h ${ADDR[0]} -u $username -p
else
    echo "Invalid selection"
fi
EOL

# Create vhost management script for remote use
cat > /opt/management-tools/vhost-remote.sh << 'EOL'
#!/bin/bash
# Remote virtual host management script

WEB_SERVERS=("10.0.11.10" "10.0.12.10" "10.0.13.10")

execute_on_all_servers() {
    local command="$1"
    
    for server in "${WEB_SERVERS[@]}"; do
        echo "Executing on $server: $command"
        ssh ubuntu@$server "$command"
        echo "---"
    done
}

execute_on_first_server() {
    local command="$1"
    ssh ubuntu@${WEB_SERVERS[0]} "$command"
}

case "$1" in
    create)
        shift
        domain="$1"
        ssl="$2"
        email="$3"
        
        if [ -z "$domain" ]; then
            echo "Usage: $0 create <domain> [ssl] [email]"
            exit 1
        fi
        
        cmd="sudo vhost create $domain"
        [ -n "$ssl" ] && cmd="$cmd $ssl"
        [ -n "$email" ] && cmd="$cmd $email"
        
        echo "Creating virtual host for: $domain"
        execute_on_first_server "$cmd"
        
        echo "Synchronizing across all servers..."
        sleep 5
        execute_on_all_servers "sudo vhost sync"
        echo "Virtual host $domain is now available on all servers!"
        ;;
    list)
        echo "Listing virtual hosts from first server..."
        execute_on_first_server "sudo vhost list"
        ;;
    remove)
        shift
        domain="$1"
        
        if [ -z "$domain" ]; then
            echo "Usage: $0 remove <domain>"
            exit 1
        fi
        
        echo "Removing virtual host for: $domain"
        execute_on_first_server "echo 'y' | sudo vhost remove $domain"
        
        echo "Synchronizing across all servers..."
        sleep 5
        execute_on_all_servers "sudo vhost sync"
        echo "Virtual host $domain has been removed from all servers!"
        ;;
    sync)
        echo "Synchronizing virtual hosts across all servers..."
        execute_on_all_servers "sudo vhost sync"
        echo "Synchronization complete!"
        ;;
    status)
        echo "Checking virtual host status on all servers..."
        execute_on_all_servers "sudo systemctl status vhost-watcher --no-pager -l"
        ;;
    *)
        echo "Virtual Host Remote Management"
        echo "Usage: $0 {create|list|remove|sync|status}"
        echo ""
        echo "Commands:"
        echo "  create <domain> [ssl] [email]  - Create a new virtual host"
        echo "  list                           - List all virtual hosts"
        echo "  remove <domain>                - Remove a virtual host"
        echo "  sync                           - Synchronize vhosts across servers"
        echo "  status                         - Check vhost watcher status"
        echo ""
        echo "Examples:"
        echo "  $0 create example.com"
        echo "  $0 create secure.com ssl admin@secure.com"
        echo "  $0 list"
        echo "  $0 remove example.com"
        exit 1
        ;;
esac
EOL

# Create infrastructure status script
cat > /opt/management-tools/check-infrastructure.sh << 'EOL'
#!/bin/bash
# Infrastructure health check script

echo "=== Infrastructure Health Check ==="
echo "$(date)"
echo ""

# Check web servers
echo "=== Web Servers ==="
WEB_SERVERS=("10.0.11.10" "10.0.12.10" "10.0.13.10")
for i in "${!WEB_SERVERS[@]}"; do
    server=${WEB_SERVERS[$i]}
    echo -n "Web Server $((i+1)) ($server): "
    if timeout 5 ssh -o ConnectTimeout=5 ubuntu@$server "echo 'OK'" 2>/dev/null | grep -q "OK"; then
        echo "✓ Online"
        # Check Apache status
        if ssh ubuntu@$server "systemctl is-active apache2" 2>/dev/null | grep -q "active"; then
            echo "  Apache: ✓ Running"
        else
            echo "  Apache: ✗ Not running"
        fi
        # Check vhost watcher
        if ssh ubuntu@$server "systemctl is-active vhost-watcher" 2>/dev/null | grep -q "active"; then
            echo "  VHost Watcher: ✓ Running"
        else
            echo "  VHost Watcher: ✗ Not running"
        fi
    else
        echo "✗ Offline"
    fi
    echo ""
done

# Check database servers
echo "=== Database Servers ==="
DB_SERVERS=("10.0.21.10" "10.0.22.10")
for i in "${!DB_SERVERS[@]}"; do
    server=${DB_SERVERS[$i]}
    echo -n "DB Server $((i+1)) ($server): "
    if timeout 5 ssh -o ConnectTimeout=5 ubuntu@$server "echo 'OK'" 2>/dev/null | grep -q "OK"; then
        echo "✓ Online"
        # Check MariaDB status
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
# This would need the ALB DNS name to be configured
echo "Check AWS console for ALB target health"
echo ""

echo "Health check completed at $(date)"
EOL

# Make all scripts executable
chmod +x /opt/management-tools/*.sh

# Create convenient aliases
cat >> /home/ubuntu/.bashrc << 'EOL'

# Management aliases
alias web1='ssh ubuntu@10.0.11.10'
alias web2='ssh ubuntu@10.0.12.10' 
alias web3='ssh ubuntu@10.0.13.10'
alias db1='ssh ubuntu@10.0.21.10'
alias db2='ssh ubuntu@10.0.22.10'
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
║  🌐 Web Servers:           web1, web2, web3                                 ║
║  🗄️  Database Servers:      db1, db2                                         ║
║  🔧 Management Tools:       /opt/management-tools/                          ║
║                                                                              ║
║  Quick Commands:                                                             ║
║    connect-web           - Interactive web server connection                 ║
║    connect-db            - Interactive database server connection           ║
║    mysql-connect         - Connect to MariaDB                              ║
║    vhost <command>       - Manage virtual hosts remotely                   ║
║    health-check          - Check infrastructure status                      ║
║                                                                              ║
║  Virtual Host Management:                                                    ║
║    vhost create <domain>         - Create new virtual host                  ║
║    vhost list                    - List all virtual hosts                   ║
║    vhost remove <domain>         - Remove virtual host                      ║
║    vhost sync                    - Sync vhosts across servers               ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOL

# Install CloudWatch agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E ./amazon-cloudwatch-agent.deb

# Configure SSH for better security
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Set timezone
timedatectl set-timezone UTC

# Create log directory for management activities
mkdir -p /var/log/management
chown ubuntu:ubuntu /var/log/management

echo "Bastion host setup completed successfully"