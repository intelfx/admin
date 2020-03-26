#!/bin/bash -e

. /etc/admin/scripts/lib/lib.sh || exit 1

DEVICE=nct6775.656
DEVICE_SYSFS="/sys/devices/platform/$DEVICE"

nct6775_write() {
	local name="$1"
	shift
	declare -A attr
	local k v
	while (( $# )); do
		k="$1"; v="$2"; shift 2
		attr["$k"]="$v"
	done

	log "nct6775_write($device): configuring $name"
	for k in "${!attr[@]}"; do
		v="${attr["$k"]}"
		case "$k" in
		_) k=$name ;;
		*) k=${name}_$k ;;
		esac

		echo "$v" > "$device/$k"
		log "nct6775_write($device): $k = $v"
	done
}

nct6775_pwm_manual() {
	local name="$1"
	shift
	nct6775_write \
		"$name" \
		enable 1 \
		temp_tolerance 5000 \
		step_up_time 10000 \
		step_down_time 5000 \
		stop_time 30000 \
		"$@"
}

nct6775_pwm_thermal_cruise() {
	local name="$1"
	shift
	nct6775_write \
		"$name" \
		enable 2 \
		temp_tolerance 1000 \
		step_up_time 5000 \
		step_down_time 5000 \
		stop_time 15000 \
		"$@"
}


cd "$DEVICE_SYSFS"
cd hwmon/hwmon*
device="$(pwd)"


# pwm6: PCH fan
# temp7 (SMBUSMASTER 1): PCH
nct6775_pwm_thermal_cruise pwm6 \
	mode 1 \
	temp_sel 7 \
	target_temp 70000 \
	floor 96 \
	start 128



# pwm1: chassis fan (main/top intake)
# pwm2: CPU fan 2 (140mm)
# pwm3: CPU fan 1 (120mm)
# pwm5: chassis fan (main/top exhaust)
# temp8 (SMBUSMASTER 0): CPU
#for pwm in pwm1 pwm2 pwm3 pwm5; do
#	nct6775_pwm_thermal_cruise $pwm \
#		mode 1 \
#		temp_sel 8 \
#		target_temp 77500 \
#		floor 96 \
#		start 100 \
#		temp_tolerance 500 \
#		step_up_time 500 \
#		step_down_time 500
#done

# pwm4: chassis fan 2 (HDD exhaust)
nct6775_pwm_manual pwm4 \
	mode 1 \
	_ 128
