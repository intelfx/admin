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
DEST_SSH_HOST="root@konishi.intelfx.name"
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

"${scp[@]}" -P "$DEST_SSH_PORT" "$PRIVKEY" "$DEST_SSH_HOST":/etc/uhttpd.key
"${scp[@]}" -P "$DEST_SSH_PORT" "$FULLCHAIN" "$DEST_SSH_HOST":/etc/uhttpd.crt

log "Pushing certificate to router OK, now reloading"

"${ssh[@]}" -p "$DEST_SSH_PORT" "$DEST_SSH_HOST" '/etc/init.d/uhttpd reload'

log "Reloading certificate in router OK"
