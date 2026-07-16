# Baked Web AMI (optional)

Pre-bakes the slow parts of web server provisioning (system upgrade,
Apache/PHP packages, AWS CLI, exporter binaries) into an AMI so instances
boot in seconds and don't depend on apt mirrors or GitHub at launch.
Everything still works without this — stock Ubuntu instances provision
themselves at boot, just slower.

## Build

```bash
cd packer
packer init .
packer build -var aws_region=us-west-2 .
```

Note the AMI id in the output (`ami-...`).

## Use

In `terraform.tfvars`:

```hcl
web_ami_id = "ami-xxxxxxxxxxxxxxxxx"
```

Then `terraform apply`. The launch template picks up the new AMI and the
ASG instance refresh rolls it through the fleet gradually, gated on ALB
health checks.

## Notes

- `scripts/web_server_setup.sh` remains the source of truth for
  configuration; it detects baked binaries/packages and skips the slow
  work. Keep exporter versions in `bake-web-base.sh` in sync with it.
- Rebuild the AMI periodically (or in CI) to pick up OS updates; instances
  also run unattended security upgrades regardless.
- The same pattern can be extended to the bastion/database/monitoring
  roles if their boot times ever matter.
