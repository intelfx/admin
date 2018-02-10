#!/bin/bash -e

. "${BASH_SOURCE%/*}/lib/lib.sh" || exit

ACTION="$1"
SUBDOMAIN="$2"
PRIVKEY="$3"
CERT="$4"
FULLCHAIN="$5"
CHAIN="$6"
TIMESTAMP="$7"

DEST_IDENTITY="/etc/admin/id_rsa"
DEST_SSH_HOST="restricted@router.9-20.lan"

log "Pushing certificate to router"

scp -o IdentityFile="$DEST_IDENTITY" "$PRIVKEY" "$DEST_SSH_HOST":/https.key
scp -o IdentityFile="$DEST_IDENTITY" "$FULLCHAIN" "$DEST_SSH_HOST":/https.crt

log "Pushing certificate to router OK, now reloading"

ssh -o IdentityFile="$DEST_IDENTITY" "$DEST_SSH_HOST" <<-EOF
	/certificate remove https
	/certificate import file-name=https.crt passphrase=""
	/certificate import file-name=https.key passphrase=""
	:delay 1
	/certificate set https.crt_0 name=https
	/ip service set www-ssl certificate=https
	/file remove https.crt
	/file remove https.key
EOF

log "Reloading certificate in router OK"
