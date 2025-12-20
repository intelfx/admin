#!/bin/bash

set -eo pipefail
shopt -s lastpipe

cd "${BASH_SOURCE%/*}"
. lib/lib.sh

host="$1"
dest="/mnt/data/Backups/Hosts"
password="$(< /etc/admin/keys/backup-mikrotik )"
identity="/etc/admin/keys/id_rsa_2048"

log "$0: backing up '$host' to '$dest'"

ssh_prep_parse_host
dest="$dest/$addr"
known_hosts="$dest/known_hosts"

ssh_prep -o PubkeyAcceptedAlgorithms=+ssh-rsa -o MACs=+hmac-sha1

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
rsync -rt --chmod=ugo=rwX "$tempdir"/ "$dest"/
