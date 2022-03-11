#!/bin/bash -e

cd "${BASH_SOURCE%/*}"
. lib/lib.sh

host="$1"
dest="/mnt/data/Backups/Hosts"
password="$(< /etc/admin/keys/backup-mikrotik )"
identity="/etc/admin/keys/id_rsa"

log "$0: backing up '$host' to '$dest'"

ssh_prep -o PubkeyAcceptedAlgorithms=+ssh-rsa
dest="$dest/$addr"

trap "rm -rf '$tempdir'" EXIT
tempdir="$(mktemp -d)"

do_ssh <<-EOF
	/system backup save password="$password" name="auto-backup"
EOF
	#/export compact file="auto-backup.rsc"
	#/export verbose file="auto-backup-verbose.rsc"

do_sftp <<-EOF
	lcd "$tempdir"
	get auto-backup.backup
	rm auto-backup*
EOF
	#get auto-backup.rsc "$host_identity.rsc"
	#get auto-backup-verbose.rsc "$host_identity-verbose.rsc"

mkdir -p "$dest"
rm -rf "$dest"/*
rsync -rt --delete "$tempdir"/ "$dest"/
