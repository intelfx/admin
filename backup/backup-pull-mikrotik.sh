#!/bin/bash -e

cd "${BASH_SOURCE%/*}"
. lib/lib.sh

host="$1"
dest="/mnt/data/Backups/Hosts"
password="$(< /etc/admin/keys/backup-mikrotik )"
identity="/etc/admin/keys/id_rsa"

ssh_prep
dest="$dest/$addr"

log "$0: backing up '$host' to '$dest'"
mkdir -p "$dest"

trap "rm -rf '$tempdir'" EXIT
tempdir="$(mktemp -d)"

host_identity="$(do_ssh ":put [/system identity get name]" | tr -d '\r\n')"

if ! [[ "$host_identity" ]]; then
	die "$0: host '$host' does not tell us its identity, exiting"
fi

log "$0: using identity '$host_identity' for host '$host'"

do_ssh <<-EOF
	/system backup save password="$password" name="auto-backup"
EOF
	#/export compact file="auto-backup.rsc"
	#/export verbose file="auto-backup-verbose.rsc"

do_sftp <<-EOF
	lcd "$tempdir"
	get auto-backup.backup "$host_identity.backup"
	rm auto-backup*
EOF
	#get auto-backup.rsc "$host_identity.rsc"
	#get auto-backup-verbose.rsc "$host_identity-verbose.rsc"

rm -rf "$dest"/*
rsync -rt --delete "$tempdir"/ "$dest"/
