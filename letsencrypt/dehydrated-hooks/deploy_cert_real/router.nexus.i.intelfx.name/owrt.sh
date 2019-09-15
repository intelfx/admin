#!/bin/bash -e

. "${BASH_SOURCE%/*}/lib/lib.sh" || exit

ACTION="$1"
SUBDOMAIN="$2"
PRIVKEY="$3"
CERT="$4"
FULLCHAIN="$5"
CHAIN="$6"
TIMESTAMP="$7"

host="root@router.nexus.i.intelfx.name"
identity="/etc/admin/keys/id_rsa"

log "$0: pushing cert to openwrt '$host'"

ssh_prep

log "$0: copying cert via sftp"

do_sftp <<-EOF
	put "$PRIVKEY" /etc/uhttpd.key
	put "$FULLCHAIN" /etc/uhttpd.crt
EOF

log "$0: copying OK, now reloading"

do_ssh '/etc/init.d/uhttpd reload'

log "$0: reloading OK"
