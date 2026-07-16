#!/bin/bash
# Monitoring server provisioning (Prometheus + Alertmanager + Grafana).
# Fetched from the provisioning S3 bucket and run by the user-data
# bootstrap, which exports:
#   REGION          - AWS region
#   ENVIRONMENT     - environment name (EC2 service-discovery filter)
#   SSM_PREFIX      - SSM parameter prefix (Grafana admin password is stored
#                     at $SSM_PREFIX/monitoring/grafana_admin_password)
#   SNS_TOPIC_ARN   - SNS topic Alertmanager publishes alerts to
#   PROM_VOLUME_ID  - EBS volume id holding /var/lib/prometheus (metrics
#                     survive instance replacement)
set -euo pipefail

: "${REGION:?REGION must be set by the bootstrap}"
: "${ENVIRONMENT:?ENVIRONMENT must be set by the bootstrap}"
: "${SSM_PREFIX:?SSM_PREFIX must be set by the bootstrap}"
: "${SNS_TOPIC_ARN:?SNS_TOPIC_ARN must be set by the bootstrap}"
: "${PROM_VOLUME_ID:?PROM_VOLUME_ID must be set by the bootstrap}"

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

DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget gnupg2 apt-transport-https software-properties-common

# ---------------------------------------------------------------------------
# Persistent metrics volume. Prometheus data lives on a dedicated EBS volume
# so 30 days of history survive instance replacement (user-data/AMI changes).
# The device is located by EBS volume-id serial (NVMe on t3), formatted only
# if blank, and mounted by label.
# ---------------------------------------------------------------------------
VOL_SERIAL=$(echo "$PROM_VOLUME_ID" | tr -d '-')
DEV=""
for attempt in $(seq 1 60); do
    DEV=$(lsblk -rno NAME,SERIAL | awk -v s="$VOL_SERIAL" '$2 == s { print "/dev/" $1; exit }')
    [ -n "$DEV" ] && break
    echo "Waiting for volume $PROM_VOLUME_ID to attach ($attempt/60)..."
    sleep 5
done
if [ -z "$DEV" ]; then
    echo "FATAL: Prometheus data volume $PROM_VOLUME_ID never attached"
    exit 1
fi
if [ -z "$(blkid -o value -s TYPE "$DEV" 2>/dev/null)" ]; then
    mkfs.ext4 -L promdata "$DEV"
fi
mkdir -p /var/lib/prometheus
echo "LABEL=promdata /var/lib/prometheus ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a

# ---------------------------------------------------------------------------
# node_exporter (monitor the monitor)
# ---------------------------------------------------------------------------
NODE_EXPORTER_VERSION="1.8.2"
useradd --no-create-home --shell /usr/sbin/nologin node_exporter || true
cd /tmp
fetch_release "https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION" \
    "node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz"
tar xzf node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
mv node_exporter-$NODE_EXPORTER_VERSION.linux-amd64/node_exporter /usr/local/bin/

cat > /etc/systemd/system/node_exporter.service << 'EOL'
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
EOL

# ---------------------------------------------------------------------------
# Prometheus
# ---------------------------------------------------------------------------
PROMETHEUS_VERSION="3.5.0"
useradd --no-create-home --shell /usr/sbin/nologin prometheus || true
mkdir -p /etc/prometheus/rules

cd /tmp
fetch_release "https://github.com/prometheus/prometheus/releases/download/v$PROMETHEUS_VERSION" \
    "prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz"
tar xzf prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz
mv prometheus-$PROMETHEUS_VERSION.linux-amd64/prometheus /usr/local/bin/
mv prometheus-$PROMETHEUS_VERSION.linux-amd64/promtool /usr/local/bin/

# Scrape config: targets discovered from EC2 tags, so scaling the fleet
# (web_server_count) is picked up automatically within a minute.
cat > /etc/prometheus/prometheus.yml << EOL
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  # CPU / RAM / disk / network on every instance in this environment.
  # ASG-managed web servers share one Name tag, so the instance label is
  # "Name ip" to stay unique per target.
  - job_name: "node"
    ec2_sd_configs:
      - region: $REGION
        port: 9100
        filters:
          - name: "tag:Environment"
            values: ["$ENVIRONMENT"]
          - name: "instance-state-name"
            values: ["running"]
    relabel_configs:
      - source_labels: [__meta_ec2_tag_Name, __meta_ec2_private_ip]
        separator: " "
        target_label: instance
      - source_labels: [__meta_ec2_tag_Type]
        target_label: role

  # Apache metrics on web servers (via mod_status)
  - job_name: "apache"
    ec2_sd_configs:
      - region: $REGION
        port: 9117
        filters:
          - name: "tag:Environment"
            values: ["$ENVIRONMENT"]
          - name: "tag:Type"
            values: ["WebServer"]
          - name: "instance-state-name"
            values: ["running"]
    relabel_configs:
      - source_labels: [__meta_ec2_tag_Name, __meta_ec2_private_ip]
        separator: " "
        target_label: instance

  # MariaDB metrics on database servers (incl. replication status)
  - job_name: "mysql"
    ec2_sd_configs:
      - region: $REGION
        port: 9104
        filters:
          - name: "tag:Environment"
            values: ["$ENVIRONMENT"]
          - name: "tag:Type"
            values: ["DatabaseServer"]
          - name: "instance-state-name"
            values: ["running"]
    relabel_configs:
      - source_labels: [__meta_ec2_tag_Name, __meta_ec2_private_ip]
        separator: " "
        target_label: instance
EOL

# Baseline alert rules: paging-worthy failures only (instance down, disk/
# memory pressure, replication broken, Apache saturated). Everything else
# stays a dashboard concern to keep alerts actionable.
cat > /etc/prometheus/rules/alerts.yml << 'RULESEOF'
groups:
  - name: infrastructure
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }}: {{ $labels.job }} target down"
          description: "Prometheus has not been able to scrape {{ $labels.instance }} ({{ $labels.job }}) for 3 minutes."

      - alert: HostOutOfDisk
        expr: node_filesystem_avail_bytes{fstype=~"ext4|xfs"} / node_filesystem_size_bytes{fstype=~"ext4|xfs"} < 0.15
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }}: low disk space on {{ $labels.mountpoint }}"
          description: "Less than 15% space left ({{ $value | humanizePercentage }} available)."

      - alert: HostOutOfMemory
        expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.10
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }}: low memory"
          description: "Less than 10% of memory available for 10 minutes."

      - alert: HostHighCpu
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }}: sustained high CPU"
          description: "CPU usage above 90% for 15 minutes."

  - name: mariadb
    rules:
      - alert: MysqlReplicationNotRunning
        expr: mysql_slave_status_slave_io_running == 0 or mysql_slave_status_slave_sql_running == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }}: MariaDB replication stopped"
          description: "The IO or SQL replication thread is not running. Master-master replication is broken."

      - alert: MysqlReplicationLag
        expr: mysql_slave_status_seconds_behind_master > 60
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }}: MariaDB replication lag"
          description: "Replication is {{ $value }}s behind the other master."

  - name: apache
    rules:
      - alert: ApacheDown
        expr: apache_up == 0
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }}: Apache is down"
          description: "apache_exporter reports Apache unreachable via mod_status."

      - alert: ApacheWorkersSaturated
        expr: apache_workers{state="busy"} / ignoring(state) sum without(state) (apache_workers) > 0.9
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }}: Apache worker pool near saturation"
          description: "More than 90% of Apache workers busy for 10 minutes; requests may queue."
RULESEOF

promtool check rules /etc/prometheus/rules/alerts.yml

chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

cat > /etc/systemd/system/prometheus.service << 'EOL'
[Unit]
Description=Prometheus
After=network-online.target
RequiresMountsFor=/var/lib/prometheus

[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus \
    --storage.tsdb.retention.time=30d \
    --web.listen-address=0.0.0.0:9090
Restart=always

[Install]
WantedBy=multi-user.target
EOL

# ---------------------------------------------------------------------------
# Alertmanager: routes Prometheus alerts to SNS (email subscriptions are
# managed in Terraform via var.alert_email). Publishes with the instance
# role credentials (sigv4).
# ---------------------------------------------------------------------------
ALERTMANAGER_VERSION="0.28.1"
useradd --no-create-home --shell /usr/sbin/nologin alertmanager || true
mkdir -p /etc/alertmanager /var/lib/alertmanager

cd /tmp
fetch_release "https://github.com/prometheus/alertmanager/releases/download/v$ALERTMANAGER_VERSION" \
    "alertmanager-$ALERTMANAGER_VERSION.linux-amd64.tar.gz"
tar xzf alertmanager-$ALERTMANAGER_VERSION.linux-amd64.tar.gz
mv alertmanager-$ALERTMANAGER_VERSION.linux-amd64/alertmanager /usr/local/bin/
mv alertmanager-$ALERTMANAGER_VERSION.linux-amd64/amtool /usr/local/bin/

cat > /etc/alertmanager/alertmanager.yml << EOL
route:
  receiver: sns
  group_by: ["alertname", "instance"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: sns
    sns_configs:
      - topic_arn: $SNS_TOPIC_ARN
        sigv4:
          region: $REGION
        subject: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}'
EOL

chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager

cat > /etc/systemd/system/alertmanager.service << 'EOL'
[Unit]
Description=Prometheus Alertmanager
After=network-online.target

[Service]
User=alertmanager
Group=alertmanager
ExecStart=/usr/local/bin/alertmanager \
    --config.file=/etc/alertmanager/alertmanager.yml \
    --storage.path=/var/lib/alertmanager \
    --web.listen-address=0.0.0.0:9093
Restart=always

[Install]
WantedBy=multi-user.target
EOL

# ---------------------------------------------------------------------------
# Grafana (OSS, from the official apt repository)
# ---------------------------------------------------------------------------
mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y grafana

# Provision the Prometheus datasource
mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yml << 'EOL'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
EOL

# Provision community dashboards: Node Exporter Full (1860),
# Apache (3894), MySQL Overview (7362)
mkdir -p /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
cat > /etc/grafana/provisioning/dashboards/default.yml << 'EOL'
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: Infrastructure
    type: file
    options:
      path: /var/lib/grafana/dashboards
EOL

for id in 1860 3894 7362; do
    curl -sf --retry 3 --retry-delay 10 "https://grafana.com/api/dashboards/$id/revisions/latest/download" \
        -o "/var/lib/grafana/dashboards/$id.json" || echo "WARN: could not fetch dashboard $id (import manually)"
done
# Provisioned dashboards can't prompt for a datasource - bind them to ours
sed -i 's/${DS_PROMETHEUS}/Prometheus/g' /var/lib/grafana/dashboards/*.json 2>/dev/null || true
sed -i 's/${DS__VICTORIAMETRICS}/Prometheus/g' /var/lib/grafana/dashboards/*.json 2>/dev/null || true
chown -R grafana:grafana /var/lib/grafana/dashboards

# Generate an admin password. Stored in SSM Parameter Store
# ($SSM_PREFIX/monitoring/grafana_admin_password) and, as a fallback,
# in /root/grafana-admin-password on this instance.
GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)
echo "$GRAFANA_ADMIN_PASSWORD" > /root/grafana-admin-password
chmod 600 /root/grafana-admin-password

# ---------------------------------------------------------------------------
# Start everything
# ---------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now node_exporter
systemctl enable --now prometheus
systemctl enable --now alertmanager
systemctl enable --now grafana-server

# Set the admin password once Grafana answers its health endpoint
for attempt in $(seq 1 60); do
    curl -sf http://localhost:3000/api/health > /dev/null && break
    sleep 2
done
grafana-cli admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD" || \
    grafana cli admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD" || \
    echo "WARN: could not set Grafana admin password; default credentials may apply"

# Publish the password to SSM for auditable retrieval without SSH
/snap/bin/aws ssm put-parameter --region "$REGION" \
    --name "$SSM_PREFIX/monitoring/grafana_admin_password" \
    --type SecureString --overwrite \
    --value "$GRAFANA_ADMIN_PASSWORD" \
    || echo "WARN: could not store Grafana password in SSM; read it from /root/grafana-admin-password"

echo "Monitoring server setup completed successfully"
