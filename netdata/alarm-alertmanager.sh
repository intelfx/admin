#!/bin/bash -e

#
# So, Alertmanager is basically a program that translates level-triggered alarms to edge-triggered.
# The problem is, Netdata is a program that does the same...
#

#
# the following is taken from /usr/lib/netdata/plugins.d/alarm-notify.sh
#
# netdata
# real-time performance and health monitoring, done right!
# (C) 2017 Costa Tsaousis <costa@tsaousis.gr>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# -----------------------------------------------------------------------------

PROGRAM_NAME="$(basename "${0}")"

logdate() {
	date "+%Y-%m-%d %H:%M:%S"
}

if [[ -n "$JOURNAL_STREAM" && ! -t 2 ]]; then
	log() {
		local prefix="${1}"
		shift 2

		echo >&2 "${prefix}${PROGRAM_NAME}: ${*}"
	}
else
	log() {
		local status="${2}"
		shift 2

		echo >&2 "$(logdate): ${PROGRAM_NAME}: ${status}: ${*}"
	}
fi

warning() {
	log "<4>" WARNING "${@}"
}

error() {
	log "<3>" ERROR "${@}"
}

info() {
	log "<5>" INFO "${@}"
}

fatal() {
	log "<2>" FATAL "${@}"
	exit 1
}

debug=${NETDATA_ALARM_NOTIFY_DEBUG:+1}
debug() {
	if [[ ${debug} ]]; then log "<7>" DEBUG "${@}"; fi
}

# -----------------------------------------------------------------------------
# defaults to allow running this script by hand

[ -z "${NETDATA_USER_CONFIG_DIR}" ] && NETDATA_USER_CONFIG_DIR="/etc/netdata"
[ -z "${NETDATA_STOCK_CONFIG_DIR}" ] && NETDATA_STOCK_CONFIG_DIR="/usr/lib/netdata/conf.d"
[ -z "${NETDATA_CACHE_DIR}" ] && NETDATA_CACHE_DIR="/var/cache/netdata"
[ -z "${NETDATA_REGISTRY_URL}" ] && NETDATA_REGISTRY_URL="https://registry.my-netdata.io"
[ -z "${NETDATA_REGISTRY_CLOUD_BASE_URL}" ] && NETDATA_REGISTRY_CLOUD_BASE_URL="https://netdata.cloud"

# -----------------------------------------------------------------------------
# parse command line parameters

roles="${1}"               # the roles that should be notified for this event
args_host="${2}"           # the host generated this event
unique_id="${3}"           # the unique id of this event
alarm_id="${4}"            # the unique id of the alarm that generated this event
event_id="${5}"            # the incremental id of the event, for this alarm id
when="${6}"                # the timestamp this event occurred
name="${7}"                # the name of the alarm, as given in netdata health.d entries
chart="${8}"               # the name of the chart (type.id)
family="${9}"              # the family of the chart
status="${10}"             # the current status : REMOVED, UNINITIALIZED, UNDEFINED, CLEAR, WARNING, CRITICAL
old_status="${11}"         # the previous status: REMOVED, UNINITIALIZED, UNDEFINED, CLEAR, WARNING, CRITICAL
value="${12}"              # the current value of the alarm
old_value="${13}"          # the previous value of the alarm
src="${14}"                # the line number and file the alarm has been configured
duration="${15}"           # the duration in seconds of the previous alarm state
non_clear_duration="${16}" # the total duration in seconds this is/was non-clear
units="${17}"              # the units of the value
info="${18}"               # a short description of the alarm
value_string="${19}"       # friendly value (with units)
# shellcheck disable=SC2034
# variable is unused, but https://github.com/netdata/netdata/pull/5164#discussion_r255572947
old_value_string="${20}"   # friendly old value (with units), previously named "old_value_string"
calc_expression="${21}"    # contains the expression that was evaluated to trigger the alarm
calc_param_values="${22}"  # the values of the parameters in the expression, at the time of the evaluation
total_warnings="${23}"     # Total number of alarms in WARNING state
total_critical="${24}"     # Total number of alarms in CRITICAL state

# -----------------------------------------------------------------------------
# find a suitable hostname to use, if netdata did not supply a hostname

if [ -z ${args_host} ]; then
	this_host=$(hostname -s 2>/dev/null)
	host="${this_host}"
	args_host="${this_host}"
else
	host="${args_host}"
fi

# -----------------------------------------------------------------------------
# screen statuses we don't need to send a notification

# don't do anything if this is not WARNING, CRITICAL or CLEAR
if [ "${status}" != "WARNING" ] && [ "${status}" != "CRITICAL" ] && [ "${status}" != "CLEAR" ]; then
	info "not sending notification for ${status} of '${host}.${chart}.${name}'"
	exit 1
fi

# don't do anything if this is CLEAR, but it was not WARNING or CRITICAL
if [ "${clear_alarm_always}" != "YES" ] && [ "${old_status}" != "WARNING" ] && [ "${old_status}" != "CRITICAL" ] && [ "${status}" = "CLEAR" ]; then
	info "not sending notification for ${status} of '${host}.${chart}.${name}' (last status was ${old_status})"
	exit 1
fi

# -----------------------------------------------------------------------------

# alertmanager
alertmanager_url="${NETDATA_ALERTMANAGER_URL-"http://localhost:9093/alertmanager"}"
_alertmanager_call() {
	local a amtool=()
	amtool=(
		amtool alert add
		"--alertmanager.url=$alertmanager_url"
		"$@"
		"${labels[@]}"
	)
	for a in "${annotations[@]}"; do
		amtool+=( "--annotation=$a" )
	done
	info "alertmanager: calling: ${amtool[*]}"
	"${amtool[@]}"
}
_alertmanager_fire() {
	info "alertmanager: firing @ $when_iso8601: $*, labels: ${labels[*]}, annotations: ${annotations[*]}"
	_alertmanager_call --start="$when_iso8601" "$@"
}
_alertmanager_clear() {
	info "alertmanager: clear @ $when_iso8601: $*, labels: ${labels[*]}, annotations: ${annotations[*]}"
	_alertmanager_call --end="$when_iso8601" "$@"
}
_alertmanager_severity() {
	local status="$1"

	case "$status" in
	CRITICAL|WARNING|CLEAR) ;;
	REMOVED|UNINITIALIZED|UNDEFINED) warning "${host} ${chart}.${name} is/was ${status} -- assuming clear" ;;
	*) fatal "${host} ${chart}.${name} is/was ${status} -- unknown status" ;;
	esac

	case "$status" in
	CRITICAL) echo "critical" ;;
	WARNING) echo "warning" ;;
	CLEAR|REMOVED|UNINITIALIZED|UNDEFINED) echo "" ;;
	esac
}

send_alertmanager() {
	local when_iso8601 severity old_severity labels=() annotations=()

	# https://prometheus.io/docs/alerting/clients/ and `amtool alert add --help`
	# say this should be RFC3339 (1970-01-01 00:00:00+00:00), but in fact it
	# wants ISO8601 (1970-01-01T00:00:00+00:00).
	when_iso8601="$(date -d "@$when" -Iseconds)"

	severity="$(_alertmanager_severity "$status")"
	old_severity="$(_alertmanager_severity "$old_status")"

	labels+=(
		# well-known labels
		"alertname=$name"
		"instance=$args_host"
		# labels matching netdata's prometheus format
		# (so that Netdata -> Prometheus -> Alertmanager yields roughly the same
		#  labels as Netdata -> Alertmanager)
		"chart=$chart"
		"family=$family"
		#"dimension=..." # XXX: what would that be?
		# other labels
		"alarm_id=$alarm_id"
	)

	annotations+=(
		# well-known annotations
		"summary=$info"
		# other annotations
		"source=$src"
		"value=$value" # old_*?
		"units=$units" # old_*?
		"value_string=$value_string" # old_*?
		"expression=$calc_expression"
		"expression_params=$calc_param_values"
	)

	#
	# Now this gets interesting.
	# For Prometheus/Alertmanager, two alerts on the same thing with
	# different severity are two different alerts which trigger and
	# expire/clear independently of each other. This means that if a warning
	# became critical and then became cleared, Prometheus would send two
	# different alerts (which will then rely on Alertmanager's inhibit_rules
	# to inhibit the warning while the critical is active) and then send two
	# different cleared notifications.
	#
	# Netdata on the other hand considers severity a property of an alarm,
	# which means that if a warning became critical and then got cleared
	# _before_ the warning expired naturally within Alertmanager, the user
	# would see a spurious warning.
	#
	# This can be solved in two ways:
	# - explicitly clear lesser alarms when upgrading them to a higher severity
	#   (that is, clear warnings when upgrading them to critical)
	# - explicitly clear higher alarms when downgrading them to a lesser severity
	#   (that is, clear warnings when downgrading critical
	#

	if [[ "$severity" ]]; then
		_alertmanager_fire severity="$severity"
	fi
	if [[ "$old_severity" ]]; then
		_alertmanager_clear severity="$old_severity"
	fi
}

send_alertmanager
