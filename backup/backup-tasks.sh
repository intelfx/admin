#!/bin/bash -e

set -eo pipefail
shopt -s lastpipe

SCRIPT_DIR="$(realpath -s "${BASH_SOURCE%/*}")"
cd "$SCRIPT_DIR"
. lib/lib.sh || exit 1

RC=0
FAILED_TASKS=()

run_task() {
	local user="$1" capa
	shift

	local setpriv_args=( --inh-caps -all )
	if [[ $user == *,* ]]; then
		capa="${user#*,}"; capa="${capa//CAP_}"; capa="${capa//cap_}"
		user="${user%%,*}"
		setpriv_args=( --inh-caps "-all,$capa" --ambient-caps "$capa" )
	fi

	if ! setpriv --reuid="$user" --regid="$user" --init-groups --reset-env "${setpriv_args[@]}" -- "$@"; then
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
run_task operator ./backup-pull-mikrotik7.sh admin@router.exile.i.intelfx.name
run_task root     ./backup-borgbase-borg.sh --create --prune --compact
run_task operator ./backup-borgbase-mirror.sh

run_task operator,+CAP_FOWNER ./macrium-consolidate.sh /mnt/data/Backups/SMB/smb-arcadia 30 60
