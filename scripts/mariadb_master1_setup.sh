#!/bin/bash
set -e

# Update system
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Install MariaDB
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    mariadb-server \
    mariadb-client \
    awscli

# Secure MariaDB installation
mysql -e "UPDATE mysql.user SET Password = PASSWORD('${db_root_password}') WHERE User = 'root'"
mysql -e "DROP USER IF EXISTS ''@'localhost'"
mysql -e "DROP USER IF EXISTS ''@'$(hostname)'"
mysql -e "DROP DATABASE IF EXISTS test"
mysql -e "FLUSH PRIVILEGES"

# Configure MariaDB for replication (Master 1)
cat > /etc/mysql/mariadb.conf.d/99-replication.cnf << EOL
[mysqld]
# Server ID - unique for each server
server-id = 1

# Binary logging
log-bin = /var/log/mysql/mysql-bin.log
binlog_format = ROW
expire_logs_days = 7
max_binlog_size = 100M

# Relay log
relay-log = /var/log/mysql/relay-bin
relay-log-index = /var/log/mysql/relay-bin.index

# Master-Master replication settings
auto_increment_increment = 2
auto_increment_offset = 1

# Enable binary logging for all databases
binlog_do_db = webapp

# Network settings
bind-address = 0.0.0.0

# Performance tuning
innodb_buffer_pool_size = 1G
innodb_log_file_size = 256M
max_connections = 500

# Enable GTID for better replication
gtid_domain_id = 1
log_slave_updates = ON
EOL

# Restart MariaDB
systemctl restart mariadb
systemctl enable mariadb

# Wait for MariaDB to be ready
sleep 10

# Set root password
mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${db_root_password}')"

# Create replication user
mysql -u root -p'${db_root_password}' -e "
CREATE USER '${db_replication_user}'@'%' IDENTIFIED BY '${db_replication_password}';
GRANT REPLICATION SLAVE ON *.* TO '${db_replication_user}'@'%';
FLUSH PRIVILEGES;
"

# Create application database
mysql -u root -p'${db_root_password}' -e "
CREATE DATABASE IF NOT EXISTS webapp;
GRANT ALL PRIVILEGES ON webapp.* TO 'webapp_user'@'%' IDENTIFIED BY '${db_root_password}';
FLUSH PRIVILEGES;
"

# Wait for Master 2 to be ready (simple wait, in production use better coordination)
sleep 120

# Setup replication from Master 2
mysql -u root -p'${db_root_password}' -e "
CHANGE MASTER TO
    MASTER_HOST='${master2_ip}',
    MASTER_USER='${db_replication_user}',
    MASTER_PASSWORD='${db_replication_password}',
    MASTER_USE_GTID=slave_pos;
START SLAVE;
"

# Create backup script
cat > /usr/local/bin/mariadb_backup.sh << 'EOL'
#!/bin/bash
BACKUP_DIR="/var/backups/mariadb"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p $BACKUP_DIR

mysqldump -u root -p'${db_root_password}' --all-databases --routines --triggers \
    --single-transaction --master-data=2 > "$BACKUP_DIR/full_backup_$DATE.sql"

# Keep only last 7 days of backups
find $BACKUP_DIR -name "*.sql" -mtime +7 -delete
EOL

chmod +x /usr/local/bin/mariadb_backup.sh

# Add backup to cron (daily at 2 AM)
echo "0 2 * * * root /usr/local/bin/mariadb_backup.sh" >> /etc/crontab

echo "MariaDB Master 1 setup completed successfully"