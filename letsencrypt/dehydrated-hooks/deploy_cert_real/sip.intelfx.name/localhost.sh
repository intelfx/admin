#!/bin/bash -e

. "${BASH_SOURCE%/*}/../common.sh" || exit

make_privkey_cert

ROUTR_DIR=/home/operator/routr
#ROUTR_CERTS_DIR="$ROUTR_DIR/etc/certs"

make_fullchain_privkey
make_pkcs12
#$ROUTR_DIR/jre/bin/keytool -importkeystore -srckeystore "$ROUTR_CERTS_DIR/domains-cert.p12" -srcstorepass "" -destkeystore "$ROUTR_CERTS_DIR/domains-cert.jks.new" -deststoretype jks -deststorepass "domains-cert.jks"
#mv -v "$ROUTR_CERTS_DIR/domains-cert.jks.new" "$ROUTR_CERTS_DIR/domains-cert.jks"

log "Reloading"
systemctl try-reload-or-restart routr
