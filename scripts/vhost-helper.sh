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
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
                -o ProxyCommand="ssh -i $SSH_KEY -W %h:%p $SSH_USER@$JUMP_HOST" \
                "$SSH_USER@$server" "$command"
        else
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
                "$SSH_USER@$server" "$command"
        fi
        echo "---"
    done
}

# Function to create a virtual host
create_vhost() {
    local domain="$1"
    local ssl="$2"
    local email="$3"
    
    if [ -z "$domain" ]; then
        echo "Usage: $0 create <domain> [ssl] [email]"
        exit 1
    fi
    
    echo "Creating virtual host for: $domain"
    
    # Create vhost on first server (it will be shared via EFS)
    local first_server=$(echo $WEB_SERVERS | cut -d' ' -f1)
    local cmd="sudo vhost create $domain"
    [ -n "$ssl" ] && cmd="$cmd $ssl"
    [ -n "$email" ] && cmd="$cmd $email"
    
    if [ -n "$JUMP_HOST" ]; then
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
            -o ProxyCommand="ssh -i $SSH_KEY -W %h:%p $SSH_USER@$JUMP_HOST" \
            "$SSH_USER@$first_server" "$cmd"
    else
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
            "$SSH_USER@$first_server" "$cmd"
    fi
    
    echo "Virtual host created. Synchronizing across all servers..."
    sleep 5  # Allow EFS to propagate changes
    
    # Sync on all servers
    execute_on_all_servers "sudo vhost sync"
    
    echo "Virtual host $domain is now available on all servers!"
}

# Function to list virtual hosts
list_vhosts() {
    echo "Listing virtual hosts from first server..."
    local first_server=$(echo $WEB_SERVERS | cut -d' ' -f1)
    
    if [ -n "$JUMP_HOST" ]; then
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
            -o ProxyCommand="ssh -i $SSH_KEY -W %h:%p $SSH_USER@$JUMP_HOST" \
            "$SSH_USER@$first_server" "sudo vhost list"
    else
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
            "$SSH_USER@$first_server" "sudo vhost list"
    fi
}

# Function to remove a virtual host
remove_vhost() {
    local domain="$1"
    
    if [ -z "$domain" ]; then
        echo "Usage: $0 remove <domain>"
        exit 1
    fi
    
    echo "Removing virtual host for: $domain"
    
    # Remove from first server
    local first_server=$(echo $WEB_SERVERS | cut -d' ' -f1)
    
    if [ -n "$JUMP_HOST" ]; then
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
            -o ProxyCommand="ssh -i $SSH_KEY -W %h:%p $SSH_USER@$JUMP_HOST" \
            "$SSH_USER@$first_server" "echo 'y' | sudo vhost remove $domain"
    else
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
            "$SSH_USER@$first_server" "echo 'y' | sudo vhost remove $domain"
    fi
    
    echo "Virtual host removed. Synchronizing across all servers..."
    sleep 5  # Allow EFS to propagate changes
    
    # Sync on all servers
    execute_on_all_servers "sudo vhost sync"
    
    echo "Virtual host $domain has been removed from all servers!"
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
    execute_on_all_servers "sudo systemctl status vhost-watcher --no-pager"
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
        echo "  create <domain> [ssl] [email]  - Create a new virtual host"
        echo "  list                           - List all virtual hosts"
        echo "  remove <domain>                - Remove a virtual host"
        echo "  sync                           - Synchronize vhosts across servers"
        echo "  status                         - Check vhost watcher and Apache status"
        echo ""
        echo "Examples:"
        echo "  $0 create example.com"
        echo "  $0 create secure.com ssl admin@secure.com"
        echo "  $0 list"
        echo "  $0 remove example.com"
        echo "  $0 sync"
        exit 1
        ;;
esac