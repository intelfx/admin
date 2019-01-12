#!/bin/bash -e

cd "${BASH_SOURCE%/*}"
. lib/lib.sh

host="$1"
dest="/mnt/data/Backups/Резервные копии сетевых устройств"
dest="$dest/$host"
identity="/etc/admin/keys/id_rsa"

log "$0: backing up openwrt '$host' to '$dest'"
mkdir -p "$dest"

ssh_prep

trap "rm -rf '$tempdir'" EXIT
tempdir="$(mktemp -d)"

do_ssh '/root/bin/opkg-get-user-overlay.sh > /root/packages.txt'
do_ssh 'sysupgrade -b -' > "$tempdir/backup.tar.gz"

rm -rf "$dest"/*
mv "$tempdir"/* "$dest"/
