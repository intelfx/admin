#!/bin/bash

set -eo pipefail
shopt -s lastpipe

. "${BASH_SOURCE%/*}/lib/lib.sh"

if (( $# != 2 )); then
	err "Expected 2 arguments, got $#"
	err "Usage: $0 <full> <incremental>"
	exit 1
fi

unix_to_wine() {
	realpath --canonicalize-missing --strip "$1" | sed -r 's|^/|Z:\\|; s|/|\\|g'
}

ARG1="$(unix_to_wine "$1")"
ARG2="$(unix_to_wine "$2")"
CONSOLIDATE_LOG="$(unix_to_wine consolidate.log)"
WINE_LOG="$(realpath --canonicalize-missing --strip "wine.log")"

rm -f consolidate.log wine.log
touch consolidate.log
tail --follow consolidate.log >&2 &
tail_pid=$!
cleanup() {
	kill "$tail_pid"
}
trap cleanup EXIT TERM HUP INT

cd "${BASH_SOURCE%/*}"

CMDLINE=(
	/usr/bin/env
	LC_ALL=C
	/usr/bin/wine
	./AutoHotkeyU64.exe
	consolidate.ahk
	"$ARG1"
	"$ARG2"
	"$CONSOLIDATE_LOG"
)

log "Starting: ${CMDLINE[@]}"
startx "${CMDLINE[@]}" -- /usr/bin/Xvnc :9 &>"$WINE_LOG"
