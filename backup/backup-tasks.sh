#!/bin/bash -e

set -eo pipefail
shopt -s lastpipe

SCRIPT_DIR="$(realpath -s "${BASH_SOURCE%/*}")"
cd "$SCRIPT_DIR"
. lib/lib.sh || exit 1

RC=0
FAILED_TASKS=()

run_task() {
	if ! "$@"; then
		err "Failed task: $*"
		(( ++RC ))
		FAILED_TASKS+=( "$*" )
	fi
}

run_task ./backup-pull-openwrt.sh root@router.nexus.i.intelfx.name
run_task ./backup-pull-mikrotik.sh admin@chr.nexus.i.intelfx.name
run_task ./backup-borgbase-borg.sh
run_task ./backup-borgbase-mirror.sh --itemize-changes

run_task ./macrium-consolidate.sh /mnt/data/Backups/SMB/smb-arcadia 30 60

if (( ${#FAILED_TASKS[@]} )); then
	err "Failed $RC tasks:"
	printf '* %s\n' "${FAILED_TASKS[@]}"
	exit ${#FAILED_TASKS[@]}
fi
exit 0
