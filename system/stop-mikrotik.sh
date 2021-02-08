#!/bin/bash

. /etc/admin/scripts/lib/lib.sh || exit 1

HOSTNAME="$1"

log "stop-mikrotik.sh: stopping $HOSTNAME"

host="admin@$HOSTNAME"
identity="/etc/admin/keys/id_rsa"
ssh_prep
do_ssh '/system/shutdown'
