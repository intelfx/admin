#!/bin/bash

. "${BASH_SOURCE%/*}/lib/lib.sh" || exit
. "${BASH_SOURCE%/*}/dehydrated-lib.sh" || exit

# raise priority of our logs
_LIBSH_PRIO[log]=notice

# set path to gcloud
source /etc/profile.d/google-cloud-*.sh

#
# functions
#

make_privkey_cert() {
	log "Creating privkey+cert"
	PEM_BUNDLE="privkey+cert-${TIMESTAMP}.pem"
	PEM_BUNDLE_LINK="privkey+cert.pem"
	cat "$PRIVKEY" "$CERT" > "${BASEDIR}/${PEM_BUNDLE}"
	ln -sf "${PEM_BUNDLE}" "${BASEDIR}/${PEM_BUNDLE_LINK}"
}

make_fullchain_privkey() {
	log "Creating fullchain+privkey"
	PEM_BUNDLE="fullchain+privkey-${TIMESTAMP}.pem"
	PEM_BUNDLE_LINK="fullchain+privkey.pem"
	cat "$FULLCHAIN" "$PRIVKEY" > "$BASEDIR/$PEM_BUNDLE"
	ln -sf "$PEM_BUNDLE" "$BASEDIR/$PEM_BUNDLE_LINK"
}

make_pkcs12() {
	log "Creating PKCS12 keystore"
	PKCS12_FILE="keystore-${TIMESTAMP}.p12"
	PKCS12_FILE_LINK="keystore.p12"
	# write to stdout and redirect because otherwise openssl chmods output 0600 and breaks ACLs
	openssl pkcs12 -export -in "$FULLCHAIN" -inkey "$PRIVKEY" -out - -name "$SUBDOMAIN" -passout pass: > "$BASEDIR/$PKCS12_FILE"
	ln -sf "$PKCS12_FILE" "$BASEDIR/$PKCS12_FILE_LINK"
}

deploy_prep() {
	ACTION="$1"
	SUBDOMAIN="$2"
	PRIVKEY="$3"
	CERT="$4"
	FULLCHAIN="$5"
	CHAIN="$6"
	TIMESTAMP="$7"

	BASEDIR="${CERT%/*}"

	if ! [[ $TIMESTAMP ]]; then
		dbg "Timestamp is empty, working around"
		if [[ $(readlink "$PRIVKEY") =~ ([0-9]+)\.pem ]]; then
			TIMESTAMP="${BASH_REMATCH[1]}"
			dbg "Using timestamp $TIMESTAMP"
		else
			die "Timestamp is empty, could not work around"
		fi
	fi
}

deploy_localhost() {
	local LIBSH_LOG_PREFIX="deploy_localhost"

	deploy_prep "$@"
	make_privkey_cert

	log "Reloading services"
	systemctl try-reload-or-restart \
		nginx.service \
		turnserver.service
}

deploy_pikvm() {
	local LIBSH_LOG_PREFIX="deploy_pikvm($1)"
	local host="$1"
	local identity="$2"
	shift 2

	deploy_prep "$@"
	ssh_prep

	log "copying cert via sftp"
	do_ssh 'rw'
	do_sftp <<-EOF
		put "$PRIVKEY" /etc/kvmd/nginx/ssl/server.key
		put "$FULLCHAIN" /etc/kvmd/nginx/ssl/server.crt
	EOF
	# HACK: trigger update of the Tailscale cert (also LE, but done autonomously)
	log "HACK: triggering autonomous update for tailscale"
	do_ssh "systemctl start tailscale-cert.service"

	log "copying OK, now reloading"
	do_ssh 'systemctl reload kvmd-nginx'
	do_ssh 'ro || true'

	log "reloading OK"
}

deploy_openwrt() {
	local LIBSH_LOG_PREFIX="deploy_openwrt($1)"
	local host="$1"
	local identity="$2"
	shift 2

	deploy_prep "$@"
	ssh_prep

	log "copying cert via sftp"

	do_sftp <<-EOF || die 'failed to upload cert'
		put "$PRIVKEY" /etc/uhttpd.key
		put "$FULLCHAIN" /etc/uhttpd.crt
	EOF

	log "copying OK, now reloading"

	do_ssh '/etc/init.d/uhttpd reload'

	log "reloading OK"
}

deploy_outpost() {
	local LIBSH_LOG_PREFIX="deploy_openwrt($1)"
	local host="$1"
	local identity="$2"
	shift 2

	deploy_prep "$@"
	ssh_prep

	log "copying cert via sftp"

	do_sftp <<-EOF || die 'failed to upload cert'
		put "$PRIVKEY" /etc/admin/certs/outpost.intelfx.name.key
		put "$FULLCHAIN" /etc/admin/certs/outpost.intelfx.name.crt
	EOF

	log "copying OK, now reloading"

	do_ssh 'systemctl try-reload-or-restart turnserver'

	log "reloading OK"
}

deploy_routeros() {
	local LIBSH_LOG_PREFIX="deploy_routeros($1)"
	local host="$1"
	local identity="$2"
	shift 2

	deploy_prep "$@"
	ssh_prep

	log "copying cert via sftp"

	do_sftp <<-EOF
		put "$PRIVKEY" /https.key
		put "$FULLCHAIN" /https.crt
	EOF

	log "copying OK, now reloading"

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

	log "reloading OK"
}

#
# main
#

if [[ $1 == playbook ]]; then
	run_playbook
	exit
fi

hookdir="${BASH_SOURCE%/*}"

hook -E '(deploy|clean)_challenge' '.*intelfx\.name' \
	-- "$hookdir"/dehydrated-scripts/challenge-dns-01.py --config /etc/admin/dns/intelfx.name.yaml --
hook -EP '(deploy|unchanged)_cert' stratofortress.nexus.i.intelfx.name \
	-- deploy_localhost
hook -EP '(deploy|unchanged)_cert' sentinel.nexus.i.intelfx.name \
	-- deploy_pikvm root@sentinel.nexus.i.intelfx.name /etc/admin/keys/id_ed25519
#hook -EP '(deploy|unchanged)_cert' router.ditaeon.i.intelfx.name \
#	-- deploy_openwrt root@router.ditaeon.i.intelfx.name /etc/admin/keys/id_ed25519
#hook -EP '(deploy|unchanged)_cert' router.sovereign.i.intelfx.name \
#	-- deploy_routeros admin@router.sovereign.i.intelfx.name /etc/admin/keys/id_rsa
hook -EP '(deploy|unchanged)_cert' router.nexus.i.intelfx.name \
	-- deploy_openwrt root@router.nexus.i.intelfx.name /etc/admin/keys/id_ed25519
hook -EP '(deploy|unchanged)_cert' outpost.intelfx.name \
	-- deploy_outpost root@outpost.intelfx.name /etc/admin/keys/id_ed25519

run_actions
