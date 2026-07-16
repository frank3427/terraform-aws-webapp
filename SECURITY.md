# Security Model

This document describes the security controls in this infrastructure and the
items that remain your responsibility, with transactional workloads in mind.

## Controls Implemented

### Edge protection
- **HTTPS termination at the ALB** with an ACM certificate (auto-renewing);
  HTTP is 301-redirected to HTTPS when a certificate is configured
- **AWS WAF** (toggle: `enable_waf`) with a rate-based rule (2000 req/5min
  per IP, blocking brute force and credential stuffing) plus AWS managed
  rule groups: Common Rule Set, Known Bad Inputs, SQL injection, and the
  Amazon IP reputation list. WAF decisions are logged to CloudWatch
  (90-day retention) for attack investigation and false-positive tuning
- ALB **drops malformed headers** (request-smuggling defense), has
  **deletion protection** enabled by default, and writes **access logs**
  (request-level HTTP audit trail) to a dedicated encrypted S3 bucket with
  90-day retention
- Apache sends baseline security headers (HSTS on HTTPS traffic,
  `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`) and does
  not advertise software versions (`ServerTokens Prod`, `expose_php Off`)

### Secrets
- Database passwords live in **SSM Parameter Store (SecureString)** and are
  fetched at boot by the database instances via their IAM role — they are
  **never embedded in EC2 user data**, which is readable by anyone with
  `ec2:DescribeInstanceAttribute`
- On the database hosts, root DB credentials are stored only in
  `/root/.my.cnf` (mode 600); no passwords appear on command lines, in
  process listings, in scripts, or in cron entries
- The application user (`webapp_user`) has its **own password** and
  **least-privilege grants** on the `webapp` schema only, restricted to the
  web server subnets; the replication user can connect only from the peer
  master's IP
- Terraform state still contains the secret values: create the encrypted,
  versioned state bucket with the one-time `bootstrap/` config, wire it
  into the backend block in `main.tf`, and restrict access to the bucket
- The generated Grafana admin password is stored as an SSM SecureString
  (`/<project>/<environment>/monitoring/grafana_admin_password`)

### Monitoring plane
- The Prometheus/Alertmanager/Grafana server sits in a private subnet; its
  UIs (3000/9090/9093) accept connections only from the bastion, and
  exporter ports on the fleet accept connections only from the monitoring
  security group
- The MariaDB `exporter` user is localhost-only and least-privilege
- Alertmanager publishes to SNS using the instance role (sigv4); the role
  can publish only to the alert topic

### Supply chain
- Instance provisioning scripts are served from a **private, versioned S3
  bucket** (`provisioning.tf`); instance roles have read-only access to the
  `scripts/` prefix
- Third-party release tarballs (Prometheus, Alertmanager, exporters) are
  **verified against the release's sha256sums.txt** at install time, with
  retries; a checksum mismatch aborts provisioning
- The optional Packer-baked AMI (see packer/) removes boot-time downloads
  from the critical path entirely

### Network
- Web and database servers have no public IPs; the ALB and bastion are the
  only internet-facing components
- **Egress is restricted on every security group** — instances can reach
  package mirrors and AWS APIs (80/443), VPC DNS, and NTP, plus only the
  specific internal services they need (EFS 2049, MySQL 3306). A compromised
  host cannot open arbitrary outbound connections
- Bastion SSH access **must** be limited to explicit admin CIDRs
  (`bastion_allowed_cidrs`); `0.0.0.0/0` is rejected by validation
- **VPC Flow Logs** capture all traffic metadata to CloudWatch Logs
  (90-day retention) for investigation and anomaly detection

### Instances
- **IMDSv2 is required** on all instances, blocking SSRF-based credential
  theft from the metadata service
- All instances run with **least-privilege IAM roles**; the database role
  can read only the three DB secrets and write only to the backup prefix of
  the backup bucket
- **Per-role SSH keys**: Terraform generates a separate ED25519 key pair
  for each role (bastion, web, database, monitoring) — the bastion key
  cannot open internal hosts and vice versa. Private keys land in
  `sshkeys_generated/` (gitignored, mode 0600) and in Terraform state,
  which is one more reason the state bucket must be access-controlled.
  Internal keys are never stored on the bastion; onward hops use SSH
  agent forwarding
- **SSM Session Manager** is available on all instances (auditable shell
  access through IAM, no inbound ports); consider it over SSH for routine
  access
- **Automatic security patching** is enabled on all instances via
  `unattended-upgrades` (security pocket only, no automatic reboots —
  schedule reboots for kernel updates yourself)
- All EBS volumes and the EFS file system are **encrypted at rest**

### Data protection
- Nightly database dumps are compressed and shipped to a **dedicated S3
  bucket** with KMS encryption, versioning, public access blocked, and
  35-day lifecycle retention — backups survive instance loss or compromise
- **EFS website content is backed up automatically** via AWS Backup
  (`aws_efs_backup_policy`), protecting against accidental deletion,
  a destructive `vhost remove --purge`, or ransomware on a web server

## Your Responsibilities

- **Payment card data:** if these sites process card payments, do not
  store, process, or transmit primary account numbers on this
  infrastructure. Use a payment processor (Stripe, Adyen, Braintree, etc.)
  with hosted fields or redirects so card data never touches your servers.
  Storing card data brings full PCI DSS scope, which this architecture is
  not designed or assessed for.
- **Application security:** WAF reduces exposure but does not replace
  secure coding — parameterized queries, output encoding, CSRF protection,
  session management (`Secure`/`HttpOnly` cookies), and input validation
  are the application's job.
- **Reboots for kernel updates:** unattended-upgrades applies security
  patches daily but does not reboot; schedule periodic reboots (or rebuild
  instances) so kernel patches take effect.
- **Restrict IAM access** to the Terraform state bucket, SSM parameters
  (`/<project>/<environment>/db/*`), and the backup bucket.
- **Rotate credentials** periodically: update the variable, run
  `terraform apply` to update SSM, then apply the change inside MariaDB.
- **Test backup restores.** A backup that has never been restored is a hope,
  not a backup.

## Open Follow-ups

Identified but not yet implemented, in suggested priority order:

1. **Account-level controls** (outside this repo's scope): CloudTrail
   enabled in all regions, GuardDuty, MFA on IAM users, and strict access
   control on the Terraform state bucket, SSM parameters, and backup
   buckets.
2. **WAF rate-limit tuning** — the 2000 req/5min default may need
   adjustment for legitimate high-traffic clients or shared office NAT IPs;
   review the WAF logs during the first weeks.

(Resolved in earlier iterations: unconfigured CloudWatch agent removed —
Prometheus is the metrics plane; alerting implemented via Prometheus
rules → Alertmanager → SNS, see MONITORING.md; single shared SSH key
replaced with Terraform-generated per-role key pairs, see ssh_keys.tf.)

## Known Trade-offs

- **MySQL connections inside the VPC are not TLS-encrypted.** Traffic stays
  within your VPC on AWS-controlled infrastructure; if your compliance
  regime requires encryption in transit everywhere, configure MariaDB
  server certificates and `REQUIRE SSL` on the application user.
- **EFS traffic is NFS without TLS** for the same reason; EFS mount-target
  traffic never leaves the VPC. Mounting with TLS requires `amazon-efs-utils`
  (not packaged for Ubuntu; must be built from source).
- **Managed alternatives:** RDS/Aurora MySQL would replace the
  hand-rolled master-master replication with managed failover, automated
  encrypted backups, and TLS out of the box — strongly worth considering
  for transactional data.
