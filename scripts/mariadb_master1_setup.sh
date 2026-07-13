#!/bin/bash
set -e

# Update system
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Install MariaDB
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    mariadb-server \
    mariadb-client

# Install AWS CLI v2 (awscli deb was removed from the Ubuntu archive in 24.04+)
snap install aws-cli --classic

# ---------------------------------------------------------------------------
# Fetch secrets from SSM Parameter Store using the instance IAM role.
# Secrets are intentionally NOT embedded in user data, which is readable by
# anyone with ec2:DescribeInstanceAttribute.
# ---------------------------------------------------------------------------
export AWS_DEFAULT_REGION="${region}"
AWS=/snap/bin/aws

DB_ROOT_PASSWORD=$($AWS ssm get-parameter --name "${ssm_prefix}/db/root_password" --with-decryption --query Parameter.Value --output text)
DB_REPL_PASSWORD=$($AWS ssm get-parameter --name "${ssm_prefix}/db/replication_password" --with-decryption --query Parameter.Value --output text)
DB_APP_PASSWORD=$($AWS ssm get-parameter --name "${ssm_prefix}/db/app_password" --with-decryption --query Parameter.Value --output text)

# Secure MariaDB installation
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
mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$DB_ROOT_PASSWORD')"

# Store root credentials in /root/.my.cnf (mode 600) so that subsequent
# commands and cron jobs never carry the password on the command line
# (visible in process listings) or inside world-readable scripts.
cat > /root/.my.cnf << MYCNF
[client]
user=root
password=$DB_ROOT_PASSWORD
MYCNF
chmod 600 /root/.my.cnf

# Create replication user, restricted to the peer master only
mysql -e "
CREATE USER IF NOT EXISTS '${db_replication_user}'@'${master2_ip}' IDENTIFIED BY '$DB_REPL_PASSWORD';
GRANT REPLICATION SLAVE ON *.* TO '${db_replication_user}'@'${master2_ip}';
FLUSH PRIVILEGES;
"

# Create application database and least-privilege application user.
# The app user has its own password (never the root password) and can only
# connect from the web server subnets.
mysql -e "CREATE DATABASE IF NOT EXISTS webapp;"
%{ for pattern in web_host_patterns ~}
mysql -e "
CREATE USER IF NOT EXISTS 'webapp_user'@'${pattern}' IDENTIFIED BY '$DB_APP_PASSWORD';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, REFERENCES ON webapp.* TO 'webapp_user'@'${pattern}';
"
%{ endfor ~}
mysql -e "FLUSH PRIVILEGES;"

# Wait for Master 2 to be ready (simple wait, in production use better coordination)
sleep 120

# Setup replication from Master 2
mysql -e "
CHANGE MASTER TO
    MASTER_HOST='${master2_ip}',
    MASTER_USER='${db_replication_user}',
    MASTER_PASSWORD='$DB_REPL_PASSWORD',
    MASTER_USE_GTID=slave_pos;
START SLAVE;
"

# ---------------------------------------------------------------------------
# Backups: nightly compressed dump, shipped to an encrypted, versioned S3
# bucket so backups survive instance loss or compromise. Credentials come
# from /root/.my.cnf; no passwords appear in this script or in cron.
# ---------------------------------------------------------------------------
cat > /usr/local/bin/mariadb_backup.sh << EOL
#!/bin/bash
set -e
export AWS_DEFAULT_REGION="${region}"
BACKUP_DIR="/var/backups/mariadb"
DATE=\$(date +%Y%m%d_%H%M%S)
HOST=\$(hostname)
mkdir -p "\$BACKUP_DIR"
chmod 700 "\$BACKUP_DIR"

mysqldump --all-databases --routines --triggers \
    --single-transaction --master-data=2 | gzip > "\$BACKUP_DIR/full_backup_\$DATE.sql.gz"
chmod 600 "\$BACKUP_DIR/full_backup_\$DATE.sql.gz"

# Ship to S3 (bucket enforces encryption at rest and 35-day retention)
/snap/bin/aws s3 cp "\$BACKUP_DIR/full_backup_\$DATE.sql.gz" \
    "s3://${backup_bucket}/db-backups/\$HOST/full_backup_\$DATE.sql.gz"

# Keep only last 7 days locally
find "\$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete
EOL

chmod 700 /usr/local/bin/mariadb_backup.sh

# Add backup to cron (daily at 2 AM)
echo "0 2 * * * root /usr/local/bin/mariadb_backup.sh" >> /etc/crontab

echo "MariaDB Master 1 setup completed successfully"
