#!/bin/bash

function btrfs_list_subvolumes() {
	local dest="$1"
	local path="$2"
	shift 2
	local args=( "$@" )

	readarray -t "$dest" < <(btrfs subvolume list "$path" "$@" | sed -nre 's|.* path (.*)$|\1|p')
}

set -e

function make_set() {
	declare -n dest="$1"
	shift
	for arg; do
		dest["$arg"]=""
	done
}

function exists() {
	[[ "${!1+"x"}" ]]
}

FILESYSTEM="$1"
shift

declare -a REPLY
declare -A SUBVOLS SNAPSHOTS
btrfs_list_subvolumes REPLY "$FILESYSTEM"
make_set SUBVOLS "${REPLY[@]}"
btrfs_list_subvolumes REPLY "$FILESYSTEM" -s
make_set SNAPSHOTS "${REPLY[@]}"

echo "subvols:"
printf "%s\n" "${!SUBVOLS[@]}"
echo "snapshots:"
printf "%s\n" "${!SNAPSHOTS[@]}"

echo "Will defragment with options: $(printf "'%s' " "$@")"
for subvol in "${!SUBVOLS[@]}"; do
	if ! exists "SNAPSHOTS[$subvol]"; then
		echo "Will defragment '$subvol' on '$FILESYSTEM'"
	fi
done

for subvol in "${!SUBVOLS[@]}"; do
	if ! exists "SNAPSHOTS[$subvol]"; then
		echo "Defragmenting '$subvol' on '$FILESYSTEM'"
		btrfs filesystem defragment -r -v "$@" "$FILESYSTEM/$subvol"
	fi
done
