#!/bin/bash

# Virtual Host Helper Script for Remote Management
# This script can be used to manage vhosts from outside the infrastructure

set -e

# Configuration - Update these values from your Terraform outputs
JUMP_HOST=""    # Bastion host public IP (terraform output bastion_public_ip)
WEB_SERVERS="auto"  # Space-separated private IPs, or "auto" to discover via AWS CLI
SSH_KEY=""      # Path to the web SSH key, e.g. sshkeys_generated/<project>-<environment>-web
SSH_USER="ubuntu"
# Note: with the generated ./sshcfg you can also skip this helper's SSH
# plumbing entirely: ssh -F sshcfg ubuntu@<web-ip> 'sudo vhost list'

# Used only when WEB_SERVERS="auto"
AWS_REGION="${AWS_REGION:-us-west-2}"
ENVIRONMENT="${ENVIRONMENT:-production}"

# Auto-discover web servers by tag (requires AWS CLI credentials with
# ec2:DescribeInstances). The web tier is an ASG, so IPs change as
# instances are replaced - "auto" is the reliable option.
if [ "$WEB_SERVERS" = "auto" ]; then
    WEB_SERVERS=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Type,Values=WebServer" \
                  "Name=tag:Environment,Values=$ENVIRONMENT" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PrivateIpAddress]' \
        --output text | sort -V | awk '{print $2}' | tr '\n' ' ')
    if [ -z "${WEB_SERVERS// /}" ]; then
        echo "Auto-discovery found no running web servers (region=$AWS_REGION, environment=$ENVIRONMENT)."
        echo "Set WEB_SERVERS manually in this script or check AWS credentials."
        exit 1
    fi
    echo "Discovered web servers: $WEB_SERVERS"
fi

# Run a command on one server, optionally via the bastion jump host
run_on() {
    local server="$1"
    shift
    if [ -n "$JUMP_HOST" ]; then
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
            -o ProxyCommand="ssh -i $SSH_KEY -W %h:%p $SSH_USER@$JUMP_HOST" \
            "$SSH_USER@$server" "$@"
    else
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
            "$SSH_USER@$server" "$@"
    fi
}

# Run a command on every web server
run_on_all() {
    local server
    for server in $WEB_SERVERS; do
        echo "Executing on $server: $*"
        run_on "$server" "$@"
        echo "---"
    done
}

# Return the first web server (vhost changes propagate via EFS)
first_server() {
    echo "$WEB_SERVERS" | cut -d' ' -f1
}

# Function to create a virtual host
create_vhost() {
    local domain="$1"
    local email="$2"

    if [ -z "$domain" ]; then
        echo "Usage: $0 create <domain> [admin-email]"
        exit 1
    fi

    echo "Creating virtual host for: $domain"

    # Create vhost on first server (it will be shared via EFS)
    local cmd="sudo vhost create $domain"
    [ -n "$email" ] && cmd="$cmd $email"
    run_on "$(first_server)" "$cmd"

    echo ""
    echo "Virtual host created on $(first_server)."
    echo "The remaining servers will sync automatically within one minute."
    echo "To force an immediate sync everywhere, run: $0 sync"
}

# Function to list virtual hosts
list_vhosts() {
    echo "Listing virtual hosts from first server..."
    run_on "$(first_server)" "sudo vhost list"
}

# Function to remove a virtual host
remove_vhost() {
    local domain="$1"
    local purge="$2"

    if [ -z "$domain" ]; then
        echo "Usage: $0 remove <domain> [--purge]"
        echo "By default website content is preserved; pass --purge to delete it."
        exit 1
    fi

    echo "Removing virtual host for: $domain"
    if [ "$purge" = "--purge" ]; then
        echo "WARNING: --purge will permanently delete the website content."
    fi

    # Remove from first server (config removal propagates via EFS)
    local cmd="sudo vhost remove $domain"
    [ "$purge" = "--purge" ] && cmd="$cmd --purge"
    run_on "$(first_server)" "$cmd"

    echo ""
    echo "Virtual host removed on $(first_server)."
    echo "The remaining servers will stop serving it within one minute."
    echo "To force an immediate sync everywhere, run: $0 sync"
}

# Function to sync virtual hosts
sync_vhosts() {
    echo "Synchronizing virtual hosts across all servers..."
    run_on_all "sudo vhost sync"
    echo "Synchronization complete!"
}

# Function to check status
check_status() {
    echo "Checking virtual host status on all servers..."
    run_on_all "sudo systemctl status vhost-sync.timer --no-pager"
    echo ""
    run_on_all "sudo apache2ctl -S"
}

# Main script logic
case "$1" in
    create)
        shift
        create_vhost "$@"
        ;;
    list)
        list_vhosts
        ;;
    remove)
        shift
        remove_vhost "$@"
        ;;
    sync)
        sync_vhosts
        ;;
    status)
        check_status
        ;;
    *)
        echo "Virtual Host Management Helper"
        echo "Usage: $0 {create|list|remove|sync|status}"
        echo ""
        echo "Before using this script, set the following variables:"
        echo "  WEB_SERVERS=\"ip1 ip2 ip3\"  # Private IPs of web servers (or \"auto\")"
        echo "  SSH_KEY=\"/path/to/key.pem\"  # Path to SSH private key"
        echo "  JUMP_HOST=\"bastion-ip\"      # Optional: bastion host IP"
        echo ""
        echo "Commands:"
        echo "  create <domain> [admin-email]  - Create a new virtual host"
        echo "  list                           - List all virtual hosts"
        echo "  remove <domain> [--purge]      - Remove a virtual host (--purge deletes content)"
        echo "  sync                           - Synchronize vhosts across servers now"
        echo "  status                         - Check vhost sync timer and Apache status"
        echo ""
        echo "Examples:"
        echo "  $0 create example.com"
        echo "  $0 create example.com admin@example.com"
        echo "  $0 list"
        echo "  $0 remove example.com"
        echo "  $0 sync"
        exit 1
        ;;
esac
