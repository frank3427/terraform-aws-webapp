# Security Model

This document describes the security controls in this infrastructure and the
items that remain your responsibility, with transactional workloads in mind.

## Controls Implemented

### Edge protection
- **HTTPS termination at the ALB** with an ACM certificate (auto-renewing);
  HTTP is 301-redirected to HTTPS when a certificate is configured
- **AWS WAF** (toggle: `enable_waf`) with AWS managed rule groups: Common
  Rule Set, Known Bad Inputs, SQL injection, and the Amazon IP reputation
  list
- ALB **drops malformed headers** (request-smuggling defense) and has
  **deletion protection** enabled by default
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
- Terraform state still contains the secret values: use the encrypted S3
  backend (see the commented block in `main.tf`) and restrict access to the
  state bucket

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
- **SSM Session Manager** is available on all instances (auditable shell
  access through IAM, no inbound ports); consider it over SSH for routine
  access
- All EBS volumes and the EFS file system are **encrypted at rest**

### Data protection
- Nightly database dumps are compressed and shipped to a **dedicated S3
  bucket** with KMS encryption, versioning, public access blocked, and
  35-day lifecycle retention — backups survive instance loss or compromise
- EFS is encrypted at rest; consider enabling **AWS Backup** for EFS

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
- **Patching:** instances install updates at launch only. Enable
  `unattended-upgrades` or rebuild instances regularly for ongoing patching.
- **Restrict IAM access** to the Terraform state bucket, SSM parameters
  (`/<project>/<environment>/db/*`), and the backup bucket.
- **Rotate credentials** periodically: update the variable, run
  `terraform apply` to update SSM, then apply the change inside MariaDB.
- **Test backup restores.** A backup that has never been restored is a hope,
  not a backup.

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
