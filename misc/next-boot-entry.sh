#!/bin/bash

. /etc/admin/scripts/lib/lib.sh || exit 1

_usage() {
	cat <<EOF
Usage: $0 [ENTRY]

If ENTRY is specified, checks whether the system is going to boot into ENTRY.
If ENTRY is not specified, prints the effective next boot entry.
EOF
}

VAR_DEFAULT='LoaderEntryDefault-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f'
VAR_ONESHOT='LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f'
VAR_SELECTED='LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f'

get_var_name() {
	local order=(
		"$VAR_ONESHOT"
		"$VAR_DEFAULT"
		"$VAR_SELECTED"
	)
	local v
	for v in "${order[@]}"; do
		if efivar-crud exists "$v"; then
			echo "$v"
			return
		fi
	done
	err "Failed to determine next boot entry"
	return 1
}

MODE_PRINT=
MODE_CHECK=
TARGET_ENTRY=

if (( $# == 0 )); then
	MODE_PRINT=1
elif (( $# == 1 )); then
	MODE_CHECK=1
	TARGET_ENTRY="$1"
else
	usage "Expected 0 or 1 arguments"
fi

entry_var="$(get_var_name)"
entry="$(efivar-crud r "$entry_var")"

if (( MODE_PRINT )); then
	echo "$entry"
else
	[[ "$entry" == "$TARGET_ENTRY" ]] && exit 0 || exit 1
fi
