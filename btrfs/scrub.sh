#!/bin/bash

DEVICE="$1"
shift

echo "$DEVICE: scrub: resuming" >&2
btrfs scrub resume "$@" "$DEVICE"

if (( $? == 2 )); then
	echo "$DEVICE: scrub: nothing to resume, starting" >&2
	btrfs scrub start "$@" "$DEVICE"
fi
