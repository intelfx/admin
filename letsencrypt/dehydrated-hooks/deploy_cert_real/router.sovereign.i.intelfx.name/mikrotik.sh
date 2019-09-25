#!/bin/bash -e

. "${BASH_SOURCE%/*}/../common.sh" || exit

identity="/etc/admin/keys/id_rsa"
host="restricted@router.sovereign.i.intelfx.name"

ssh_cert_to_routeros
