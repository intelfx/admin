#!/bin/bash

function set_and_read_back() {
	local file="$1" values=("${@:2}")
	for v in "${values[@]}"; do
		echo "$v" > "$file" && break
	done
	echo "OK: $file = $(< "$file" )" >&2
}

set_and_read_back /sys/module/pcie_aspm/parameters/policy performance

for host in /sys/class/scsi_host/host*/link_power_management_policy; do
	set_and_read_back "$host" max_performance
done
