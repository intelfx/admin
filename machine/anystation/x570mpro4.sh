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

initialize() {
	if [[ -e /run/x570mpro4 ]]; then return; fi
	liquidctl -m 'Commander Pro' initialize || true
	liquidctl -m 'HX1000i' initialize --single-12v-ocp || true
	liquidctl -m 'HX1000i' set fan speed 30 || true
	liquidctl -m 'H100i' initialize --pump-mode balanced || true
	touch /run/x570mpro4
}

profile_performance() {
	# H100i: CPU exhaust
	liquidctl -m 'H100i' set fan speed \
		20 $h100i_quiet \
		25 $h100i_quiet \
		30 $h100i_loud \
		36 $h100i_loud \
		40 100

	# Commander fan1, fan2: left chamber fan (CPU/GPU top intake, CPU/GPU bottom intake)
	for fan in fan1 fan2; do
		liquidctl -m 'Commander Pro' set $fan speed $case_loud
	done

	# Commander fan4, fan6: right chamber fan (HDD intake, exhaust)
	for fan in fan4 fan6; do
		liquidctl -m 'Commander Pro' set $fan speed $case_loud
	done

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

}

profile_normal() {
	liquidctl -m 'H100i' set fan speed \
		20 $h100i_quiet \
		25 $h100i_quiet \
		28 $h100i_quiet \
		36 $h100i_loud \
		40 100

	# Commander fan1, fan2: left chamber fan (CPU/GPU top intake, CPU/GPU bottom intake)
	for fan in fan1 fan2; do
		liquidctl -m 'Commander Pro' set $fan speed $case_quiet
	done

	# Commander fan4, fan6: right chamber fan (HDD intake, exhaust)
	for fan in fan4 fan6; do
		liquidctl -m 'Commander Pro' set $fan speed $case_quiet
	done

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


}

profile_quiet() {
	liquidctl -m 'H100i' set fan speed \
		20 $h100i_silent \
		25 $h100i_quiet \
		30 $h100i_quiet \
		36 $h100i_quiet \
		40 100

	# Commander fan1, fan2: left chamber fan (CPU/GPU top intake, CPU/GPU bottom intake)
	for fan in fan1 fan2; do
		liquidctl -m 'Commander Pro' set $fan speed $case_silent
	done

	# Commander fan4, fan6: right chamber fan (HDD intake, exhaust)
	for fan in fan4 fan6; do
		liquidctl -m 'Commander Pro' set $fan speed $case_silent
	done

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

# 60: ~800 RPM, definitely inaudible
case_silent=60
# 75: ~1000 RPM, almost unnoticeable
case_quiet=75
# 100: ~1300-1400 RPM, definitely noticeable
case_loud=100

# nct6775 binds for ASRock X570M-Pro4:
# pwm1: chassis fan 3 (bottom left connector)
# pwm2: CPU fan 2
# pwm3: CPU fan 1
# pwm4: chassis fan 1 (top connector)
# pwm5: chassis fan 2 (bottom right connector)
# pwm6: PCH fan
# temp1 (SYSTIN): somewhere on MB
# temp2 (CPUTIN): still somewhere on MB, probably under the CPU
# temp7 (SMBUSMASTER 1): PCH
# temp8 (SMBUSMASTER 0): CPU

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
initialize
"profile_$PROFILE"
