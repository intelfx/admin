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

PHASE=
while (( $# )); do
	case "$1" in
	--init) PHASE=start; shift ;;
	--fini) PHASE=end; shift ;;
	-*) usage "invalid option: ${1@Q}" ;;
	*) break ;;
	esac
done

if (( $# < 1 )); then
	usage "expected at least 1 positional argument"
fi

FS_FILE="$1"
shift
REMOUNT_ARGS=( "$@" )

if ! [[ $PHASE ]]; then
	if [[ ${REMOUNT_ARGS+set} ]]
	then PHASE=start
	else PHASE=end
	fi
fi

#
# main
#

if ! realpath -qe "$FS_FILE" | IFS='' read -r FS_PATH; then
	die "${FS_FILE@Q}: failed to canonicalize path"
fi
if ! df "$FS_PATH" --output=target | tail -n-1 | IFS='' read -r FS_MOUNTPOINT; then
	die "${FS_PATH@Q}: failed to determine mountpoint"
fi

case "$PHASE" in
start)
	REMOUNT_ARGS=( --options-source fstab --options-mode prepend -o remount "${REMOUNT_ARGS[@]}" )
	set -x
	mount -v "$FS_MOUNTPOINT" "${REMOUNT_ARGS[@]}"
	sync -f "$FS_MOUNTPOINT"
	;;
end)
	REMOUNT_ARGS=( --options-source fstab --options-mode prepend -o remount "${REMOUNT_ARGS[@]}" )
	set -x
	sync -f "$FS_MOUNTPOINT"
	mount -v "$FS_MOUNTPOINT" "${REMOUNT_ARGS[@]}"
	;;
*)
	die "internal error: invalid phase: ${PHASE@Q}"
	;;
esac
