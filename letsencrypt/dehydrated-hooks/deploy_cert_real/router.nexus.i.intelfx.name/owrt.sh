#!/bin/bash -e

. "${BASH_SOURCE%/*}/../common.sh" || exit

host="root@router.nexus.i.intelfx.name"
identity="/etc/admin/keys/id_ed25519"

ssh_cert_to_openwrt
