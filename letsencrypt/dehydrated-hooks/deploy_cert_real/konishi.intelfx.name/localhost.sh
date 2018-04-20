#!/bin/bash -e

. "${BASH_SOURCE%/*}/lib/lib.sh" || exit


ACTION="$1"
SUBDOMAIN="$2"
PRIVKEY="$3"
CERT="$4"
FULLCHAIN="$5"
CHAIN="$6"
TIMESTAMP="$7"

BASEDIR="${CERT%/*}"

log "Creating privkey+cert"
PEM_BUNDLE="privkey+cert-${TIMESTAMP}.pem"
PEM_BUNDLE_LINK="privkey+cert.pem"
cat "$PRIVKEY" "$CERT" > "${BASEDIR}/${PEM_BUNDLE}"
ln -sf "${PEM_BUNDLE}" "${BASEDIR}/${PEM_BUNDLE_LINK}"

log "Reloading"
systemctl try-reload-or-restart lighttpd synapse turnserver
