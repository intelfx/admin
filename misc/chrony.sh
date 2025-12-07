#!/bin/bash

set -eo pipefail
shopt -s lastpipe

if ! [[ -t 0 && -t 1 && -t 2 ]]; then
	exec 2> >(systemd-cat -t ${0##*/} -p notice) >&2
fi

ACTION="$1"

PS4="+ [$ACTION] "

# case "$ACTION" in
# up) chronyc online ;;
# down) chronyc -m offline dump writertc ;;
# esac

run() {
	set -x
	"$@"
	{ set +x; } &>/dev/null
}

if [[ $ACTION != resume ]] && [[ ! -e /run/chrony/chronyd.pid ]]; then
	echo >&2 "$PS4 (chrony not running)"
	exit 0
fi

case "$ACTION" in
dhcp4-change|dhcp6-change)
	# Actions "up" and "connectivity-change" in some cases do not
	# guarantee that the interface has a route (e.g. a bond).
	# dhcp(x)-change handles at least cases that use DHCP.
	;&
up|connectivity-change)
	run chronyc onoffline
	;;
down)
	run chronyc -m offline dump writertc
	;;
suspend)
	# run chronyc -m offline dump writertc
	run systemctl stop chronyd.service
	;;
resume)
	# XXX: upon "reset sources", chrony's RTC driver seems to wedge itself
	# do_chronyc -m "reset sources" onoffline
	run systemctl start chronyd.service
esac
