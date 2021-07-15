#!/bin/bash -e

. /etc/admin/scripts/lib/lib.sh || exit 1

STATE_DIR="/run/libvirt/qemu-hook"
VCPU_GOVERNOR=ondemand
VCPU_ONDEMAND_THRESHOLD=10

#
# hugepage support
#

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

hugepages_rollback() {
	# input: $huge_nr_orig
	local huge_nr_now="$(< /sys/kernel/mm/hugepages/$huge/nr_hugepages)"
	log "hugepages($huge): releasing: now=$huge_nr_now, target=$huge_nr_orig"

	if ! echo "$huge_nr_orig" >"/sys/kernel/mm/hugepages/$huge/nr_hugepages"; then
		die "hugepages($huge): releasing: failure"
	fi

	local huge_nr_actual="$(< /sys/kernel/mm/hugepages/$huge/nr_hugepages)"
	if ! (( huge_nr_actual == huge_nr_orig )); then
		die "hugepages($huge): releasing: silent failure: freed just $((huge_nr_now-huge_nr_actual)) out of $((huge_nr_now-huge_nr_orig)) (actual=$huge_nr_actual, target=$huge_nr_orig)"
	fi

	log "hugepages($huge): releasing: success: released $((huge_nr_now-huge_nr_actual)) (actual=$huge_nr_actual)"
}

hugepages_setup() {
	eval "$(ltraps)"

	local LIBSH_LOG_PREFIX="qemu::hugepages_setup($GUEST_NAME)"

	log "reserving hugepages"
	local mem_unit mem_value mem_size
	mem_unit="$(xq_domain -r '.domain.memory["@unit"] // "B"')"
	mem_value="$(xq_domain -r '.domain.memory["#text"]')"

	# determine how much memory we need
	mem_size="$(mem_decode_qemu "$mem_value" "$mem_unit")"

	local hugepage_unit hugepage_value hugepage_size
	hugepage_unit="$(xq_domain -r '.domain.memoryBacking.hugepages.page["@unit"] // "B"')"
	hugepage_value="$(xq_domain -r '.domain.memoryBacking.hugepages.page["@size"] // 0')"

	# determine which hugepages we want
	hugepage_size="$(mem_decode_qemu "$hugepage_value" "$hugepage_unit")"

	if ! (( mem_size && hugepage_size )); then
		log "hugepages not configured -- nothing to do"
		return
	fi

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

	#local huge_size_kb="$(</proc/meminfo sed -nr 's|^Hugepagesize: *([0-9]+) kB$|\1|p')"
	#if ! [[ "$huge_size_kb" ]]; then
	#	err "failed to determine default hugepage size"
	#fi

	local huge huge_size huge_count huge_wasted
	huge="hugepages-$(( hugepage_size / 1024 ))kB"
	huge_size="$hugepage_size"
	huge_count="$(( (mem_size+huge_size-1) / huge_size ))"
	huge_wasted="$(( mem_size % huge_size ))"

	log "hugepages($huge): allocating $huge_count to fulfill $mem_size bytes (expecting to waste $huge_wasted bytes)"

	local sysfs_huge_free="$(< /sys/kernel/mm/hugepages/$huge/free_hugepages)"
	local sysfs_huge_resv="$(< /sys/kernel/mm/hugepages/$huge/resv_hugepages)"
	local sysfs_huge_nr="$(< /sys/kernel/mm/hugepages/$huge/nr_hugepages)"
	local sysfs_huge_avail="$(( sysfs_huge_free - sysfs_huge_resv ))"

	local huge_behavior
	if (( sysfs_huge_avail >= huge_count )); then
		log "hugepages($huge): have preallocated hugepages (free - resv = $sysfs_huge_avail >= $huge_count), behavior=use"
		huge_behavior="use"
	else
		log "hugepages($huge): no preallocated hugepages (free - resv = $sysfs_huge_avail < $huge_count), behavior=allocate"
		huge_behavior="allocate"
	fi

	if [[ $huge_behavior == use ]]; then
		return  # right?
	fi

	local huge_nr_orig="$(< /sys/kernel/mm/hugepages/$huge/nr_hugepages)"
	ltrap 'hugepages_rollback'
	local i fail=1
	for (( i = 1; i <= 100; ++i )); do
		local huge_free="$(< /sys/kernel/mm/hugepages/$huge/free_hugepages)"
		local huge_resv="$(< /sys/kernel/mm/hugepages/$huge/resv_hugepages)"
		local huge_avail=$(( huge_free - huge_resv ))
		local huge_nr_now="$(< /sys/kernel/mm/hugepages/$huge/nr_hugepages)"
		local huge_nr_target="$(( huge_nr_now + huge_count - huge_avail ))"
		if (( i > 1 )); then
			log "hugepages($huge): allocating (try $i): dropping caches"
			sync
			sysctl vm.drop_caches=3
			sysctl vm.compact_memory=1
		fi
		log "hugepages($huge): allocating (try $i): orig=$huge_nr_orig, now=$huge_nr_now, target=$huge_nr_target"
		if ! echo "$huge_nr_target" >/sys/kernel/mm/hugepages/$huge/nr_hugepages; then
			log "hugepages($huge): allocating (try $i): failure, retrying in 100ms"
			sleep 0.1
			continue
		fi

		local huge_free_actual="$(< /sys/kernel/mm/hugepages/$huge/free_hugepages)"
		local huge_resv_actual="$(< /sys/kernel/mm/hugepages/$huge/resv_hugepages)"
		local huge_avail_actual="$(( huge_free_actual - huge_resv_actual ))"
		local huge_nr_actual="$(< /sys/kernel/mm/hugepages/$huge/nr_hugepages)"
		if ! (( huge_avail_actual >= huge_count )); then
			log "hugepages($huge): allocating (try $i): silent failure: have just $huge_avail_actual out of $huge_count (actual=$huge_nr_actual, target=$huge_nr_target), retrying in 100ms"
			sleep 0.1
			continue
		fi

		log "hugepages($huge): allocating (try $i): success: have $huge_free_actual, need $huge_count"
		fail=0
		break
	done
	if (( fail )); then
		die "hugepages($huge): allocating: exceeded attempts, releasing $((huge_nr_actual-huge_nr_orig)) allocated so far"
	fi

	STATE_FILE="$STATE_DIR/hugepages/$GUEST_NAME"
	mkdir -p "${STATE_FILE%/*}"
	cat <<-EOF >"$STATE_FILE"
	huge=$huge
	huge_count=$huge_count
	EOF
	luntrap
}

hugepages_teardown() {
	local LIBSH_LOG_PREFIX="qemu::hugepages_teardown($GUEST_NAME)"

	log "releasing hugepages"

	STATE_FILE="$STATE_DIR/hugepages/$GUEST_NAME"
	if ! [[ -e "$STATE_FILE" ]]; then
		warn "state file does not exist: $STATE_FILE"
		return 0
	fi

	local huge huge_count
	. "$STATE_FILE"

	if ! [[ -e "/sys/kernel/mm/hugepages/$huge/nr_hugepages" ]]; then
		die "malformed state file: hugepages type '$huge' does not exist"
	fi
	if ! (( huge_count > 0 )); then
		die "malformed state file: hugepages count '$huge_count' is not a positive integer"
	fi

	log "hugepages($huge): releasing $huge_count"

	local huge_nr_orig="$(( huge_nr_actual - huge_count ))"
	hugepages_rollback

	rm -f "$STATE_FILE"
}

#
# cpufreq support
#

cpufreq_rollback() {
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

cpufreq_setup() {
	eval "$(ltraps)"

	local LIBSH_LOG_PREFIX="qemu::cpufreq_setup($GUEST_NAME)"

	log "configuring cpufreq governor for pinned CPUs"
	declare -a cpus
	readarray -t cpus < <(xq_domain -r '.domain.cputune.vcpupin[]["@cpuset"]')

	local c
	for c in "${cpus[@]}"; do
		if ! [[ $c =~ ^[0-9]+$ ]]; then
			err "unsupported cpuset $c (only single CPUs are supported)"
			return
		fi
	done

	IFS=,
	local cpus_list="${cpus[*]}"
	unset IFS

	log "configuring cpufreq governor: cpus=${cpus_list} governor=${governor_new}"
	declare -A governor_state
	ltrap 'cpufreq_rollback'
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

	if [[ -d /sys/devices/system/cpu/cpufreq/ondemand ]]; then
		log "configuring ondemand: up_threshold=$VCPU_ONDEMAND_THRESHOLD"
		echo "$VCPU_ONDEMAND_THRESHOLD" >/sys/devices/system/cpu/cpufreq/ondemand/up_threshold
	fi

	STATE_FILE="$STATE_DIR/cpufreq/$GUEST_NAME"
	mkdir -p "${STATE_FILE%/*}"
	declare -p governor_state >"$STATE_FILE"
	luntrap
}

cpufreq_teardown() {
	local LIBSH_LOG_PREFIX="qemu::cpufreq_teardown($GUEST_NAME)"

	log "restoring cpufreq governor for previously configured CPUs"

	STATE_FILE="$STATE_DIR/cpufreq/$GUEST_NAME"
	if ! [[ -e "$STATE_FILE" ]]; then
		warn "state file does not exist: $STATE_FILE"
		return 0
	fi

	source "$STATE_FILE"

	cpufreq_rollback

	rm -f "$STATE_FILE"
}

if ! [[ -t 2 ]]; then
	exec 2> >(systemd-cat -t libvirt-hook)
fi

eval "$(globaltraps)"

(( $# == 4 )) || die "Bad usage: $0 $* (expected 4 arguments, got $#)"
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
	hugepages_setup
	cpufreq_setup
	;;
'release/end')
	hugepages_teardown
	cpufreq_teardown
	;;
esac
