#!/bin/bash -e

set -eo pipefail
shopt -s lastpipe

SCRIPT_DIR="$(realpath -s "${BASH_SOURCE%/*}")"
cd "$SCRIPT_DIR"
. lib/lib.sh || exit 1

RC=0
FAILED_TASKS=()

run_task() {
	local user="$1"
	shift

	if ! runuser -u $user -- "$@"; then
		err "Failed task: $* (as $user${capa:+ with $capa})"
		(( ++RC ))
		FAILED_TASKS+=( "$*" )
	fi
}

log_tasks() {
	if (( ${#FAILED_TASKS[@]} )); then
		err "Failed $RC tasks:"
		printf '* %s\n' "${FAILED_TASKS[@]}"
		exit ${#FAILED_TASKS[@]}
	fi
	exit 0
}
trap log_tasks EXIT

run_task operator ./backup-pull-openwrt.sh root@router.nexus.i.intelfx.name
run_task operator ./backup-pull-mikrotik.sh admin@chr.nexus.i.intelfx.name
run_task root     ./backup-borgbase-borg.sh
run_task operator ./backup-borgbase-mirror.sh --itemize-changes

run_task operator ./macrium-consolidate.sh /mnt/data/Backups/SMB/smb-arcadia 30 60
