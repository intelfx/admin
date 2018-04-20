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
DEST_SSH_HOST="restricted@conceptory.intelfx.name"
DEST_SSH_PORT="2222"

ssh_args=(
	-o IdentityFile="$DEST_IDENTITY"
	-o StrictHostKeyChecking=accept-new
)

ssh=(
	ssh
	"${ssh_args[@]}"
)

scp=(
	scp
	"${ssh_args[@]}"
)

log "Pushing certificate to router"

"${scp[@]}" -P "$DEST_SSH_PORT" "$PRIVKEY" "$DEST_SSH_HOST":/https.key
"${scp[@]}" -P "$DEST_SSH_PORT" "$FULLCHAIN" "$DEST_SSH_HOST":/https.crt

log "Pushing certificate to router OK, now reloading"

"${ssh[@]}" "$DEST_SSH_HOST" -p "$DEST_SSH_PORT" <<-EOF
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
