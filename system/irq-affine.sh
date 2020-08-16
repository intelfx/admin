#!/bin/bash

. /etc/admin/scripts/lib/lib.sh || exit 1

if [[ $1 == "--udev" ]]; then
	exec 2> >(systemd-cat -t "${0##*/}")
	shift
fi

IRQ_NAME="$1"
IRQ_AFFINITY_MASK="$2"
IRQ_NR=()

log "Configuring IRQ(s) matching $IRQ_NAME"
log "Configuring IRQ(s) to $IRQ_AFFINITY_MASK"

while read irq_dir; do
	if [[ $irq_dir =~ ^/proc/irq/([0-9]+)$ ]]; then
		IRQ_NR+=( "${BASH_REMATCH[1]}" )
	else
		die "Bad irq directory: $irq_dir"
	fi
done < <(find /proc/irq -type d -name "$IRQ_NAME" -printf '%h\n')

log "Found ${#IRQ_NR[@]} IRQ(s) for $IRQ_NAME: ${IRQ_NR[@]}"
if (( ${#IRQ_NR[@]} < 1 )); then
	die "No IRQs found -- exiting"
fi

while read sock; do
	log "Found irqbalance socket at $sock, banning IRQs"

	# "setup" command crashes irqbalance, sunrise by hand
	(
	flock -n 9
	cd /run/irqbalance
	readarray -t BAN_LIST < ban-list
	log "Old irqbalance ban list: ${BAN_LIST[*]}"
	BAN_LIST+=( "${IRQ_NR[@]}" )
	sort_array BAN_LIST -u
	log "New irqbalance ban list: ${BAN_LIST[*]}"
	print_array "${BAN_LIST[@]}" > ban-list
	socat "$sock" "-" <<< "settings ban irqs ${BAN_LIST[*]}" >&2
	log "Uploaded new ban list"
	) 9>>/run/irqbalance/ban-list
done < <(find /run/irqbalance -name 'irqbalance*.sock')

rc=0
for i in "${IRQ_NR[@]}"; do
	if ! echo "$IRQ_AFFINITY_MASK" >/proc/irq/$i/smp_affinity; then
		err "Failed to set IRQ $i"
		rc=1
	fi
done
exit $rc

IRQBALANCE_BAN_LIST
