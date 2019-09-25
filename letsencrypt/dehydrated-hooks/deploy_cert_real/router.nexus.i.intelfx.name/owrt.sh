#!/bin/bash -e

. "${BASH_SOURCE%/*}/../common.sh" || exit

host="root@router.nexus.i.intelfx.name"
identity="/etc/admin/keys/id_rsa"

ssh_cert_to_openwrt
