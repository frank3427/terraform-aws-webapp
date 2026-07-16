#!/bin/bash
# Baked into the web-base AMI by Packer (see web-base.pkr.hcl).
# Pre-installs everything scripts/web_server_setup.sh would otherwise
# download at boot. That script stays the source of truth for
# configuration; this one only handles the slow package/binary work.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y

# Apache, PHP, EFS utilities (identical package set to web_server_setup.sh)
apt-get install -y \
    unattended-upgrades \
    apache2 \
    php \
    php-cli \
    php-common \
    php-mysql \
    php-zip \
    php-gd \
    php-mbstring \
    php-curl \
    php-xml \
    php-bcmath \
    libapache2-mod-php \
    nfs-common \
    jq

# AWS CLI v2 (the user-data bootstrap skips this when already present)
snap wait system seed.loaded
snap install aws-cli --classic

# Download a release tarball with retries and verify it against the
# release's sha256sums.txt (same helper as scripts/lib/fetch-release.sh)
fetch_release() {
    local base="$1" tarball="$2" sums attempt
    sums="$tarball.sums"
    for attempt in 1 2 3 4 5; do
        if wget -q -O "$tarball" "$base/$tarball"; then
            if wget -q -O "$sums" "$base/sha256sums.txt"; then
                if awk -v f="$tarball" '{ sub(/^\*/, "", $2) } $2 == f { print $1 "  " f }' "$sums" \
                    | sha256sum -c --status; then
                    rm -f "$sums"; return 0
                fi
                echo "ERROR: checksum mismatch for $tarball (attempt $attempt/5)" >&2
                rm -f "$tarball" "$sums"
            else
                echo "WARN: no sha256sums.txt for $tarball; proceeding unverified" >&2
                rm -f "$sums"; return 0
            fi
        fi
        echo "Download of $tarball failed (attempt $attempt/5); retrying in 15s..." >&2
        sleep 15
    done
    echo "FATAL: could not download and verify $tarball" >&2
    return 1
}

# Exporter binaries (versions must match scripts/web_server_setup.sh, which
# skips the download when the binary already exists)
NODE_EXPORTER_VERSION="1.8.2"
APACHE_EXPORTER_VERSION="1.0.8"
cd /tmp

fetch_release "https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION" \
    "node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz"
tar xzf node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
mv node_exporter-$NODE_EXPORTER_VERSION.linux-amd64/node_exporter /usr/local/bin/

fetch_release "https://github.com/Lusitaniae/apache_exporter/releases/download/v$APACHE_EXPORTER_VERSION" \
    "apache_exporter-$APACHE_EXPORTER_VERSION.linux-amd64.tar.gz"
tar xzf apache_exporter-$APACHE_EXPORTER_VERSION.linux-amd64.tar.gz
mv apache_exporter-$APACHE_EXPORTER_VERSION.linux-amd64/apache_exporter /usr/local/bin/

# Don't bake apt lists or temp files into the image
apt-get clean
rm -rf /tmp/node_exporter-* /tmp/apache_exporter-* /var/lib/apt/lists/*

echo "Web-base AMI bake completed"
