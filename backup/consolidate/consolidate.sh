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
	realpath --strip "$1" | sed -r 's|^/|Z:\\|; s|/|\\|g'
}

if ! [[ -e "$1" ]]; then
	die "Target does not exist: $1"
fi

if ! [[ -e "$2" ]]; then
	die "Source does not exist: $2"
fi

ARG1="$(unix_to_wine "$1")"
ARG2="$(unix_to_wine "$2")"
CONSOLIDATE_LOG="$(unix_to_wine consolidate.log)"
WINE_LOG="$(realpath --strip wine.log)"

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
