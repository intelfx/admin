#!/bin/bash -e

. /etc/admin/scripts/lib/lib.sh || exit 1

udevadm settle  # guilty as charged

DEVICE=nct6775.656
DEVICE_SYSFS="/sys/devices/platform/$DEVICE"

cd "$DEVICE_SYSFS"
cd hwmon/hwmon*
device="$(pwd)"

nct6775_write() {
	local name="$1"
	shift
	declare -a pairs=( "$@" )
	declare -A effective
	local k v
	set -- "${pairs[@]}"
	while (( $# )); do
		k="$1"; v="$2"; shift 2
		effective["$k"]="$v"
	done

	log "nct6775_write($device): configuring $name"
	set -- "${pairs[@]}"
	while (( $# )); do
		k="$1"; v="$2"; shift 2
		if ! [[ "$v" == "${effective[$k]}" ]]; then
			continue
		fi

		case "$k" in
		_) k=$name ;;
		*) k=${name}_$k ;;
		esac

		if echo "$v" > "$device/$k"; then
			log "nct6775_write($device): $k = $v"
		else
			log "nct6775_write($device): $k <- $v: error $?"
		fi
	done
}

nct6775_pwm_maxspeed() {
	local name="$1"
	shift
	nct6775_write \
		"$name" \
		mode 1 \
		"$@" \
		enable 0
}

nct6775_pwm_manual() {
	local name="$1"
	shift
	nct6775_write \
		"$name" \
		mode 1 \
		"$@" \
		enable 1
}

nct6775_pwm_thermal_cruise() {
	local name="$1"
	shift
	nct6775_write \
		"$name" \
		mode 1 \
		step_up_time 1000 \
		step_down_time 1000 \
		"$@" \
		enable 2
}

nct6775_pwm_curve() {
	local name="$1"
	shift
	nct6775_write \
		"$name" \
		mode 1 \
		step_down_time 400 \
		step_up_time 400 \
		"$@" \
		enable 5
}

profile_performance() {
	liquidctl -m 'H100i' --non-volatile set fan speed \
		20 $h100i_quiet \
		25 $h100i_quiet \
		30 $h100i_loud \
		33 $h100i_loud \
		35 100

	# pwm6: PCH fan
	# temp7 (SMBUSMASTER 1): PCH
	nct6775_pwm_curve pwm6 \
		temp_sel 7 \
		target_temp 70000 \
		floor $pchfan_floor \
		start $pchfan_silent \
		auto_point1_pwm $pchfan_silent \
		auto_point1_temp 50000 \
		auto_point2_pwm $pchfan_quiet \
		auto_point2_temp 60000 \
		auto_point3_pwm $pchfan_quiet \
		auto_point3_temp 70000 \
		auto_point4_pwm $pchfan_loud \
		auto_point4_temp 75000 \
		auto_point5_pwm 255 \
		auto_point5_temp 80000 \
		stop_time 15200 \
		temp_tolerance 2000 \
		crit_temp_tolerance 2000 \

	# pwm4: chassis fan 2 (HDD exhaust)
	# temp1 (SYSTIN): somewhere on MB
	# temp2 (CPUTIN): still somewhere on MB, probably under the CPU
	#nct6775_pwm_curve pwm4 \
	#	temp_sel 1 \
	#	floor 192 \
	#	start 192 \
	#	auto_point1_pwm 192 \
	#	auto_point1_temp 40000 \
	#	auto_point2_pwm 192 \
	#	auto_point2_temp 45000 \
	#	auto_point3_pwm 255 \
	#	auto_point3_temp 50000 \
	#	auto_point4_pwm 255 \
	#	auto_point4_temp 60000 \
	#	auto_point5_pwm 255 \
	#	auto_point5_temp 80000 \
	#	temp_tolerance 2000 \
	#	crit_temp_tolerance 5000 \
	#	stop_time 30000 \
	nct6775_pwm_manual pwm4 \
		mode 1 \
		_ $hddfan_quiet
	#nct6775_pwm_maxspeed pwm4

	# pwm1: chassis fan (main/top intake)
	# pwm2: CPU fan 2 (140mm)
	# pwm3: CPU fan 1 (120mm)
	# pwm5: chassis fan (main/top exhaust)
	# temp8 (SMBUSMASTER 0): CPU
	#for pwm in pwm1 pwm2 pwm3 pwm5; do
	#	nct6775_pwm_maxspeed $pwm
	#done
}

profile_normal() {
	liquidctl -m 'H100i' --non-volatile set fan speed \
		20 $h100i_quiet \
		25 $h100i_quiet \
		28 $h100i_quiet \
		35 $h100i_loud \
		40 100

	# pwm6: PCH fan
	# temp7 (SMBUSMASTER 1): PCH
	nct6775_pwm_curve pwm6 \
		temp_sel 7 \
		target_temp 70000 \
		floor $pchfan_floor \
		start $pchfan_silent \
		auto_point1_pwm $pchfan_silent \
		auto_point1_temp 50000 \
		auto_point2_pwm $pchfan_silent \
		auto_point2_temp 60000 \
		auto_point3_pwm $pchfan_quiet \
		auto_point3_temp 70000 \
		auto_point4_pwm $pchfan_quiet \
		auto_point4_temp 75000 \
		auto_point5_pwm 255 \
		auto_point5_temp 80000 \
		stop_time 15200 \
		temp_tolerance 2000 \
		crit_temp_tolerance 2000 \

	# pwm4: chassis fan 2 (HDD exhaust)
	# temp1 (SYSTIN): somewhere on MB
	# temp2 (CPUTIN): still somewhere on MB, probably under the CPU
	#nct6775_pwm_curve pwm4 \
	#	temp_sel 2 \
	#	target_temp 45000 \
	#	floor 128 \
	#	start 128 \
	#	auto_point1_pwm 160 \
	#	auto_point1_temp 40000 \
	#	auto_point2_pwm 192 \
	#	auto_point2_temp 45000 \
	#	auto_point3_pwm 255 \
	#	auto_point3_temp 50000 \
	#	auto_point4_pwm 255 \
	#	auto_point4_temp 50000 \
	#	auto_point5_pwm 255 \
	#	auto_point5_temp 50000 \
	#	temp_tolerance 2000 \
	#	crit_temp_tolerance 5000 \
	#	stop_time 30000 \
	nct6775_pwm_manual pwm4 \
		mode 1 \
		_ $hddfan_quiet
	#nct6775_pwm_maxspeed pwm4

	# pwm1: chassis fan (main/top intake)
	# pwm2: CPU fan 2 (140mm)
	# pwm3: CPU fan 1 (120mm)
	# pwm5: chassis fan (main/top exhaust)
	# temp8 (SMBUSMASTER 0): CPU
	#for pwm in pwm1 pwm2 pwm3 pwm5; do
	#	nct6775_pwm_curve "$pwm" \
	#		temp_sel 8 \
	#		target_temp 80000 \
	#		floor 0 \
	#		start 64 \
	#		auto_point1_pwm 76 \
	#		auto_point1_temp 40000 \
	#		auto_point2_pwm 102 \
	#		auto_point2_temp 55000 \
	#		auto_point3_pwm 178 \
	#		auto_point3_temp 70000 \
	#		auto_point4_pwm 255 \
	#		auto_point4_temp 80000 \
	#		auto_point5_pwm 255 \
	#		auto_point5_temp 80000 \
	#		temp_tolerance 2000 \
	#		crit_temp_tolerance 1000 \
	#		stop_time 15200 \
	#done
}

profile_quiet() {
	liquidctl -m 'H100i' --non-volatile set fan speed \
		20 $h100i_silent \
		25 $h100i_quiet \
		30 $h100i_quiet \
		35 $h100i_quiet \
		40 100

	# pwm6: PCH fan
	# temp7 (SMBUSMASTER 1): PCH
	nct6775_pwm_curve pwm6 \
		mode 1 \
		temp_sel 7 \
		target_temp 70000 \
		floor $pchfan_floor \
		start $pchfan_silent \
		auto_point1_pwm $pchfan_floor \
		auto_point1_temp 50000 \
		auto_point2_pwm $pchfan_silent \
		auto_point2_temp 60000 \
		auto_point3_pwm $pchfan_silent \
		auto_point3_temp 70000 \
		auto_point4_pwm $pchfan_silent \
		auto_point4_temp 75000 \
		auto_point5_pwm 255 \
		auto_point5_temp 80000 \
		stop_time 15200 \
		temp_tolerance 2000 \
		crit_temp_tolerance 2000 \

	# pwm4: chassis fan 2 (HDD exhaust)
	# temp1 (SYSTIN): somewhere on MB
	# temp2 (CPUTIN): still somewhere on MB, probably under the CPU
	#nct6775_pwm_curve pwm4 \
	#	temp_sel 2 \
	#	target_temp 45000 \
	#	floor 128 \
	#	start 128 \
	#	auto_point1_pwm 128 \
	#	auto_point1_temp 40000 \
	#	auto_point2_pwm 160 \
	#	auto_point2_temp 50000 \
	#	auto_point3_pwm 255 \
	#	auto_point3_temp 55000 \
	#	auto_point4_pwm 255 \
	#	auto_point4_temp 55000 \
	#	auto_point5_pwm 255 \
	#	auto_point5_temp 55000 \
	#	temp_tolerance 2000 \
	#	crit_temp_tolerance 5000 \
	#	stop_time 30000 \
	nct6775_pwm_manual pwm4 \
		mode 1 \
		_ $hddfan_quiet

	# pwm1: chassis fan (main/top intake)
	# pwm2: CPU fan 2 (140mm)
	# pwm3: CPU fan 1 (120mm)
	# pwm5: chassis fan (main/top exhaust)
	# temp8 (SMBUSMASTER 0): CPU
	#for pwm in pwm1 pwm2 pwm3 pwm5; do
	#
	#nct6775_pwm_curve "$pwm" \
	#	temp_sel 8 \
	#	target_temp 80000 \
	#	floor 0 \
	#	start 64 \
	#	auto_point1_pwm 76 \
	#	auto_point1_temp 40000 \
	#	auto_point2_pwm 102 \
	#	auto_point2_temp 70000 \
	#	auto_point3_pwm 178 \
	#	auto_point3_temp 80000 \
	#	auto_point4_pwm 255 \
	#	auto_point4_temp 85000 \
	#	auto_point5_pwm 255 \
	#	auto_point5_temp 85000 \
	#	temp_tolerance 2000 \
	#	crit_temp_tolerance 1000 \
	#	stop_time 15200 \
	#
	#done
}

ARG_PROFILE="default"

# 192: ~1000 RPM, almost unnoticeable if HDDs are active
hddfan_quiet=192

# 0: 0 RPM, semipassive mode as per BIOS
# 76: ~2100 RPM, apparently the actual floor for this fan (takes ~1min to start spinning)
# 80: ~2200 RPM, starts faster
pchfan_floor=80
# 128: ~3300 RPM, definitely inaudible
pchfan_silent=128
# 160: ~4000 RPM, almost inaudible in common noise floor
pchfan_quiet=160
# 192: ~4800 RPM, definitely noticeable, maximum acceptable high-pitched noise
pchfan_loud=192

# 40: ~700 RPM, definitely inaudible
h100i_silent=40
# 42: ~1000 RPM, almost inaudible
h100i_quiet=43
# 60: ~1500 RPM, maximum acceptable noise
h100i_loud=60

if (( $# > 1 )); then
	die "Expected 0 or 1 arguments, got $#"
elif (( $# == 1 )); then
	ARG_PROFILE="$1"
fi

case "$ARG_PROFILE" in
normal|default)
	PROFILE=normal ;;
max|perf|performance)
	PROFILE=performance ;;
min|quiet|silent)
	PROFILE=quiet ;;
*)
	die "Unknown profile: '$ARG_PROFILE'"
esac

log "Using profile: '$ARG_PROFILE'"
"profile_$PROFILE"
