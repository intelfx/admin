#!/bin/bash -e

cd "${BASH_SOURCE%/*}"
. lib/lib.sh

host="$1"
dest="/mnt/data/Backups/Hosts"
identity="/etc/admin/keys/id_rsa"

ssh_prep
dest="$dest/$addr"

log "$0: backing up openwrt '$host' to '$dest'"
mkdir -p "$dest"

trap "rm -rf '$tempdir'" EXIT
tempdir="$(mktemp -d)"

do_ssh '/root/bin/opkg-get-user-overlay.sh > /root/packages.txt'
do_ssh 'sysupgrade -b -' > "$tempdir/backup.tar.gz"

rm -rf "$dest"/*
mv "$tempdir"/* "$dest"/
