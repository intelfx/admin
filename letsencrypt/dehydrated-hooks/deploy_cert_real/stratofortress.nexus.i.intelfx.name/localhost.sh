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

if ! [[ $TIMESTAMP ]]; then
	warn "Timestamp is empty, working around"
	if [[ $(readlink "$PRIVKEY") =~ ([0-9]+)\.pem ]]; then
		TIMESTAMP="${BASH_REMATCH[1]}"
		warn "Using timestamp $TIMESTAMP"
	else
		die "Timestamp is empty, could not work around"
	fi
fi

log "Creating privkey+cert"
PEM_BUNDLE="privkey+cert-${TIMESTAMP}.pem"
PEM_BUNDLE_LINK="privkey+cert.pem"
cat "$PRIVKEY" "$CERT" > "${BASEDIR}/${PEM_BUNDLE}"
ln -sf "${PEM_BUNDLE}" "${BASEDIR}/${PEM_BUNDLE_LINK}"

log "Reloading"
systemctl try-reload-or-restart nginx turnserver
