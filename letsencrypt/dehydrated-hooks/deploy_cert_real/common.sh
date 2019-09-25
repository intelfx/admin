#!/hint/bash

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

function make_privkey_cert() {
	log "Creating privkey+cert"
	PEM_BUNDLE="privkey+cert-${TIMESTAMP}.pem"
	PEM_BUNDLE_LINK="privkey+cert.pem"
	cat "$PRIVKEY" "$CERT" > "${BASEDIR}/${PEM_BUNDLE}"
	ln -sf "${PEM_BUNDLE}" "${BASEDIR}/${PEM_BUNDLE_LINK}"
}

function make_fullchain_privkey() {
	log "Creating fullchain+privkey"
	PEM_BUNDLE="fullchain+privkey-${TIMESTAMP}.pem"
	PEM_BUNDLE_LINK="fullchain+privkey.pem"
	cat "$FULLCHAIN" "$PRIVKEY" > "$BASEDIR/$PEM_BUNDLE"
	ln -sf "$PEM_BUNDLE" "$BASEDIR/$PEM_BUNDLE_LINK"
}

function make_pkcs12() {
	log "Creating PKCS12 keystore"
	PKCS12_FILE="keystore-${TIMESTAMP}.p12"
	PKCS12_FILE_LINK="keystore.p12"
	# write to stdout and redirect because otherwise openssl chmods output 0600 and breaks ACLs
	openssl pkcs12 -export -in "$FULLCHAIN" -inkey "$PRIVKEY" -out - -name "$SUBDOMAIN" -passout pass: > "$BASEDIR/$PKCS12_FILE"
	ln -sf "$PKCS12_FILE" "$BASEDIR/$PKCS12_FILE_LINK"
}

function ssh_cert_to_routeros() {
	log "$0: pushing cert to routeros at '$host'"

	ssh_prep

	log "$0: copying cert via sftp"

	do_sftp <<-EOF
		put "$PRIVKEY" /https.key
		put "$FULLCHAIN" /https.crt
	EOF

	log "$0: copying OK, now reloading"

	do_ssh <<-EOF
		/certificate remove https
		/certificate import file-name=https.crt passphrase=""
		/certificate import file-name=https.key passphrase=""
		:delay 1
		/certificate set https.crt_0 name=https
		/ip service set www-ssl certificate=https
		/file remove https.crt
		/file remove https.key
	EOF

	log "$0: reloading OK"
}

function ssh_cert_to_openwrt() {
	log "$0: pushing cert to openwrt '$host'"

	ssh_prep

	log "$0: copying cert via sftp"

	do_sftp <<-EOF
		put "$PRIVKEY" /etc/uhttpd.key
		put "$FULLCHAIN" /etc/uhttpd.crt
	EOF

	log "$0: copying OK, now reloading"

	do_ssh '/etc/init.d/uhttpd reload'

	log "$0: reloading OK"
}
