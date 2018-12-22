#!/bin/bash -e

cd "${BASH_SOURCE%/*}"
. lib/lib.sh

host="$1"
dest="/mnt/data/Backups/Резервные копии сетевых устройств"
dest="$dest/$host"
password="$(< /etc/admin/backup-password )"

if ! [[ "$host" ]]; then
	die "mikrotik-backup.sh: host not provided, exiting"
fi

if ! ping -c 1 -w 5 -q "$host"; then
	die "mikrotik-backup.sh: host '$host' unresponsive, exiting"
fi

mkdir -p "$dest"

log "mikrotik-backup.sh: backing up '$host' to '$dest'"

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
	ssh "${SSH[@]}" ${hostport:+-p "$hostport"} restricted@"$hostaddr" "$@"
}

function do_sftp() {
	sftp "${SSH[@]}" ${hostport:+-P "$hostport"} restricted@"$hostaddr" "$@"
}

host_identity="$(do_ssh ":put [/system identity get name]" | tr -d '\r\n')"

if ! [[ "$host_identity" ]]; then
	die "mikrotik-backup.sh: host '$host' does not tell us its identity, exiting"
fi

trap "rm -rf '$tempdir'" EXIT
tempdir="$(mktemp -d)"

log "mikrotik-backup.sh: using identity '$host_identity' for host '$host'"

do_ssh <<-EOF
	/system backup save password="$password" name="auto-backup"
	/export compact file="auto-backup.rsc"
	/export verbose file="auto-backup-verbose.rsc"
EOF

do_sftp <<-EOF
	lcd "$tempdir"
	get auto-backup.backup "$host_identity.backup"
	get auto-backup.rsc "$host_identity.rsc"
	get auto-backup-verbose.rsc "$host_identity-verbose.rsc"
	rm auto-backup*
EOF

rm -rf "$dest"/*
mv "$tempdir"/* "$dest"/
