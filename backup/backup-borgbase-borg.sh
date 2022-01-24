#!/bin/bash

set -eo pipefail
shopt -s lastpipe
shopt -s extglob

SCRIPT_DIR="$(realpath -s "${BASH_SOURCE%/*}")"
cd "$SCRIPT_DIR"
. lib/lib.sh || exit 1

LOCAL_PATH=/mnt/data
export BORG_RSH="ssh -oBatchMode=yes -oIdentitiesOnly=yes -i/etc/admin/keys/id_ed25519"
export BORG_PASSCOMMAND="cat /etc/admin/keys/borg"

BORGBASE_NAME="$(hostname --short)/tank/borg"
BORGBASE_CREATE_ARGS="region:\"eu\", borgVersion:\"V_1_2_X\", appendOnlyKeys:[\"18566\"]"
BORG_INIT_ARGS=( -e repokey-blake2 )

TIMESTAMP="$(date -Iseconds)"
TIMESTAMP_UTC="$(TZ=UTC date -d "$TIMESTAMP" -Iseconds)"
TIMESTAMP_UTC="${TIMESTAMP_UTC%+00:00}"

blacklist="$(mktemp)"
inclusions="$(mktemp)"
exclusions="$(mktemp)"
patterns="$(mktemp)"

cleanup() {
	rm -f "$blacklist" "$inclusions" "$exclusions" "$patterns"
}
trap cleanup TERM HUP INT EXIT

borgbase_name_by_target() {
	local target="$1"
	if [[ $target == . ]]; then
		echo "$BORGBASE_NAME"
	else
		echo "$BORGBASE_NAME/$target"
	fi
}

borgbase_wait() {
	local url="$1"
	local host="$url"
	host="${host%:*}"
	host="${host#*@}"

	local timeout=1
	while :; do
		if getent hosts "$host" &>/dev/null; then
			break
		fi
		log "Waiting $timeout s for $host to resolve..."
		sleep "$timeout"
		(( timeout = timeout*2 < 60 ? timeout*2 : 60 ))
	done

}

# easiest this way, the rest of the script hardcodes "."
cd "$LOCAL_PATH"

BORG_TARGETS=(
	.
	Backups/SMB
)

declare -A BORG_PARAMS=(
	[.]="--chunker-params buzhash,10,23,20,4095"
	[Backups/SMB]="--chunker-params buzhash,10,23,16,4095"
)

declare -A BORG_PRUNE=(
	[.]="--keep-last 1 --keep-daily 7 --keep-weekly 4 --keep-monthly -1"
	[Backups/SMB]="--keep-last 1 --keep-monthly -1"
)

declare -A BORG_URLS

exitcode=0

for target in "${BORG_TARGETS[@]}"; do
	name="$(borgbase_name_by_target "$target")"
	url="$("$SCRIPT_DIR/borgbase-get-repo.sh" "$name" "$BORGBASE_CREATE_ARGS"):repo"
	log "$target: backing up to BorgBase repo $name at $url"
	BORG_URLS[$target]="$url"

	(
	borgbase_wait "$url"

	if ! borg debug get-obj "$url" "$(printf '%064d' '0')" /dev/null; then
		log "$target: initializing borg repo at $url"
		borg init "${BORG_INIT_ARGS[@]}" "$url"
	fi

	declare -a patterns_p=()

	cd "$target"

	# exclude all other targets
	p1="$(realpath --strip "$target")"
	for other in "${BORG_TARGETS[@]}"; do
		p2="$(realpath --strip "$other")"
		if [[ $p2 == $p1/* ]]; then
			log "$other ($p2) is under $target ($p1), skipping"
			realpath --strip --relative-to="$target" "$other"
		fi
	done >"$blacklist"

	find . \
		-type f \
		-name DONTBORG.TAG \
		-printf '%h\n' \
		>>"$blacklist"
	readarray -t blacklist_p <"$blacklist"
	patterns_p+=( "+re:/DONTBORG.TAG$" )

	find . \
		-type f \
		-name NOBACKUP.TAG \
		-printf '%h\n' \
		>"$exclusions"
	readarray -t exclusions_p <"$exclusions"
	patterns_p+=( "+re:/NOBACKUP.TAG$" )

	maybe_find "${exclusions_p[@]}" \
		-type f \
		-name BACKUP.TAG \
		-printf '%h\n' \
		>"$inclusions"
	readarray -t inclusions_p <"$inclusions"

	for p in "${blacklist_p[@]}"; do
		patterns_p+=( "!pp:$p" )
	done
	for p in "${inclusions_p[@]}"; do
		patterns_p+=( "+pp:$p" )
	done
	for p in "${exclusions_p[@]}"; do
		patterns_p+=( "-pp:$p" )
	done
	print_array "${patterns_p[@]}" >"$patterns"

	borg create \
		--numeric-ids \
		--exclude-caches \
		--keep-exclude-tags \
		--patterns-from "$patterns" \
		--compression zstd,10 \
		${BORG_PARAMS[$target]} \
		--timestamp "$TIMESTAMP_UTC" \
		--stats --progress --verbose \
		"$@" \
		"$url::$TIMESTAMP" \
		.
	) && rc=0 || rc=$?

	if (( rc == 1 )); then
		warn "$target: minor problems when backing up to $url, continuing"
	elif (( rc > 1 )); then
		err "$target: failed to back up to $url"
		(( ++exitcode ))
	fi
done

for target in "${BORG_TARGETS[@]}"; do
	(
	name="$(borgbase_name_by_target "$target")"
	url="${BORG_URLS[$target]}"
	if ! [[ $url ]]; then
		err "$target: URL not registered during backup, check prune configuration"
		(( ++exitcode ))
		exit 1
	fi

	log "$target: pruning BorgBase repo $name at $url"
	borg prune \
		--stats --progress --list --verbose \
		${BORG_PRUNE[$target]} \
		"$url"
	) && rc=0 || rc=$?

	if (( rc > 0 )); then
		err "$target: failed to prune $url"
		(( ++exitcode ))
	fi
done

exit $exitcode
