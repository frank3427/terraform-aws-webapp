# Monitoring Guide

Prometheus + Alertmanager + Grafana monitoring for all servers and
services in this infrastructure. Toggle with `enable_monitoring`
(default: on). Alerts are delivered via SNS email — set `alert_email`
and confirm the subscription AWS sends.

## What Is Collected

| Target | Exporter | Port | Metrics |
|---|---|---|---|
| Every server (web, DB, bastion, monitoring) | node_exporter | 9100 | CPU, RAM, disk usage & I/O, network, load |
| Web servers | apache_exporter (mod_status) | 9117 | Request rate, worker/scoreboard state, throughput, uptime |
| Database servers | mysqld_exporter | 9104 | Connections, query rates, InnoDB stats, **replication status/lag** |

Prometheus discovers targets from EC2 tags (`Environment` + `Type`), the
same scheme the bastion tools use — scaling `web_server_count` or ASG
instance replacement is picked up automatically within about a minute.
Because ASG-managed web servers share one `Name` tag, the `instance`
label is `"<Name> <private-ip>"` to stay unique per server. Metrics are
retained for 30 days.

## Architecture & Security

- The monitoring server runs in a private subnet with no public exposure.
- Grafana (:3000), the Prometheus UI (:9090) and the Alertmanager UI
  (:9093) accept connections only from the bastion security group.
- Exporter ports on the fleet accept connections only from the monitoring
  security group.
- The `exporter` MariaDB user is localhost-only with least-privilege
  grants (PROCESS, REPLICATION CLIENT, SLAVE MONITOR, SELECT on
  performance_schema) and a per-instance random password.

## Accessing Grafana

1. Open a tunnel through the bastion (or use the `grafana_tunnel_command`
   Terraform output):
   ```bash
   ssh -i your-key.pem \
       -L 3000:<monitoring-private-ip>:3000 \
       -L 9090:<monitoring-private-ip>:9090 \
       ubuntu@<bastion-public-ip>
   ```
   Alternative without SSH: SSM port forwarding
   ```bash
   aws ssm start-session --target <monitoring-instance-id> \
       --document-name AWS-StartPortForwardingSession \
       --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
   ```

2. Browse to http://localhost:3000 (Grafana) or http://localhost:9090
   (Prometheus UI, useful for ad-hoc queries and checking target health
   under Status → Targets).

3. Log in as `admin`. The generated password is in SSM Parameter Store
   (no SSH required; see the `grafana_admin_password_parameter` output):
   ```bash
   aws ssm get-parameter --with-decryption \
       --name /<project>/<environment>/monitoring/grafana_admin_password \
       --query Parameter.Value --output text
   ```
   (Fallback: `sudo cat /root/grafana-admin-password` on the instance.)
   Change it after first login (Profile → Change password).

## Dashboards

Three community dashboards are provisioned automatically into the
"Infrastructure" folder:

- **Node Exporter Full** (ID 1860) — per-server CPU, memory, disk, network
- **Apache** (ID 3894) — web server request/worker metrics
- **MySQL Overview** (ID 7362) — database and replication metrics

If a dashboard failed to download at boot (check
`/var/lib/grafana/dashboards/`), import it manually: Dashboards → New →
Import → enter the ID → select the Prometheus datasource.

## Useful Queries

```promql
# CPU usage per server (%)
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory usage per server (%)
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Disk usage on root filesystem (%)
(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100

# Apache requests/second per web server
rate(apache_accesses_total[5m])

# MariaDB replication lag (seconds)
mysql_slave_status_seconds_behind_master

# Replication broken (0 = broken, 1 = healthy)
mysql_slave_status_slave_sql_running * mysql_slave_status_slave_io_running
```

## Alerting

Prometheus evaluates the rules in `/etc/prometheus/rules/alerts.yml`;
firing alerts route through Alertmanager (:9093) to the SNS topic
(`alerts_sns_topic_arn` output). Set `alert_email` in terraform.tfvars to
subscribe an address (confirm the email AWS sends once). Additional
subscribers (more emails, Slack via HTTPS endpoint, PagerDuty) can be
added to the same topic outside Terraform or as extra
`aws_sns_topic_subscription` resources.

Provisioned rules:

| Alert | Condition | Severity |
|---|---|---|
| InstanceDown | any scrape target down 3m | critical |
| MysqlReplicationNotRunning | IO or SQL thread stopped 2m | critical |
| ApacheDown | mod_status unreachable 3m | critical |
| MysqlReplicationLag | > 60s behind for 5m | warning |
| HostOutOfDisk | < 15% free for 10m | warning |
| HostOutOfMemory | < 10% available for 10m | warning |
| HostHighCpu | > 90% for 15m | warning |
| ApacheWorkersSaturated | > 90% workers busy 10m | warning |

To silence or inspect alerts, tunnel to the Alertmanager UI on :9093
(included in `grafana_tunnel_command`).

## Operations

- Services on the monitoring host: `prometheus`, `alertmanager`,
  `grafana-server`, `node_exporter` (all systemd; `systemctl status <name>`)
- Prometheus config: `/etc/prometheus/prometheus.yml`; alert rules:
  `/etc/prometheus/rules/alerts.yml` (run `promtool check config` /
  `promtool check rules` after edits, then `systemctl reload prometheus`)
- Storage: metrics live in `/var/lib/prometheus` on a **dedicated 20 GB
  EBS volume** (30-day retention). The volume survives instance
  replacement — a rebuilt monitoring server remounts it and keeps its
  history. Watch its disk usage on the Node Exporter dashboard.
- The monitoring instance is a single node: if it is down you lose
  visibility (not availability). Rebuilding it via `terraform apply`
  restores collection with history intact.
- Provisioning runs from S3 (see `provisioning.tf`): edits to
  `scripts/monitoring_setup.sh` upload on the next apply but only take
  effect on newly launched instances (or run the script manually via SSM).
