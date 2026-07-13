#!/bin/bash

# Virtual Host Helper Script for Remote Management
# This script can be used to manage vhosts from outside the infrastructure

set -e

# Configuration - Update these values from your Terraform outputs
JUMP_HOST=""  # Bastion host public IP from terraform output
WEB_SERVERS=""  # Private IPs of web servers from terraform output  
SSH_KEY=""  # Path to your SSH private key
SSH_USER="ubuntu"

# Function to execute command on all web servers
execute_on_all_servers() {
    local command="$1"
    local servers=($WEB_SERVERS)
    
    for server in "${servers[@]}"; do
        echo "Executing on $server: $command"
        if [ -n "$JUMP_HOST" ]; then
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
                -o ProxyCommand="ssh -i $SSH_KEY -W %h:%p $SSH_USER@$JUMP_HOST" \
                "$SSH_USER@$server" "$command"
        else
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
                "$SSH_USER@$server" "$command"
        fi
        echo "---"
    done
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
    local first_server=$(echo $WEB_SERVERS | cut -d' ' -f1)
    local cmd="sudo vhost create $domain"
    [ -n "$email" ] && cmd="$cmd $email"

    if [ -n "$JUMP_HOST" ]; then
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
            -o ProxyCommand="ssh -i $SSH_KEY -W %h:%p $SSH_USER@$JUMP_HOST" \
            "$SSH_USER@$first_server" "$cmd"
    else
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
            "$SSH_USER@$first_server" "$cmd"
    fi

    echo ""
    echo "Virtual host created on $first_server."
    echo "The remaining servers will sync automatically within one minute."
    echo "To force an immediate sync everywhere, run: $0 sync"
}

# Function to list virtual hosts
list_vhosts() {
    echo "Listing virtual hosts from first server..."
    local first_server=$(echo $WEB_SERVERS | cut -d' ' -f1)
    
    if [ -n "$JUMP_HOST" ]; then
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
            -o ProxyCommand="ssh -i $SSH_KEY -W %h:%p $SSH_USER@$JUMP_HOST" \
            "$SSH_USER@$first_server" "sudo vhost list"
    else
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
            "$SSH_USER@$first_server" "sudo vhost list"
    fi
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
    local first_server=$(echo $WEB_SERVERS | cut -d' ' -f1)
    local cmd="sudo vhost remove $domain"
    [ "$purge" = "--purge" ] && cmd="$cmd --purge"

    if [ -n "$JUMP_HOST" ]; then
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
            -o ProxyCommand="ssh -i $SSH_KEY -W %h:%p $SSH_USER@$JUMP_HOST" \
            "$SSH_USER@$first_server" "$cmd"
    else
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
            "$SSH_USER@$first_server" "$cmd"
    fi

    echo ""
    echo "Virtual host removed on $first_server."
    echo "The remaining servers will stop serving it within one minute."
    echo "To force an immediate sync everywhere, run: $0 sync"
}

# Function to sync virtual hosts
sync_vhosts() {
    echo "Synchronizing virtual hosts across all servers..."
    execute_on_all_servers "sudo vhost sync"
    echo "Synchronization complete!"
}

# Function to check status
check_status() {
    echo "Checking virtual host status on all servers..."
    execute_on_all_servers "sudo systemctl status vhost-sync.timer --no-pager"
    echo ""
    execute_on_all_servers "sudo apache2ctl -S"
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
        echo "  WEB_SERVERS=\"ip1 ip2 ip3\"  # Private IPs of web servers"
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