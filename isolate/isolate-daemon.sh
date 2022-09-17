#!/bin/bash

. /etc/admin/scripts/lib/lib.sh || exit 1

enable -f /usr/lib/bash/sleep sleep

CGROUP_NAME="kthread.slice"
TIMEOUT=1

[[ "$CGROUP_NAME" ]] || die "Bad cgroup name (not given)"

CGROUP_PATH="$(realpath -qm /sys/fs/cgroup/$CGROUP_NAME)"

declare -A FAILED_TIDS

while :; do
	if ! [[ -d "$CGROUP_PATH" ]]; then
		die "Cgroup disappeared: $CGROUP_NAME ($CGROUP_PATH)"
	fi

	if [[ $(< "$CGROUP_PATH/cgroup.type") != threaded ]] && \
	   ! echo threaded > "$CGROUP_PATH/cgroup.type"; then
		die "Cannot set cgroup type: cgroup.type = threaded"
	fi

	errs=0
	while read tid; do
		if ! echo $tid > "$CGROUP_PATH/cgroup.threads" 2>/dev/null; then
			if ! [[ ${FAILED_TIDS[$tid]} ]]; then
				(( ++errs ))
			fi
			FAILED_TIDS[$tid]=1
		else
			unset FAILED_TIDS[$tid]
			log "Moved [/sys/fs/cgroup -> $CGROUP_PATH]: $tid"
		fi
	done < /sys/fs/cgroup/cgroup.threads
	if (( errs )); then
		err "Failed to move $errs new threads"
	fi

	sleep "$TIMEOUT"
done
