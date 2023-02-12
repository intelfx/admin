#!/bin/bash

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

rc=0
set -o pipefail

check_set() {
	local what="$1"
	local where="$2"
	local check="${3:-$2}"

	if [[ "$3" && ! -e "$check" ]]; then
		err "[$where] not writing, check file '$check' does not exist"
		(( ++rc ))
		return 1
	fi

	if [[ ! -e "$where" ]]; then
		err "[$where] not writing, file does not exist"
		(( ++rc ))
		return 1
	fi

	#if ! grep -qw "$what" "$check"; then
	#	err "[$where] not writing '$what', option not available"
	#	err "[$where] (possible options: $(< "$check" ))"
	#	(( ++rc ))
	#	return 1
	#fi

	if ! echo -n "$what" > "$where"; then
		err "[$where] failed to write '$what'"
		(( ++rc ))
		return 1
	fi

	log "[$where] set '$what'"
	return 0
}

check_set_many() {
	local what="$1"
	local where="$2"
	local rc2=0
	local dir
	for dir in "${@:4}"; do
		if ! check_set "$what" "$dir/$where" "${3:+$dir/$3}"; then
			(( ++rc2 ))
		fi
	done

	if (( rc2 )); then
		return 1
	fi
	return 0
}

check_set \
	powersave \
	/sys/module/pcie_aspm/parameters/policy
check_set_many \
	powersave \
	scaling_governor \
	scaling_available_governors \
	/sys/devices/system/cpu/cpufreq/policy*
check_set_many \
	balance_performance \
	energy_performance_preference \
	energy_performance_available_preferences \
	/sys/devices/system/cpu/cpufreq/policy*

exit $rc
