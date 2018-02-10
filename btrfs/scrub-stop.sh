#!/bin/bash

DEVICE="$1"
shift

echo "$DEVICE: scrub: stopping" >&2
btrfs scrub cancel "$@" "$DEVICE"

if (( $? == 2 )); then
	echo "$DEVICE: scrub: nothing to stop, ignoring" >&2
fi
