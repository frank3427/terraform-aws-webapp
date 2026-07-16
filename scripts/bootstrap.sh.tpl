#!/bin/bash
# Minimal user-data bootstrap for the "${role}" role.
#
# The real provisioning script lives in S3, not in user data, because:
#   - EC2 user data is capped at 16 KB (base64-decoded); the full setup
#     scripts exceed it
#   - keeping user data tiny and stable means editing a provisioning
#     script no longer forces Terraform to replace the instance
#
# NOTE: existing instances do NOT re-run provisioning when the S3 copy
# changes. Changes apply to newly launched instances, or run the script
# manually via SSM on running ones.
set -euo pipefail

%{ for k, v in env ~}
export ${k}="${v}"
%{ endfor ~}

# AWS CLI v2 (the awscli deb was removed from the Ubuntu archive in 24.04+);
# skipped when pre-baked into the AMI (see packer/)
if ! snap list aws-cli > /dev/null 2>&1; then
    snap wait system seed.loaded
    snap install aws-cli --classic
fi

# Fetch all provisioning scripts (retry: NAT/S3 may need a moment at boot)
mkdir -p /opt/provisioning
for attempt in 1 2 3 4 5; do
    if /snap/bin/aws s3 cp --region "${region}" --recursive --only-show-errors \
        "s3://${bucket}/scripts/" /opt/provisioning/scripts/; then
        break
    fi
    echo "S3 fetch failed (attempt $attempt/5); retrying in 15s..."
    sleep 15
done

if [ ! -f "/opt/provisioning/scripts/${script}" ]; then
    echo "FATAL: could not fetch provisioning scripts from s3://${bucket}"
    exit 1
fi

chmod -R u+x /opt/provisioning/scripts
exec bash "/opt/provisioning/scripts/${script}"
