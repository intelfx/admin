#!/bin/bash -e

DISK="$1"
ARGS=( "${@:2}" )

trap "rm -f '\$REPLY_FILE'" EXIT
REPLY_FILE="$(mktemp)"

set -o pipefail

function smartctl_c_completed() {
	if ! smartctl -c "$DISK" | grep -E -A 1 '^Self-test execution status:' | tee "$REPLY_FILE"; then
		rc="${PIPESTATUS[0]}"
		echo "E: failed to run smartctl -c $DISK, rc = $rc"
		exit $rc
	fi

	STATUS_BYTE="$(sed -nre 's|^Self-test execution status: *\( *([0-9]+)\).*|\1|p' "$REPLY_FILE")"
	if [[ "$STATUS_BYTE" ]]; then
		if (( STATUS_BYTE < 240 )); then
			echo "N: self-test completed, rc = $STATUS_BYTE"
			return 0
		else
			echo "N: self-test in progress, rc = $STATUS_BYTE"
			return 1
		fi
	else
		echo "E: failed to parse smartctl output"
		exit 1
	fi
}

function smartctl_run_and_wait() {
	if ! smartctl "${ARGS[@]}" "$DISK" | tee "$REPLY_FILE"; then
		rc=${PIPESTATUS[0]}
		echo "E: failed to start smartctl ${ARGS[*]} $DISK, rc = $rc"
		exit $rc
	fi

	ETE=$(sed -nre 's|^Please wait ([0-9]+) minutes for test to complete.$|\1|p' "$REPLY_FILE")

	if [[ "$ETE" ]]; then
		echo "N: waiting $ETE minutes"
		sleep ${ETE}m
	else
		echo "W: failed to parse smartctl output"
	fi
}

if ! smartctl_c_completed; then
	echo "E: a selftest is already in progress"
	exit 0
fi

smartctl_run_and_wait

origETE=$ETE
ETE=1
while :; do
	echo "N: additionally waiting $ETE minutes"
	sleep ${ETE}m

	if smartctl_c_completed; then
		break
	fi

	# cap at first 2^N greater than reported ETE
	if (( ETE < origETE )); then
		(( ETE *= 2 ))
	fi
done

smartctl -l selftest "$DISK"
exit "$STATUS_BYTE"
