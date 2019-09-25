#!/bin/bash -e

. "${BASH_SOURCE%/*}/../common.sh" || exit

make_privkey_cert

log "Reloading"
systemctl try-reload-or-restart nginx turnserver
