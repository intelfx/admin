#!/bin/bash -e

function log() {
	echo "$*" >&2
}

hostname="$common_name"
hostname="${hostname//./-}"
ip="$ifconfig_pool_remote_ip"
suffix="$2"
hosts="$3"

trap "rm -f '$tempfile'" EXIT
tempfile="$(mktemp)"

if ! [[ "$suffix" == .* && -f "$hosts" ]]; then
	log "openvpn-client.sh: invalid arguments: DNS suffix '$suffix', hosts-file '$hosts' -- exiting"
	exit 1
fi

if ! [[ "$hostname" && "$ip" ]]; then
	log "openvpn-client.sh: invalid input: hostname '$hostname', ip '$ip' -- skipping"
	exit 0
fi

case "$1" in
connect)
	log "openvpn-client.sh: connect hostname '$hostname' ip '$ip' suffix '$suffix' hosts-file '$hosts'"

	sed -re "/$hostname$suffix/d" "$hosts" > "$tempfile"
	echo "$ip $hostname$suffix" >> "$tempfile"
	cat "$tempfile" > "$hosts"
	;;

disconnect)
	log "openvpn-client.sh: disconnect hostname '$hostname' ip '$ip' suffix '$suffix' hosts-file '$hosts'"

	sed -re "/$hostname$suffix/d" "$hosts" > "$tempfile"
	cat "$tempfile" > "$hosts"
	;;

*)
	log "openvpn-client.sh: invalid verb: '$1'"
	exit 1
	;;
esac
