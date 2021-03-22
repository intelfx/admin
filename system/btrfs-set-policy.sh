#!/bin/bash

set -eo pipefail
shopt -s lastpipe

. /etc/admin/scripts/lib/lib.sh || exit 1

MOUNTPOINT="$1"
if ! [[ -d "$MOUNTPOINT" ]]; then
	die "Bad mountpoint: '$MOUNTPOINT'"
fi

log "Mountpoint: $MOUNTPOINT"

FSID="$(df -P /mnt/data | awk 'END {print $1}' | xargs lsblk -no UUID)"
if ! [[ "$FSID" ]]; then
	die "Could not query fsid: '$MOUNTPOINT'"
fi

log "fsid: $FSID"

SYSFS="/sys/fs/btrfs/$FSID"
if ! echo roundrobin > "$SYSFS/read_policies/policy"; then
	die "Could not write to policy control file: '$SYSFS/read_policies/policy'"
fi
