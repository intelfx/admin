#!/bin/bash

set -eo pipefail
shopt -s lastpipe

cd "${BASH_SOURCE%/*}"
. lib/lib.sh

host="$1"
dest="/mnt/data/Backups/Hosts"
password="$(< /etc/admin/keys/backup-mikrotik )"
identity="/etc/admin/keys/id_rsa"

log "$0: backing up '$host' to '$dest'"

ssh_prep_parse_host
dest="$dest/$addr"
known_hosts="$dest/known_hosts"

ssh_prep -o PubkeyAcceptedAlgorithms=+rsa-sha2-256

trap "rm -rf '$tempdir'" EXIT
tempdir="$(mktemp -d)"

do_ssh <<-EOF
	/system backup save password="$password" name="auto-backup"
	/export compact file="auto-export.rsc"
	/export verbose file="auto-export-verbose.rsc"
EOF

do_sftp <<-EOF
	lcd "$tempdir"
	get auto-backup.backup
	get auto-export.rsc "auto-export.rsc"
	get auto-export-verbose.rsc "auto-export-verbose.rsc"
	rm auto-backup*
EOF

mkdir -p "$dest"
rsync -rt --chmod=ugo=rwX "$tempdir"/ "$dest"/
