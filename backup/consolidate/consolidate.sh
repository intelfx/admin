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

ARG1_PATH="$(realpath --strip "$1")"
ARG2_PATH="$(realpath --strip "$2")"
ARG2_MTIME="$(stat -c '%.Y' "$2")"

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
	WINEPREFIX=/etc/admin/wineprefix
	/usr/bin/wine
	./AutoHotkeyU64.exe
	consolidate.ahk
	"$ARG1"
	"$ARG2"
	"$CONSOLIDATE_LOG"
)

log "Starting: ${CMDLINE[@]}"
xinit "${CMDLINE[@]}" -- /usr/bin/Xvnc :9 -auth /etc/admin/Xauthority 2>"$WINE_LOG"

if [[ -e "$ARG1_PATH" && -e "$ARG2_PATH" ]]; then
	err "Consolidation failure -- both files still exist"
	exit 1
elif [[ -e "$ARG1_PATH" ]]; then
	# arg1 is full, arg2 is incremental
	log "Resetting target mtime"
	touch -d "@$ARG2_MTIME" "$ARG1_PATH" || true
elif [[ -e "$ARG2_PATH" ]]; then
	# both arg1 and arg2 are incremental -- consolidate.exe deletes source and renames target to source
	log "Resetting target mtime"
	touch -d "@$ARG2_MTIME" "$ARG2_PATH" || true
else
	err "Consolidation failure -- neither file exists"
	exit 1
fi
