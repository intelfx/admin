#!/bin/bash -e

. "${BASH_SOURCE%/*}/../common.sh" || exit

make_fullchain_privkey

log "Reloading"
systemctl try-reload-or-restart nginx mongooseim
