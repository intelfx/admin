#!/bin/bash -e

DISK="$1"
ARGS=( "${@:2}" )

trap "rm -f '$REPLY_FILE'" EXIT
REPLY_FILE="$(mktemp)"

set -o pipefail
if ! smartctl -c "$DISK" | grep -E -A 1 '^Self-test execution status:' | tee "$REPLY_FILE"; then
	rc="${PIPESTATUS[0]}"
	echo "W: failed to run smartctl -c $DISK, rc = $rc"
	NEED_STOP=1
fi

STATUS_BYTE="$(sed -nre 's|^Self-test execution status: *\( *([0-9]+)\).*|\1|p' "$REPLY_FILE")"
if [[ "$STATUS_BYTE" ]]; then
	if ! (( STATUS_BYTE < 240 )); then
		NEED_STOP=1
	fi
else
	echo "W: failed to parse smartctl -c output"
	NEED_STOP=1
fi

if (( NEED_STOP )); then
	echo "N: aborting a self-test in progress"
	smartctl -X "$DISK"
fi
