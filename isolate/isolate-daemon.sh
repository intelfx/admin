#!/bin/bash

. /etc/admin/scripts/lib/lib.sh || exit 1

enable -f /usr/lib/bash/sleep sleep

CGROUP_NAME="kthread.slice"
TIMEOUT=1

[[ "$CGROUP_NAME" ]] || die "Bad cgroup name (not given)"

ROOT_PATH="/sys/fs/cgroup"
CGROUP_PATH="$(realpath -qm /sys/fs/cgroup/$CGROUP_NAME)"

declare -a THREADS
declare -A FAILED_TIDS
declare -A SEEN_TIDS


while :; do
	if ! [[ -d "$CGROUP_PATH" ]]; then
		die "Cgroup disappeared: $CGROUP_NAME ($CGROUP_PATH)"
	fi

	if [[ $(< "$CGROUP_PATH/cgroup.type") != threaded ]] && \
	   ! echo threaded > "$CGROUP_PATH/cgroup.type"; then
		die "Cannot set cgroup type: cgroup.type = threaded"
	fi

	SEEN_TIDS=()
	moves=0
	errs=0

	readarray -t THREADS < "$ROOT_PATH/cgroup.threads"
	for tid in "${THREADS[@]}"; do
		SEEN_TIDS[$tid]=1

		if [[ ${FAILED_TIDS[$tid]} ]]; then
			continue
		fi

		if ! echo $tid > "$CGROUP_PATH/cgroup.threads" 2>/dev/null; then
			err "Failed: $tid ($(</proc/$tid/comm))"
			FAILED_TIDS[$tid]=1
			(( ++errs ))
		else
			log "Moved [$ROOT_PATH -> $CGROUP_PATH]: $tid ($(</proc/$tid/comm))"
			(( ++moves ))
		fi
	done

	# forget non-existent tids
	for tid in "${!FAILED_TIDS[@]}"; do
		if ! [[ ${SEEN_TIDS[$tid]} ]]; then
			log "Disappeared: $tid (previously failed)"
			unset FAILED_TIDS[$tid]
		fi
	done

	if (( moves )); then
		log "Moved $moves new threads"
	fi
	if (( errs )); then
		err "Failed to move $errs new threads"
	fi

	sleep "$TIMEOUT"
done
