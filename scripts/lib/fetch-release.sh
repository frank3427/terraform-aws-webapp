#!/bin/bash
# Shared download helper for provisioning scripts.
#
# fetch_release <base_url> <tarball>
#   Downloads <base_url>/<tarball> into the current directory with retries
#   and verifies it against the release's sha256sums.txt. Hard-fails on a
#   checksum mismatch (possible tampering/corruption); if the sums file
#   itself is unavailable it warns and proceeds, since not every project
#   publishes one.
fetch_release() {
    local base="$1" tarball="$2"
    local attempt sums="$tarball.sums"

    for attempt in 1 2 3 4 5; do
        if wget -q -O "$tarball" "$base/$tarball"; then
            if wget -q -O "$sums" "$base/sha256sums.txt"; then
                if awk -v f="$tarball" '{ sub(/^\*/, "", $2) } $2 == f { print $1 "  " f }' "$sums" \
                    | sha256sum -c --status; then
                    rm -f "$sums"
                    return 0
                fi
                echo "ERROR: checksum mismatch for $tarball (attempt $attempt/5)" >&2
                rm -f "$tarball" "$sums"
            else
                echo "WARN: no sha256sums.txt published for $tarball; proceeding unverified" >&2
                rm -f "$sums"
                return 0
            fi
        fi
        echo "Download of $tarball failed (attempt $attempt/5); retrying in 15s..." >&2
        sleep 15
    done

    echo "FATAL: could not download and verify $tarball" >&2
    return 1
}
