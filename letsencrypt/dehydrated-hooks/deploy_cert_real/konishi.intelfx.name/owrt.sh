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

log "Pushing certificate to router"

scp -o IdentityFile="$DEST_IDENTITY" "$PRIVKEY" "$DEST_SSH_HOST":/etc/uhttpd.key
scp -o IdentityFile="$DEST_IDENTITY" "$FULLCHAIN" "$DEST_SSH_HOST":/etc/uhttpd.crt

log "Pushing certificate to router OK, now reloading"

ssh -o IdentityFile="$DEST_IDENTITY" "$DEST_SSH_HOST" '/etc/init.d/uhttpd reload'

log "Reloading certificate in router OK"
