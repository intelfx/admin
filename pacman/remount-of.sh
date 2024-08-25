#!/bin/bash

#!/bin/bash

set -eo pipefail
shopt -s lastpipe

log() {
	echo ":: $*" >&2
}

err() {
	echo "E: $*" >&2
}

die() {
	err "$@"
	exit 1
}

usage() {
	if (( $# )); then
		echo "${0##*/}: $*" >&2
		echo >&2
	fi
	_usage >&2
	exit 1
}

_usage() {
	cat <<EOF
Usage: ${0##*/} CONTAINED-FILE [MOUNT-ARGS...]
EOF
}


#
# args
#

if (( $# < 1 )); then
	usage "expected at least 1 positional argument"
fi

FS_FILE="$1"
shift
REMOUNT_ARGS=( "$@" )

#
# main
#

if ! realpath -qe "$FS_FILE" | IFS='' read -r FS_PATH; then
	die "${FS_FILE@Q}: failed to canonicalize path"
fi
if ! df "$FS_PATH" --output=target | tail -n-1 | IFS='' read -r FS_MOUNTPOINT; then
	die "${FS_PATH@Q}: failed to determine mountpoint"
fi

if [[ ${REMOUNT_ARGS+set} ]]; then
	# log "${FS_PATH@Q}: remounting ${FS_MOUNTPOINT@Q} with ${REMOUNT_ARGS[@]@Q}"
	REMOUNT_ARGS=( --options-source fstab --options-mode prepend -o remount "${REMOUNT_ARGS[@]}" )
	set -x
	mount -v "$FS_MOUNTPOINT" "${REMOUNT_ARGS[@]}"
	sync -f "$FS_MOUNTPOINT"
else
	# log "${FS_PATH@Q}: remounting ${FS_MOUNTPOINT@Q} with fstab options"
	REMOUNT_ARGS=( --options-source fstab --options-mode prepend -o remount "${REMOUNT_ARGS[@]}" )
	set -x
	sync -f "$FS_MOUNTPOINT"
	mount -v "$FS_MOUNTPOINT" "${REMOUNT_ARGS[@]}"
fi
