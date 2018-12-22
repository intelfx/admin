#!/bin/bash -e

cd "${BASH_SOURCE%/*}"
. lib/lib.sh

host="$1"
dest="/mnt/data/Backups/Резервные копии сетевых устройств"
dest="$dest/$host"

if ! [[ "$host" ]]; then
	die "backup-pull-openwrt.sh: host not provided, exiting"
fi

if ! ping -c 1 -w 5 -q "$host"; then
	die "backup-pull-openwrt.sh: host '$host' unresponsive, exiting"
fi

mkdir -p "$dest"

log "backup-pull-openwrt.sh: backing up '$host' to '$dest'"

hostaddr="$host"
if [[ "$host" == *:* ]]; then
	hostaddr="${host%:*}"
	hostport="${host##*:}"
fi

SSH=(
	-o StrictHostKeyChecking=accept-new
	-i /etc/admin/id_rsa
)

function do_ssh() {
	ssh "${SSH[@]}" ${hostport:+-p "$hostport"} root@"$hostaddr" "$@"
}

function do_sftp() {
	sftp "${SSH[@]}" ${hostport:+-P "$hostport"} root@"$hostaddr" "$@"
}

trap "rm -rf '$tempdir'" EXIT
tempdir="$(mktemp -d)"

log "backup-pull-openwrt.sh: using host '$host'"

do_ssh '/root/bin/opkg-get-user-overlay.sh > /root/packages.txt'
do_ssh 'sysupgrade -b -' > "$tempdir/backup.tar.gz"

rm -rf "$dest"/*
mv "$tempdir"/* "$dest"/
