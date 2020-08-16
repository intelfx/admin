#!/bin/bash -e

. /etc/admin/scripts/lib/lib.sh || exit 1

STATE_DIR="/run/libvirt/qemu-hook"
VCPU_GOVERNOR=ondemand

mem_decode_qemu() {
	local mem_value="$1" mem_unit="$2"
	log "domain memory: value=$mem_value unit=$mem_unit"
	case "$mem_unit" in
	TiB) (( mem_value *= 1024*1024*1024*1024 )) ;;
	GiB) (( mem_value *= 1024*1024*1024 )) ;;
	MiB) (( mem_value *= 1024*1024 )) ;;
	KiB) (( mem_value *= 1024 )) ;;
	B) ;;
	*) die "unknown memory unit (expected one of B, KiB, MiB, GiB or TiB; got $mem_unit)"
	esac
	log "domain memory: $mem_value bytes"
	echo "$mem_value"
}

mem_decode_sysfs_hugepages() {
	local name="$1" value unit
	log "hugepages entry: $name"
	if ! [[ $name =~ hugepages-([0-9]+)([a-zA-Z]+) ]]; then
		die "malformed sysfs hugepage entry (expected hugepages-{SIZE}{UNIT}, got $name)"
	fi
	value="${BASH_REMATCH[1]}"
	unit="${BASH_REMATCH[2]}"
	log "hugepages($name): value=$value, unit=$unit"
	case "$unit" in
	kB) (( value *= 1024*1024 )) ;;
	*) die "unknown memory unit (expected one of kB; got $unit)" ;;
	esac
	log "hugepages($name): $value bytes"
	echo "$value"
}

mem_calculate_hugepages() {
	huge_count="$(( (mem_size+huge_size-1) / huge_size ))"
	huge_wasted="$(( mem_size % huge_size ))"
}


rollback_hugepages() {
	local huge_nr_new="$(< /sys/kernel/mm/hugepages/$huge/nr_hugepages)"
	log "hugepages($huge): releasing: current=$huge_nr_new, desired=$huge_nr_old"

	if ! echo "$huge_nr_old" >"/sys/kernel/mm/hugepages/$huge/nr_hugepages"; then
		die "hugepages($huge): releasing: failure"
	fi

	local huge_nr_actual="$(< /sys/kernel/mm/hugepages/$huge/nr_hugepages)"
	if ! (( huge_nr_actual == huge_nr_old )); then
		die "hugepages($huge): releasing: silent failure: freed just $((huge_nr_new-huge_nr_actual)) out of $((huge_nr_new-huge_nr_old)) (current=$huge_nr_actual, desired=$huge_nr_old)"
	fi

	log "hugepages($huge): releasing: success: released $((huge_nr_new-huge_nr_actual)) (current=$huge_nr_actual)"
}

prepare_hugepages() {
	eval "$(ltraps)"

	LIBSH_LOG_PREFIX="qemu::prepare_hugepages($GUEST_NAME)"
	ltrap 'LIBSH_LOG_PREFIX='

	log "reserving hugepages"
	local mem_unit mem_value mem_size
	mem_unit="$(xq_domain -r '.domain.memory["@unit"] // "B"')"
	mem_value="$(xq_domain -r '.domain.memory["#text"]')"

	# determine how much memory we need
	mem_size="$(mem_decode_qemu "$mem_value" "$mem_unit")"

	# check if maybe we already preallocated hugepages of a specific non-default size
	# TODO: rework code below to do the thing above

	# determine which hugepages we can have
	# XXX: broken idea, x86 has 2M and 1G and you can't allocate 1G at runtime
	#declare -a hugepages
	#readarray -t hugepages < <(find /sys/kernel/mm/hugepages -mindepth 1 -maxdepth 1 -type d -name 'hugepages-*')

	#local h h_value h_count h_wasted
	#local pick pick_value=0 pick_count pick_wasted
	#for h in "${hugepages[@]}"; do
	#	h_value="$(mem_decode_sysfs_hugepages "$h")"
	#	h_count="$( (mem_value+h_value-1) / h_value)"
	#	h_wasted="$(mem_value % h_value)"
	#	log "hugepages($h): count=$h_count, waste=$h_wasted (total=$mem_value)"

	#	if (( h_wasted < HUGEPAGES_MAX_WASTED_BYTES && h_value > pick_value )); then
	#		pick="$h"
	#		pick_value="$h_value"
	#		pick_count="$h_count"
	#		pick_wasted="$h_wasted"
	#	fi
	#done

	#if ! [[ "$pick" ]]; then
	#	err "failed to pick suitable hugepages"
	#	return 1
	#fi

	local huge_size_kb="$(</proc/meminfo sed -nr 's|^Hugepagesize: *([0-9]+) kB$|\1|p')"
	if ! [[ "$huge_size_kb" ]]; then
		err "failed to determine default hugepage size"
	fi

	local huge huge_size huge_count huge_wasted
	huge="hugepages-${huge_size_kb}kB"
	huge_size=$((huge_size_kb*1024))
	mem_calculate_hugepages # sets huge_count, huge_wasted

	log "hugepages($huge): allocating $huge_count to fulfill $mem_size bytes (expecting to waste $huge_wasted bytes)"

	local huge_nr_old="$(< /sys/kernel/mm/hugepages/$huge/nr_hugepages)"
	local huge_nr_new="$(( huge_nr_old + huge_count ))"
	log "hugepages($huge): allocating: old=$huge_nr_old, new=$huge_nr_new"
	ltrap 'rollback_hugepages'
	local i fail=1
	for (( i = 1; i <= 10; ++i )); do
		if (( i > 1 )); then
			log "hugepages($huge): allocating (try $i): dropping caches"
			sync
			sysctl vm.drop_caches=3
			sysctl vm.compact_memory=1
		fi
		if ! echo "$huge_nr_new" >/sys/kernel/mm/hugepages/$huge/nr_hugepages; then
			log "hugepages($huge): allocating (try $i): failure, retrying in 100ms"
			sleep 0.1
			continue
		fi

		local huge_nr_actual="$(< /sys/kernel/mm/hugepages/$huge/nr_hugepages)"
		if ! (( huge_nr_actual >= huge_nr_new )); then
			log "hugepages($huge): allocating (try $i): silent failure: allocated just $((huge_nr_actual-huge_nr_old)) out of $((huge_nr_new-huge_nr_old)) (current=$huge_nr_actual, desired=$huge_nr_new), retrying in 100ms"
			sleep 0.1
			continue
		fi

		log "hugepages($huge): allocating (try $i): success: allocated $((huge_nr_actual-huge_nr_old)) (new=$huge_nr_actual)"
		fail=0
		break
	done
	if (( fail )); then
		die "hugepages($huge): allocating: exceeded attempts, releasing $((huge_nr_actual-huge_nr_old)) allocated so far"
	fi

	STATE_FILE="$STATE_DIR/hugepages/$GUEST_NAME"
	mkdir -p "${STATE_FILE%/*}"
	echo "$huge $huge_count" >"$STATE_FILE"
	luntrap
}

release_hugepages() {
	eval "$(ltraps)"

	LIBSH_LOG_PREFIX="qemu::release_hugepages($GUEST_NAME)"
	ltrap 'LIBSH_LOG_PREFIX='

	log "releasing hugepages"

	STATE_FILE="$STATE_DIR/hugepages/$GUEST_NAME"
	if ! [[ -e "$STATE_FILE" ]]; then
		warn "state file does not exist: $STATE_FILE"
		return 0
	fi

	local huge huge_count
	read huge huge_count <"$STATE_FILE"

	if ! [[ -e "/sys/kernel/mm/hugepages/$huge/nr_hugepages" ]]; then
		die "malformed state file: hugepages type '$huge' does not exist"
	fi
	if !  (( huge_count > 0 )); then
		die "malformed state file: hugepages count $huge_count is not a positive integer"
	fi

	log "hugepages($huge): releasing $huge_count"

	local huge_nr_new="$(< /sys/kernel/mm/hugepages/$huge/nr_hugepages)"
	local huge_nr_old="$(( huge_nr_new - huge_count ))"

	rollback_hugepages

	rm -f "$STATE_FILE"
}

rollback_governor() {
	IFS=,
	local cpus_list="${!governor_state[*]}"
	unset IFS

	log "restoring cpufreq governor: cpus=${cpus_list}"
	local c governor_file governor_old
	for c in "${!governor_state[@]}"; do
		governor_file="/sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor"
		governor_old="${governor_state["$c"]}"

		log "writing $governor_file = $governor_old"
		if ! echo "$governor_old" >"$governor_file"; then
			die "writing $governor_file: failure"
		fi
	done

	log "restoring cpufreq governor: restored ${#governor_state[@]} cpus"
}

configure_governor() {
	eval "$(ltraps)"

	LIBSH_LOG_PREFIX="qemu::configure_governor($GUEST_NAME)"
	ltrap "LIBSH_LOG_PREFIX="

	log "configuring cpufreq governor for pinned CPUs"
	declare -a cpus
	readarray -t cpus < <(xq_domain -r '.domain.cputune.vcpupin[]["@cpuset"]')

	local c
	for c in "${cpus[@]}"; do
		if ! [[ $c =~ ^[0-9]+$ ]]; then
			die "unsupported cpuset $c (only single CPUs are supported)"
		fi
	done

	IFS=,
	local cpus_list="${cpus[*]}"
	unset IFS

	log "configuring cpufreq governor: cpus=${cpus_list} governor=${governor_new}"
	declare -A governor_state
	ltrap 'rollback_governor'
	local c governor_file governor_new="$VCPU_GOVERNOR"
	for c in "${cpus[@]}"; do
		governor_file="/sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor"
		log "writing $governor_file = $governor_new"
		governor_state[$c]="$(< $governor_file)"
		if ! echo "$governor_new" >"$governor_file"; then
			die "writing $governor_file: failure"
		fi
	done
	log "configuring cpufreq governor: configured ${#cpus[@]} cpus"

	STATE_FILE="$STATE_DIR/cpufreq/$GUEST_NAME"
	mkdir -p "${STATE_FILE%/*}"
	declare -p governor_state >"$STATE_FILE"
	luntrap
}

restore_governor() {
	LIBSH_LOG_PREFIX="qemu::restore_governor($GUEST_NAME)"

	log "restoring cpufreq governor for previously configured CPUs"

	STATE_FILE="$STATE_DIR/cpufreq/$GUEST_NAME"
	if ! [[ -e "$STATE_FILE" ]]; then
		warn "state file does not exist: $STATE_FILE"
		return 0
	fi

	source "$STATE_FILE"

	rollback_governor

	rm -f "$STATE_FILE"

	LIBSH_LOG_PREFIX=
}

if ! [[ -t 2 ]]; then
	exec 2> >(systemd-cat -t libvirt-hook)
fi

eval "$(globaltraps)"

(( $# == 4 )) || die "Bad usage: $0 $* (expected 4 arguments, got $#))"
GUEST_NAME="$1"
OPERATION="$2"
STAGE="$3"

log "qemu($GUEST_NAME/$OPERATION/$STAGE)"

DOMAIN_XML="$(mktemp)"
ltrap "rm -vf '$DOMAIN_XML'"
cat >"$DOMAIN_XML"
xq_domain() {
	xq "$@" <"$DOMAIN_XML"
}

case "$OPERATION/$STAGE" in
'prepare/begin')
	#prepare_hugepages
	configure_governor
	;;
'release/end')
	#release_hugepages
	restore_governor
	;;
esac
