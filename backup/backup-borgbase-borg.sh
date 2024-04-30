#!/bin/bash

set -eo pipefail
shopt -s lastpipe
shopt -s extglob

SCRIPT_DIR="$(realpath -s "${BASH_SOURCE%/*}")"
cd "$SCRIPT_DIR"
. lib/lib.sh || exit 1

#
# constants and setup
#

LOCAL_PATH=/mnt/data
export BORG_BASE_DIR="/home/operator"
export BORG_RSH="ssh -oBatchMode=yes -oIdentitiesOnly=yes -i/etc/admin/keys/id_ed25519"
export BORG_PASSCOMMAND="cat /etc/admin/keys/borg"

BORGBASE_NAME="$(hostname --short)/tank/borg"
BORGBASE_CREATE_ARGS="region:\"eu\", borgVersion:\"V_1_2_X\", appendOnlyKeys:[\"18566\"]"

BORG_INIT_ARGS=( -e repokey-blake2 )
BORG_PROGRESS_ARGS=()
if [[ -t 2 ]]; then
	BORG_PROGRESS_ARGS+=( --progress )
fi

TIMESTAMP="$(date -Iseconds)"
TIMESTAMP_UTC="$(TZ=UTC date -d "$TIMESTAMP" -Iseconds)"
TIMESTAMP_UTC="${TIMESTAMP_UTC%+00:00}"

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

#
# arguments
#

_usage() {
	cat <<EOF
Usage: $0 [--create] [--prune] [--compact]
Default is $0 --create --prune --compact.
EOF
}

if (( $# )); then
	declare -A ARGS=(
		[--create]=OP_CREATE
		[--prune]=OP_PRUNE
		[--compact]=OP_COMPACT
	)
	if ! parse_args ARGS "$@"; then
		usage ""
	fi
	if ! (( OP_CREATE || OP_PRUNE || OP_COMPACT )); then
		usage "No action specified"
	fi
else
	OP_CREATE=1
	OP_PRUNE=1
	OP_COMPACT=1
fi

#
# functions
#

borgbase_name_by_target() {
	local target="$1"
	if [[ $target == . ]]; then
		echo "$BORGBASE_NAME"
	else
		echo "$BORGBASE_NAME/$target"
	fi
}

#
# setup
#

blacklist="$(mktemp)"
inclusions="$(mktemp)"
exclusions="$(mktemp)"
patterns="$(mktemp)"

cleanup() {
	rm -f "$blacklist" "$inclusions" "$exclusions" "$patterns"
}
trap cleanup TERM HUP INT EXIT

#
# main
#

log "$0${*:+" ${*@Q}"}: backing up $LOCAL_PATH to BorgBase (borg)"

RC=0

for target in "${BORG_TARGETS[@]}"; do
	name="$(borgbase_name_by_target "$target")"
	if ! url="$("$SCRIPT_DIR/borgbase-get-repo.sh" "$name" "$BORGBASE_CREATE_ARGS"):repo"; then
		err "$target: failed to acquire BorgBase repo at $url"
		RC=1
		continue
	fi
	BORG_URLS[$target]="$url"

	if (( OP_CREATE )); then
	log "$target: backing up to BorgBase repo $name at $url"

	(
	if ! borg debug get-obj "$url" "$(printf '%064d' '0')" /dev/null; then
		log "$target: initializing Borg repo at $url"
		if ! borg init "${BORG_INIT_ARGS[@]}" "$url"; then
			err "$target: failed to initialize Borg repo at $url"
			exit 1
		fi
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
	# locations that are mirrored to a separate raw repo, bypassing borg
	find . \
		-type f \
		-name DONTBORG.TAG \
		-printf '%h\n' \
		>>"$blacklist"
	# borg repositories are mirrored to separate borg repos
	find . \
		-type f \
		-name 'config' \
		-execdir test -d 'data' \; \
		-execdir grep -q -Fx '[repository]' {} \; \
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
		--stats --verbose "${BORG_PROGRESS_ARGS[@]}" \
		"$url::$TIMESTAMP" \
		.
	) && rc=0 || rc=$?

	if (( rc == 1 )); then
		warn "$target: minor problems when backing up to $url, continuing"
	elif (( rc > 1 )); then
		err "$target: failed to back up to $url"
		RC=1
	fi

	fi
done

if (( OP_PRUNE )); then

for target in "${BORG_TARGETS[@]}"; do
	(
	name="$(borgbase_name_by_target "$target")"
	url="${BORG_URLS[$target]}"
	if ! [[ $url ]]; then
		err "$target: URL not registered during backup, check prune configuration"
		exit 1
	fi

	log "$target: pruning BorgBase repo $name at $url"
	borg delete \
		-a '*.checkpoint' \
		--list --stats --verbose \
		"$url" || exit

	borg prune \
		--list --stats --verbose "${BORG_PROGRESS_ARGS[@]}" \
		${BORG_PRUNE[$target]} \
		"$url" || exit
	) && rc=0 || rc=$?

	if (( rc > 0 )); then
		err "$target: failed to prune $url"
		RC=1
	fi
done

fi

if (( OP_COMPACT )); then

for target in "${BORG_TARGETS[@]}"; do
	(
	name="$(borgbase_name_by_target "$target")"
	url="${BORG_URLS[$target]}"
	if ! [[ $url ]]; then
		err "$target: URL not registered during backup, check prune configuration"
		exit 1
	fi

	log "$target: compacting BorgBase repo $name at $url"
	borg compact \
		--verbose "${BORG_PROGRESS_ARGS[@]}" \
		"$url" \
	) && rc=0 || rc=$?

	if (( rc > 0 )); then
		err "$target: failed to compact $url"
		RC=1
	fi
done

fi

exit $RC
