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
	liquidctl -m 'Commander Pro' initialize || true
	liquidctl -m 'HX1000i' initialize --single-12v-ocp || true
	liquidctl -m 'HX1000i' set fan speed 30 || true
	liquidctl -m 'H100i' initialize --pump-mode balanced || true
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

profile_semiperf() {
	# H100i: CPU exhaust
	liquidctl -m 'H100i' set fan speed \
		20 $h100i_quiet \
		31 $h100i_quiet \
		32 $h100i_loud \
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
		31 $h100i_quiet \
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

profile_semiquiet() {
	liquidctl -m 'H100i' set fan speed \
		20 $h100i_silent \
		25 $h100i_quiet \
		30 $h100i_quiet \
		36 $h100i_quiet \
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
		mode 1 \
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

profile_auto() {
	eval "$(ltraps)"
	liquidctl_json="$(mktemp)"
	ltrap 'rm -f "$liquidctl_json"'

	local STATE=none
	local PROFILE=none
	auto_set_state() {
		log "auto[state=$STATE]: switching state: $STATE -> $1"
		STATE="$1"
	}
	auto_set_profile() {
		if [[ "$1" != "$PROFILE" ]]; then
			log "auto[state=$STATE]: switching profile: $PROFILE -> $1"
			if "$0" --auto "$1"; then
				PROFILE="$1"
			else
				err "auto[state=$STATE]: failed to set profile: $1"
			fi
		fi
	}

	while :; do
		if ! liquidctl status --json >"$liquidctl_json"; then
			err "Failed to query liquidctl, continuing"
			sleep 1
			continue
		fi

		power="$(<"$liquidctl_json" jq -r '.[] | select(.description == "Corsair HX1000i") | .status[] | select(.key == "Total power output") | .value')"
		cpu_fan="$(<"$liquidctl_json" jq -r '.[] | select(.description == "Corsair Hydro H100i Pro XT") | .status | map(select(.key | match("Fan [0-9]+ duty"))) | map(.value) | max')"

		grep drivetemp /sys/class/hwmon/hwmon*/name | xargs -n1 dirname | xargs -I{} cat "{}/temp1_input" | readarray -t drivetemps
		drivetemp=$(( $(max "${drivetemps[@]}") / 1000 ))

		log "auto[state=$STATE]: $(date): power=${power}W, cpu_fan=${cpu_fan}%, drivetemp=${drivetemp}°C"

		case "$STATE" in
		normal)
			if (( cpu_fan >= 60 )) || (( drivetemp > 45 )); then
				auto_set_profile "semiperf"
			else
				auto_set_profile "normal"
			fi

			if (( power >= 350 )); then
				auto_set_state "loaded"
				continue
			fi
			;;

		loaded)
			auto_set_profile "semiperf"

			if (( power < 200 )) && (( cpu_fan <= 50 )); then
				auto_set_state "normal"
				continue
			fi
			;;
		*)
			auto_set_state "normal"
			continue
			;;
		esac
		sleep 10
	done
}

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

ARG_PROFILE="default"
ARG_NO_INITIALIZE=
ARG_FORCE_INITIALIZE=

declare -A PARSE_ARGS
PARSE_ARGS=(
	[--auto]="ARG_NO_INITIALIZE"
	[--init]="ARG_FORCE_INITIALIZE"
	[-i]="ARG_FORCE_INITIALIZE"
	[--]="ARGS"
)
parse_args PARSE_ARGS "$@"
set -- "${ARGS[@]}"

if (( $# > 1 )); then
	die "Expected 0 or 1 positional arguments, got $#"
elif (( $# == 1 )); then
	ARG_PROFILE="$1"
fi

case "$ARG_PROFILE" in
auto)
	PROFILE=auto ;;
normal|default)
	PROFILE=normal ;;
max|perf|performance)
	PROFILE=performance ;;
min|quiet|silent)
	PROFILE=quiet ;;
semisilent|semiquiet|semi)
	PROFILE=semiquiet ;;
semiperf|active)
	PROFILE=semiperf ;;
*)
	die "Unknown profile: '$ARG_PROFILE'"
esac

if (( ARG_FORCE_INITIALIZE )); then
	log "Forcibly re-initializing devices"
	initialize
	touch /run/x570mpro4
elif ! (( ARG_SKIP_INITIALIZE )) && ! [[ -e /run/x570mpro4 ]]; then
	log "Initializing devices"
	initialize
	touch /run/x570mpro4
fi

log "Using profile: '$ARG_PROFILE'"
"profile_$PROFILE"
