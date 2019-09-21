#!/bin/bash -e

. "${BASH_SOURCE%/*}/lib/lib.sh" || exit

ACTION="$1"
SUBDOMAIN="$2"
PRIVKEY="$3"
CERT="$4"
FULLCHAIN="$5"
CHAIN="$6"
#TIMESTAMP="$7"

identity="/etc/admin/keys/id_rsa"
host="restricted@router.sovereign.i.intelfx.name"

log "$0: pushing cert to mikrotik '$host'"

ssh_prep

log "$0: copying cert via sftp"

do_sftp <<-EOF
	put "$PRIVKEY" /https.key
	put "$FULLCHAIN" /https.crt
EOF

log "$0: copying OK, now reloading"

do_ssh <<-EOF
	/certificate remove https
	/certificate import file-name=https.crt passphrase=""
	/certificate import file-name=https.key passphrase=""
	:delay 1
	/certificate set https.crt_0 name=https
	/ip service set www-ssl certificate=https
	/file remove https.crt
	/file remove https.key
EOF

log "$0: reloading OK"
