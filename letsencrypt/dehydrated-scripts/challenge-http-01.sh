#!/bin/bash

set -eo pipefail
shopt -s lastpipe

. "${BASH_SOURCE%/*}/lib/lib.sh"

_usage() {
	cat <<EOF
Usage: $0 [ARGS...]
EOF
}


#
# args
#

declare -A _args=(
	[-h|--help]=ARG_USAGE
	[--rootdir:]=ARG_ROOTDIR
	[--]=ARGS
)
parse_args _args "$@" || usage
[[ ! $ARG_USAGE ]] || usage

[[ -d "$ARG_ROOTDIR" && -w "$ARG_ROOTDIR" ]] \
	|| usage "--rootdir=${ARG_ROOTDIR@Q} is not writable or is not a directory"

case "${#ARGS[@]}" in
4)
	ARG_ACTION="${ARGS[0]}"
	ARG_DOMAIN="${ARGS[1]}"
	ARG_CHALLENGE_NAME="${ARGS[2]}"
	ARG_CHALLENGE_VALUE="${ARGS[3]}"
	;;
*)
	usage "expected 4 positional arguments, got ${#ARGS[@]}"
	;;
esac

CHALLENGE_FILE="$ARG_ROOTDIR/$ARG_CHALLENGE_NAME"


#
# main
#

LIBSH_LOG_PREFIX="HTTP-01[$ARG_DOMAIN]"

case "$ARG_ACTION" in
deploy_challenge)
	log "deploy_challenge: ${CHALLENGE_FILE@Q} <- ${ARG_CHALLENGE_VALUE@Q}"
	printf "%s" "$ARG_CHALLENGE_VALUE" >"$CHALLENGE_FILE"
	ls -la "$CHALLENGE_FILE" >&2
	;;

clean_challenge)
	log "clean_challenge: ${CHALLENGE_FILE@Q} (was: ${ARG_CHALLENGE_VALUE@Q})"
	if [[ -e "$CHALLENGE_FILE" ]]; then
		if OLD_VALUE="$(< "$CHALLENGE_FILE" )"; then
			if [[ "$OLD_VALUE" != "$ARG_CHALLENGE_VALUE" ]]; then
				die "challenge exists and contains unexpected value: expected ${ARG_CHALLENGE_VALUE@Q}, has ${OLD_VALUE@Q}"
			fi
		fi
	fi

	rm -vf "$CHALLENGE_FILE"
	;;

*)
	usage "expected either deploy_challenge or clean_challenge action, got ${ARG_ACTION@Q}"
	;;
esac
