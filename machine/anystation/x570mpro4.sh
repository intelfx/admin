#!/bin/bash -e

. /etc/admin/scripts/lib/lib.sh || exit 1

DEVICE=nct6775.656
DEVICE_SYSFS="/sys/devices/platform/$DEVICE"

# ------------------------------------------------------------------------------

liquidctl() {
	Trace command liquidctl "$@"
}

# ------------------------------------------------------------------------------

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

nct6775_pwm() {
	local name="$1"
	shift
	nct6775_write \
		"$name" \
		mode 1 \
		"$@" \
		# EOL
}

nct6775_pwm_maxspeed() {
	local name="$1"
	shift
	nct6775_pwm \
		"$name" \
		enable 0 \
		"$@" \
		# EOL
}

nct6775_pwm_manual() {
	local name="$1"
	shift
	nct6775_pwm \
		"$name" \
		enable 1 \
		"$@" \
		# EOL
}

nct6775_pwm_thermal_cruise() {
	local name="$1"
	shift
	nct6775_pwm \
		"$name" \
		step_up_time 1000 \
		step_down_time 1000 \
		"$@" \
		enable 2 \
		# EOL
}

nct6775_pwm_curve() {
	local name="$1"
	shift
	nct6775_pwm \
		"$name" \
		step_down_time 400 \
		step_up_time 400 \
		"$@" \
		enable 5
}

nct6775_set() {
	local func="$1" pwm="$2"
	shift 2

	declare -a args
	local i=1 pct temp

	# handle any key=value pairs
	while :; do
		case "$1" in
		# convert percentages into pwm duty cycles
		floor|start|auto_point*_pwm|_)
			pct="$2"
			args+=(
				"$1" "$(( pct * 255 / 100 ))"
			)
			shift 2
			;;
		[a-z]*)
			args+=(
				"$1" "$2"
			)
			shift 2
			;;
		*)
			break
			;;
		esac
	done

	if (( $# )); then
		die "nct6775_set($pwm, $func): bad arguments"
	fi

	"$func" "$pwm" "${args[@]}"
}


nct6775_set_curve() {
	local pwm="$1"
	shift 1

	declare -a args
	local i=1 pct temp

	# handle any key=value pairs
	while :; do
		case "$1" in
		# convert percentages into pwm duty cycles
		floor|start)
			pct="$2"
			args+=(
				"$1" "$(( pct * 255 / 100 ))"
			)
			shift 2
			;;
		[a-z]*)
			args+=(
				"$1" "$2"
			)
			shift 2
			;;
		*)
			break
			;;
		esac
	done

	while (( $# )); do
		temp="$1"
		pct="$2"
		shift 2
		if [[ ! $pct || ! $temp ]]; then
			die "nct6775_set_curve($pwm): bad arguments"
		fi
		if (( i > 5 )); then
			die "nct6775_set_curve($pwm): more than 5 autopoints"
		fi

		args+=(
			# convert percentages into pwm duty cycles
			"auto_point${i}_pwm" "$(( pct * 255 / 100 ))"
			"auto_point${i}_temp" "$(( temp * 1000 ))"
		)
		(( ++i ))
	done
	# repeat last curve point
	while (( i <= 5 )); do
		args+=(
			# convert percentages into pwm duty cycles
			"auto_point${i}_pwm" "$(( pct * 255 / 100 ))"
			"auto_point${i}_temp" "$(( temp * 1000 ))"
		)
		(( ++i ))
	done

	nct6775_pwm_curve "$pwm" "${args[@]}"
}

liquidctl_set_curve() {
	local dev="$1"
	shift 1

	declare -a channels curve

	# handle channels
	while :; do
		case "$1" in
		all)
			# fix up liquidctl brain damage because they can't
			# agree on a single name for manipulating all channels
			# between different device drivers
			case "$dev" in
			*Pro*) channels+=( sync ) ;;
			*Core*) channels+=( fans ) ;;
			*) die "Unknown liquidctl device filter: ${dev@Q}" ;;
			esac
			shift
			;;
		[a-z]*)
			channels+=( "$1" )
			shift
			;;
		*)
			break
			;;
		esac
	done

	# might be either a single temperature argument or a set of points
	curve+=( "$@" )

	for channel in "${channels[@]}"; do
		liquidctl -m "$dev" set "$channel" speed "${curve[@]}"
	done
}

# ------------------------------------------------------------------------------

do_initialize() {
	liquidctl initialize all || return
}

initialize() {
	local i=1 backoff=1 max=2
	while ! do_initialize; do
		if (( i >= max )); then
			err "Initializing devices [${i}/${max}]: FAIL, bailing"
			return 1
		fi
		warn "Initializing devices [${i}/${max}]: FAIL, waiting ${backoff}s"
		sleep "$backoff"
		(( backoff >= 30 )) || (( backoff *= 2 ))
		(( ++i ))
	done
	log "Initializing devices [${i}/${max}}: OK"
}

# ------------------------------------------------------------------------------

set_mb_cpu_fans_curve() {
	# pwm2, pwm3: CPU fan
	# temp1: M/B ambient
	# temp2: M/B CPU-proximal
	# temp9 (SMBUSMASTER 0): CPU
	# temp13: (TSI0_TEMP): CPU
	for pwm in "${mb_cpufans[@]}"; do
		nct6775_set_curve $pwm \
			temp_sel 1 \
			target_temp 60000 \
			temp_tolerance 2000 \
			crit_temp_tolerance 2000 \
			stop_time 15200 \
			floor ${cpufan_floor:?} \
			start ${cpufan_silent:?} \
			"$@" \
			${cpu_crit:?} ${cpufan_max:?} \
			# EOL
	done
}

set_mb_cpu_pump_curve() {
	# pwm3: CPU pump
	# temp1: M/B ambient
	# temp2: M/B CPU-proximal
	# temp9 (SMBUSMASTER 0): CPU
	# temp13: (TSI0_TEMP): CPU
	for pwm in "${mb_cpupump[@]}"; do
		nct6775_set_curve $pwm \
			temp_sel 1 \
			target_temp 60000 \
			temp_tolerance 2000 \
			crit_temp_tolerance 2000 \
			stop_time 15200 \
			floor ${cpupump_floor:?} \
			start ${cpupump_silent:?} \
			"$@" \
			${cpu_crit:?} ${cpupump_max:?} \
			# EOL
	done
}

set_mb_pch_fans_curve() {
	# pwm6: PCH fan
	# temp14 (TSI1_TEMP): PCH
	# temp7 (SMBUSMASTER 1): PCH
	for pwm in "${mb_pchfans[@]}"; do
		nct6775_set_curve $pwm \
			temp_sel 7 \
			target_temp 70000 \
			temp_tolerance 2000 \
			crit_temp_tolerance 2000 \
			stop_time 15200 \
			floor ${pchfan_floor:?} \
			start ${pchfan_silent:?} \
			"$@" \
			$pch_crit ${pchfan_max:?} \
			# EOL
	done
}

set_mb_cpu_fans_fixed() {
	# pwm2: CPU fan
	# temp1: M/B ambient
	# temp2: M/B CPU-proximal
	# temp9 (SMBUSMASTER 0): CPU
	# temp13: (TSI0_TEMP): CPU
	for pwm in "${mb_cpufans[@]}"; do
		nct6775_set nct6775_pwm_manual $pwm \
			floor ${cpufan_floor:?} \
			start ${cpufan_silent:?} \
			_ ${1:?} \
			# EOL
	done
}

set_mb_cpu_pump_fixed() {
	# pwm3: CPU pump
	# temp1: M/B ambient
	# temp2: M/B CPU-proximal
	# temp9 (SMBUSMASTER 0): CPU
	# temp13: (TSI0_TEMP): CPU
	for pwm in "${mb_cpupump[@]}"; do
		nct6775_set nct6775_pwm_manual $pwm \
			floor ${cpupump_floor:?} \
			start ${cpupump_silent:?} \
			_ ${1:?} \
			# EOL
	done
}

set_mb_pch_fans_fixed() {
	# pwm6: PCH fan
	# temp14 (TSI1_TEMP): PCH
	# temp7 (SMBUSMASTER 1): PCH
	for pwm in "${mb_pchfans[@]}"; do
		nct6775_set nct6775_pwm_manual $pwm \
			floor ${pchfan_floor:?} \
			start ${pchfan_silent:?} \
			_ ${1:?} \
			# EOL
	done
}

# ------------------------------------------------------------------------------

profile_noop() {
	:
}

# ------------------------------------------------------------------------------

profile_new_main() {
	cpupower -c all frequency-set -g powersave
	printf "%s\n" balance_performance \
	| tee /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference

	# liquidctl -m 'Commander Core' set pump speed \
	# 	20 45 \
	# 	30 45 \
	# 	38 45 \
	# 	40 60 \
	# 	50 100 \

	# liquidctl -m 'Commander Core' set fans speed \
	# 	20 $h100i_quiet \
	# 	30 $h100i_quiet \
	# 	38 $h100i_loud \
	# 	40 100 \
        #
	# liquidctl -m 'Commander Pro' set sync speed \
	# 	$case_loud

	set_mb_pch_fans \
		50 $pchfan_silent \
		60 $pchfan_quiet \
		70 $pchfan_quiet \
		75 $pchfan_loud \

}

profile_new_max() {
	# cpupower -c all frequency-set -g performance
	# printf "%s\n" performance \
	# | tee /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference

	set_mb_pch_fans_fixed \
		$pchfan_max

	set_mb_cpu_pump_fixed \
		$cpupump_max

	set_mb_cpu_fans_fixed \
		$cpufan_max

	liquidctl_set_curve 'Commander Pro' \
		"${cpro_cpu_intake_rear[@]}" \
		"${cpro_cpu_intake_front[0]}" \
		"$case_max"
	liquidctl_set_curve 'Commander Pro' \
		"${cpro_cpu_intake_front[1]}" \
		"$case_max2"

	liquidctl_set_curve 'Commander Pro' \
		"${cpro_hdd_intake_front[0]}" \
		"${cpro_hdd_exhaust_rear[@]}" \
		"$case_hdd"
	liquidctl_set_curve 'Commander Pro' \
		"${cpro_hdd_intake_front[1]}" \
		"$case_hdd2"
}

profile_new_min() {
	cpupower -c all frequency-set -g powersave
	printf "%s\n" power \
	| tee /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference

	btrfs scrub cancel /mnt/data ||:
	btrfs balance cancel /mnt/data ||:

	liquidctl -m 'Commander Core' set pump speed \
		60

	liquidctl -m 'Commander Core' set fans speed \
		45

	liquidctl -m 'Commander Pro' set sync speed \
		45

	set_mb_pch_fans \
		30 $pchfan_silent \
		40 $pchfan_silent \
		75 $pchfan_silent \
		80 100 \

}

# ------------------------------------------------------------------------------

profile_max() {
	liquidctl -m 'H100i' set fan speed \
		20 $h100i_silent \
		36 $h100i_silent \
		40 100

	set_mb_cpu_fans \
		30 $h100i_silent \
		40 $h100i_silent \
		45 100 \
		81 100 \

	set_mb_pch_fans \
		30 $pchfan_silent \
		40 $pchfan_silent \
		50 100 \
		75 100 \

	# Commander fan1, fan2: left chamber fan (CPU/GPU top intake, CPU/GPU bottom intake)
	for fan in fan1 fan2; do
		liquidctl -m 'Commander Pro' set $fan speed 100
	done

	# Commander fan4, fan6: right chamber fan (HDD intake, exhaust)
	for fan in fan4 fan6; do
		liquidctl -m 'Commander Pro' set $fan speed 100
	done
}

profile_loud() {
	# H100i: CPU exhaust
	#liquidctl -m 'H100i' set fan speed \
	#	20 $h100i_quiet \
	#	25 $h100i_quiet \
	#	30 $h100i_loud \
	#	36 $h100i_loud \
	#	40 100

	set_mb_cpu_fans \
		30 $h100i_silent \
		40 $h100i_loud \
		81 $h100i_loud \

	set_mb_pch_fans \
		50 $pchfan_silent \
		60 $pchfan_loud \
		75 $pchfan_loud \

	# Commander fan1, fan2: left chamber fan (CPU/GPU top intake, CPU/GPU bottom intake)
	for fan in fan1 fan2; do
		liquidctl -m 'Commander Pro' set $fan speed $case_loud
	done

	# Commander fan4, fan6: right chamber fan (HDD intake, exhaust)
	for fan in fan4 fan6; do
		liquidctl -m 'Commander Pro' set $fan speed $case_loud
	done
}

profile_active() {
	# H100i: CPU exhaust
	#liquidctl -m 'H100i' set fan speed \
	#	20 $h100i_quiet \
	#	30 $h100i_quiet \
	#	31 $h100i_loud \
	#	40 $h100i_loud \
	#	41 100

	set_mb_cpu_fans \
		40 $h100i_quiet \
		60 $h100i_quiet \
		70 $h100i_loud \
		81 $h100i_loud \

	set_mb_pch_fans \
		50 $pchfan_silent \
		60 $pchfan_quiet \
		70 $pchfan_quiet \
		75 $pchfan_loud \

	# Commander fan1, fan2: left chamber fan (CPU/GPU top intake, CPU/GPU bottom intake)
	for fan in fan1 fan2; do
		liquidctl -m 'Commander Pro' set $fan speed $case_loud
	done

	# Commander fan4, fan6: right chamber fan (HDD intake, exhaust)
	for fan in fan4 fan6; do
		liquidctl -m 'Commander Pro' set $fan speed $case_loud
	done
}

profile_normal_hi() {
	#liquidctl -m 'H100i' set fan speed \
	#	20 $h100i_quiet \
	#	25 $h100i_quiet \
	#	31 $h100i_quiet \
	#	36 $h100i_loud \
	#	40 100

	set_mb_cpu_fans \
		40 $h100i_quiet \
		60 $h100i_quiet \
		70 $h100i_quiet \
		81 $h100i_loud \

	set_mb_pch_fans \
		50 $pchfan_silent \
		60 $pchfan_silent \
		70 $pchfan_quiet \
		75 $pchfan_quiet \

	# Commander fan1, fan2: left chamber fan (CPU/GPU top intake, CPU/GPU bottom intake)
	for fan in fan1 fan2; do
		liquidctl -m 'Commander Pro' set $fan speed $case_loud
	done

	# Commander fan4, fan6: right chamber fan (HDD intake, exhaust)
	for fan in fan4 fan6; do
		liquidctl -m 'Commander Pro' set $fan speed $case_loud
	done
}

profile_normal() {
	#liquidctl -m 'H100i' set fan speed \
	#	20 $h100i_quiet \
	#	25 $h100i_quiet \
	#	32 $h100i_quiet \
	#	36 $h100i_loud \
	#	40 100

	set_mb_cpu_fans \
		40 $h100i_silent \
		60 $h100i_quiet \
		70 $h100i_quiet \
		81 $h100i_loud \

	set_mb_pch_fans \
		50 $pchfan_floor \
		60 $pchfan_silent \
		70 $pchfan_quiet \
		75 $pchfan_quiet \

	# Commander fan1, fan2: left chamber fan (CPU/GPU top intake, CPU/GPU bottom intake)
	for fan in fan1 fan2; do
		liquidctl -m 'Commander Pro' set $fan speed $case_quiet
	done

	# Commander fan4, fan6: right chamber fan (HDD intake, exhaust)
	for fan in fan4 fan6; do
		liquidctl -m 'Commander Pro' set $fan speed $case_quiet
	done

}

profile_passive() {
	#liquidctl -m 'H100i' set fan speed \
	#	20 $h100i_silent \
	#	25 $h100i_quiet \
	#	34 $h100i_quiet \
	#	39 $h100i_loud \
	#	40 100

	set_mb_cpu_fans \
		40 $h100i_silent \
		60 $h100i_quiet \
		81 $h100i_quiet \
		85 $h100i_loud \

	set_mb_pch_fans \
		50 $pchfan_silent \
		60 $pchfan_silent \
		70 $pchfan_quiet \
		75 $pchfan_quiet \

	# Commander fan1, fan2: left chamber fan (CPU/GPU top intake, CPU/GPU bottom intake)
	for fan in fan1 fan2; do
		liquidctl -m 'Commander Pro' set $fan speed $case_quiet
	done

	# Commander fan4, fan6: right chamber fan (HDD intake, exhaust)
	for fan in fan4 fan6; do
		liquidctl -m 'Commander Pro' set $fan speed $case_quiet
	done
}

profile_silent() {
	#liquidctl -m 'H100i' set fan speed \
	#	20 $h100i_silent \
	#	36 $h100i_silent \
	#	40 100

	set_mb_cpu_fans \
		40 $h100i_silent \
		85 $h100i_silent \

	set_mb_pch_fans \
		50 $pchfan_silent \
		60 $pchfan_silent \
		70 $pchfan_silent \
		75 $pchfan_silent \

	# Commander fan1, fan2: left chamber fan (CPU/GPU top intake, CPU/GPU bottom intake)
	for fan in fan1 fan2; do
		liquidctl -m 'Commander Pro' set $fan speed $case_silent
	done

	# Commander fan4, fan6: right chamber fan (HDD intake, exhaust)
	for fan in fan4 fan6; do
		liquidctl -m 'Commander Pro' set $fan speed $case_silent_2
	done
}

profile_min() {
	#liquidctl -m 'H100i' set fan speed \
	#	20 $h100i_silent \
	#	36 $h100i_silent \
	#	40 100

	set_mb_cpu_fans \
		40 $h100i_floor \
		85 $h100i_floor \

	set_mb_pch_fans \
		50 $pchfan_floor \
		60 $pchfan_floor \
		70 $pchfan_floor \
		75 $pchfan_floor \

	# Commander fan1, fan2: left chamber fan (CPU/GPU top intake, CPU/GPU bottom intake)
	for fan in fan1 fan2; do
		liquidctl -m 'Commander Pro' set $fan speed $case_floor
	done

	# Commander fan4, fan6: right chamber fan (HDD intake, exhaust)
	for fan in fan4 fan6; do
		liquidctl -m 'Commander Pro' set $fan speed $case_floor
	done
}

profile_auto() {
	eval "$(ltraps)"
	liquidctl_json="$(mktemp)"
	ltrap 'rm -f "$liquidctl_json"'

	local STATE=none
	local PROFILE=none
	local PROFILE_NEW=none
	auto_set_state() {
		log "auto[state=$STATE]: switching state: $STATE -> $1"
		STATE="$1"
	}
	auto_set_profile() {
		PROFILE_NEW="$1"
	}
	auto_set_profile_commit() {
		if [[ "$PROFILE_NEW" != "$PROFILE" ]]; then
			log "auto[state=$STATE]: switching profile: $PROFILE -> $PROFILE_NEW"
			if "$0" --auto "$PROFILE_NEW"; then
				PROFILE="$PROFILE_NEW"
			else
				err "auto[state=$STATE]: failed to set profile: $PROFILE_NEW"
			fi
		fi
	}

	bc_scale() {
		local exp="$1"
		local scale="$2"

		bc <<< "x=($exp); $scale; x/1"
	}

	while :; do
		if ! liquidctl status --json >"$liquidctl_json"; then
			err "Failed to query liquidctl, continuing"
			sleep 0.5
			continue
		fi

		#ram_temp="$(<"$liquidctl_json" jq -r '.[] | select(.description == "Corsair Commander Pro") | .status | map(select(.key | match("Temperature [0-9]+"))) | map(.value) | max')"; ram_temp_x10="$(bc_scale "$ram_temp*10" "scale=0")"; ram_temp="$(bc_scale "$ram_temp" "scale=1")";

		#liquid_temp="$(<"$liquidctl_json" jq -r '.[] | select(.description == "Corsair Hydro H100i Pro XT") | .status[] | select(.key == "Liquid temperature") | .value')"; liquid_temp_x10="$(bc_scale "$liquid_temp*10" "scale=0")"; liquid_temp="$(bc_scale "$liquid_temp" "scale=1")"
		#cpu_fan="$(<"$liquidctl_json" jq -r '.[] | select(.description == "Corsair Hydro H100i Pro XT") | .status | map(select(.key | match("Fan [0-9]+ duty"))) | map(.value) | max')"

		#grep nct6798 /sys/class/hwmon/hwmon*/name | xargs -n1 dirname | xargs -I{} cat "{}/pwm1" "{}/pwm2" | readarray -t cpu_fans
		#cpu_fan="$(max "${cpu_fans[@]}")"
		#cpu_fan="$(bc_scale "$cpu_fan*100/255" "scale=0")"


		power="$(<"$liquidctl_json" jq -r '.[] | select(.description == "Corsair HX1000i") | .status[] | select(.key == "Total power output") | .value')"; power="${power%.*}"
		liquid_temp="$(<"$liquidctl_json" jq -r '.[] | select(.description == "Corsair Commander Core (broken)") | .status[] | select(.key == "Water temperature") | .value')"; liquid_temp_x10="$(bc_scale "$liquid_temp*10" "scale=0")"; liquid_temp="$(bc_scale "$liquid_temp" "scale=1")"
		cpu_fan="$(<"$liquidctl_json" jq -r '.[] | select(.description == "Corsair Commander Core (broken)") | .status | map(select(.key | match("Fan speed [0-9]+"))) | map(.value) | max')"

		grep -L nct6798 /sys/class/hwmon/hwmon*/name | xargs -n1 dirname | xargs -I{} cat "{}/temp13_input" | read cpu_temp
		cpu_temp_x10="$(bc_scale "$cpu_temp/100" "scale=0")"
		cpu_temp="$(bc_scale "$cpu_temp/1000" "scale=1")"

		grep -L drivetemp /sys/class/hwmon/hwmon*/name | xargs -n1 dirname | xargs -I{} cat "{}/temp1_input" | readarray -t drivetemps
		drivetemp_max="$(max "${drivetemps[@]}")"
		drivetemp="$(bc_scale "$drivetemp_max/1000" "scale=1")"
		drivetemp_x10="$(bc_scale "$drivetemp_max/100" "scale=0")"

		log "auto[state=$STATE]: $(date): power=${power}W, cpu_temp=${cpu_temp}°C, cpu_fan=${cpu_fan}%, ram_temp=${ram_temp}°C, drivetemp=${drivetemp}°C"

		case "$STATE" in
		cold)
			auto_set_profile "passive"

			if (( power >= 330 )); then
				auto_set_state "hot"
				continue
			fi

			if (( power >= 200 )) && (( cpu_temp_x10 >= 800 )); then
				auto_set_state "hot"
				continue
			fi

			if (( drivetemp_x10 > 450 )) || (( ram_temp_x10 > 450 )); then
				auto_set_state "warm"
				continue
			fi
			;;

		warm)
			auto_set_profile "normal_hi"

			if (( power > 330 )); then
				auto_set_state "hot"
				continue
			fi

			if (( drivetemp_x10 <= 420 )) && (( ram_temp_x10 <= 440 )); then
				auto_set_state "cold"
				continue
			fi
			;;

		hot)
			auto_set_profile "active"

			if (( power <= 150 )) && (( cpu_temp_x10 <= 600 )); then
				auto_set_state "cold"
				continue
			fi

			;;
		*)
			auto_set_state "cold"
			continue
			;;
		esac

		#case "$STATE" in
		#cold)
		#	auto_set_profile "silent"

		#	if (( power > 330 )); then
		#		auto_set_state "loaded"
		#		continue
		#	fi

		#	if (( drivetemp_x10 > 450 )) || (( ram_temp_x10 > 450 )); then
		#		auto_set_state "hot"
		#		continue
		#	fi

		#	if (( power > 200 )) && (( liquid_temp_x10 > 340 )); then
		#		auto_set_state "normal"
		#		continue
		#	fi

		#	;;

		#normal)
		#	if (( cpu_fan >= 55 )); then
		#		auto_set_profile "normal_hi"
		#	else
		#		auto_set_profile "normal"
		#	fi

		#	if (( power >= 330 )); then
		#		auto_set_state "loaded"
		#		continue
		#	fi

		#	if (( drivetemp_x10 > 450 )) || (( ram_temp_x10 > 450 )); then
		#		auto_set_state "hot"
		#		continue
		#	fi

		#	if (( power <= 150 )) && (( liquid_temp_x10 <= 320 )); then
		#		auto_set_state "cold"
		#		continue
		#	fi
		#	;;

		#hot)
		#	auto_set_profile "normal_hi"

		#	if (( power > 330 )); then
		#		auto_set_state "loaded"
		#		continue
		#	fi

		#	if (( drivetemp_x10 <= 420 )) && (( ram_temp_x10 <= 440 )); then
		#		auto_set_state "normal"
		#		continue
		#	fi
		#	;;

		#loaded)
		#	auto_set_profile "active"

		#	if (( power <= 200 )) && (( liquid_temp_x10 <= 340 )); then
		#		auto_set_state "normal"
		#		continue
		#	fi

		#	;;
		#*)
		#	auto_set_state "cold"
		#	continue
		#	;;
		#esac

		auto_set_profile_commit
		sleep 10
	done
}

mb_cpufans=(pwm2)
mb_cpupump=(pwm3)
mb_pchfans=(pwm6)
cpro_cpu_intake_rear=(fan1)
cpro_cpu_intake_front=(fan2 fan5)
cpro_hdd_intake_front=(fan3 fan6)
cpro_hdd_exhaust_rear=(fan4)

cpufan_floor=30
cpufan_silent=50
# 100: 2100 RPM
cpufan_max=100

cpupump_floor=30
cpupump_silent=50
# 60: 3450 RPM
cpupump_max=60
# 100: 4200 RPM
#cpupump_max=100

case_noctua120_max=100
case_noctua140_max=100
case_phanteks_max=100

# 0: 0 RPM, semipassive mode as per BIOS
# 30: ~2100 RPM, apparently the actual floor for this fan (takes ~1min to start spinning)
# 31: ~2200 RPM, starts faster
pchfan_floor=31
# 50: ~3300 RPM, definitely inaudible
pchfan_silent=50
# 63: ~4000 RPM, almost inaudible in common noise floor
pchfan_quiet=63
# 75: ~4400 RPM
pchfan_loud=75
pchfan_max=75
# ???: ~4800 RPM, definitely noticeable, maximum acceptable high-pitched noise
# 100: 5200 RPM
#pchfan_max=100

# 75: ~1000 RPM, almost unnoticeable if HDDs are active
hddfan_quiet=75

# 40: ~980 RPM, definitely inaudible
h100i_floor=30
# 43: ~1100 RPM, almost inaudible
h100i_start=43

## 40: ~980 RPM, definitely inaudible
#h100i_silent=39
## 43: ~1100 RPM, almost inaudible
#h100i_quiet=43
## 60: ~1500 RPM, maximum acceptable noise
#h100i_loud=60
h100i_silent=40
h100i_quiet=45
h100i_loud=60

#case_floor=50
## 60: ~890 RPM, definitely inaudible
#case_silent=60
## 65: ~950 RPM
#case_silent_2=70
## 75: ~1000 RPM, almost unnoticeable
#case_quiet=75
## 100: ~1300-1400 RPM, definitely noticeable
#case_loud=100
case_quiet=45
case_loud=60
case_max=100
case_max2=75
case_hdd=30
case_hdd2=30

cpu_crit=90
pch_crit=80
aio_crit=40

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
ARG_LAYOUT="new"
unset ARG_INITIALIZE

declare -A PARSE_ARGS
PARSE_ARGS=(
	[-i|--init]="ARG_INITIALIZE"
	[--]="ARGS"
)
parse_args PARSE_ARGS "$@"

if (( ${#ARGS[@]} > 1 )); then
	die "Expected 0 or 1 positional arguments, got ${#ARGS[@]}"
elif (( ${#ARGS[@]} == 1 )); then
	ARG_PROFILE="${ARGS[0]}"
fi

if [[ $ARG_PROFILE == default ]]; then
	if (( ARG_INITIALIZE )); then
		ARG_PROFILE=noop
	# elif grep -qFw x-bench /proc/cmdline; then
	# 	ARG_PROFILE=max
	else
		ARG_PROFILE=max
	fi
fi

LAYOUT="$ARG_LAYOUT"
case "$ARG_PROFILE" in
skip|noop) PROFILE=noop; LAYOUT= ;;
main)      PROFILE=main ;;
max)       PROFILE=max ;;
min)       PROFILE=min ;;
*)
	die "Unknown profile: '$ARG_PROFILE'"
esac

if (( ARG_INITIALIZE )) || ! [[ -e /run/x570mpro4 ]]; then
	log "Initializing devices"
	initialize
fi

if ! [[ -e /run/x570mpro4 ]]; then
	touch /run/x570mpro4
fi

cd "$DEVICE_SYSFS"
cd hwmon/hwmon*
device="$(pwd)"

log "Applying profile: ${PROFILE}"
if [[ $LAYOUT ]]; then
	log "Using layout: ${LAYOUT}"
	"profile_${LAYOUT}_${PROFILE}"
else
	"profile_${PROFILE}"
fi
