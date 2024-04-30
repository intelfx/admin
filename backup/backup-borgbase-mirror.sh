#!/bin/bash

set -eo pipefail
shopt -s lastpipe
shopt -s extglob

SCRIPT_DIR="$(realpath -s "${BASH_SOURCE%/*}")"
SCRIPT_PATH="$(realpath -s "$BASH_SOURCE")"
cd "$SCRIPT_DIR"
. lib/lib.sh || exit 1


#
# constants
#

LOCAL_PATH=/mnt/data
export RSYNC_RSH="ssh -oBatchMode=yes -oIdentitiesOnly=yes -i/etc/admin/keys/id_ed25519"
RSYNC_PARTIAL=".rsync-partial"

BORGBASE_NAME="$(hostname --short)/tank/files"
BORGBASE_NAME_CATCH_ALL="$BORGBASE_NAME"
BORGBASE_CREATE_ARGS="region:\"eu\", borgVersion:\"V_1_2_X\", rsyncKeys:[\"18566\"]"

BORG_PROGRESS_ARGS=()
RSYNC_PROGRESS_ARGS=()
if [[ -t 2 ]]; then
	BORG_PROGRESS_ARGS+=( --progress )
	RSYNC_PROGRESS_ARGS+=( --info=progress2 )
else
	RSYNC_PROGRESS_ARGS+=( --itemize-changes --info=stats )
fi


#
# arguments
#

RETRY_COUNT_MAX=5
RETRY_COUNT=0

BORG_COMPACT=1
BORG_COMPACT_FORCE=0
RSYNC_ARGS=()
ALL_ARGS=()

for arg; do
	case "$arg" in
	-X-retry-count=*)
		# not appending to $ALL_ARGS, will be set to N+1 on reexec
		RETRY_COUNT="${arg#-X-retry-count=}"
		;;
	-Xno-compact)
		ALL_ARGS+=( "$arg" )
		BORG_COMPACT=0
		;;
	-Xforce-compact)
		ALL_ARGS+=( "$arg" )
		BORG_COMPACT_FORCE=1
		;;
	-X*)
		die "Unrecognized: $arg"
		;;
	*)
		ALL_ARGS+=( "$arg" )
		RSYNC_ARGS+=( "$arg" )
		;;
	esac
done


#
# functions
#

do_rsync() {
	local rc

	rsync \
		-arAX --fake-super \
		"${RSYNC_PROGRESS_ARGS[@]}" \
		--human-readable \
		--delete-after \
		--partial-dir="$RSYNC_PARTIAL" \
		--delay-updates \
		"$@" \
	&& rc=0 || rc=$?

	case "$rc" in
	0)
		;;
	23|24)
		warn "rsync reported partial transfer (rc=$rc), scheduling a rerun"
		NEED_RERUN=1
		;;
	30)
		warn "rsync reported timeout (rc=$rc), scheduling a rerun"
		NEED_RERUN=1
		;;
	*)
		err "rsync reported errors (rc=$rc), logging failure"
		RC=1
		;;
	esac
}


#
# setup
#

# rsync does not have any facilities to filter by "tag files" (CACHEDIR.TAG),
# sunrise by hand
inclusions="$(mktemp)"
exclusions="$(mktemp)"

targets_borg="$(mktemp)"
targets_files="$(mktemp)"

cleanup() {
	rm -f "$inclusions" "$exclusions" "$targets_borg" "$targets_files"
}
trap cleanup TERM HUP INT EXIT


#
# main
#

log "$0${*:+" ${*@Q}"}: backing up $LOCAL_PATH to BorgBase (mirror)"
if (( RETRY_COUNT != 0 )); then
	log "$0: retry count: $RETRY_COUNT of $RETRY_COUNT_MAX"
fi
if (( ! BORG_COMPACT )); then
	log "$0: disabling automatic compaction of Borg repositories"
elif (( BORG_COMPACT_FORCE )); then
	log "$0: forcing compaction of Borg repositories"
fi

NEED_RERUN=0
RC=0

# easiest this way, the rest of the script hardcodes "."
cd "$LOCAL_PATH"

find . \
	! -readable -prune -or \
	-type f \
	\( -name CACHEDIR.TAG -or -name NOBACKUP.TAG \) \
	-printf '%h\n' \
	>"$exclusions"
readarray -t exclusions_p <"$exclusions"

maybe_find "${exclusions_p[@]}" \
	! -readable -prune -or \
	-type f \
	-name BACKUP.TAG \
	-printf '%h\n' \
	>"$inclusions"
readarray -t inclusions_p <"$inclusions"

findctl_init FIND
findctl_add_targets FIND .
findctl_add_exclusions FIND "${exclusions_p[@]}"
findctl_add_inclusions FIND "${inclusions_p[@]}"
findctl_add_pre_args FIND \
	! -readable -prune -or

# some less-than-superficial checks whether $1 is a borg repository
findctl_run FIND \
	-type f \
	-name 'config' \
	-execdir test -d 'data' \; \
	-execdir grep -q -Fx '[repository]' {} \; \
	-printf '%h\n' \
	>"$targets_borg"
readarray -t targets_borg_p <"$targets_borg"

# other locations that have to be backed up with rsync into a separate raw repo, bypassing borg
#findctl_add_exclusions FIND "${targets_borg_p[@]}"
findctl_run FIND \
	-type f \
	-name DONTBORG.TAG \
	-printf '%h\n' \
	>"$targets_files"
readarray -t targets_files_p <"$targets_files"

echo "EXCLUSIONS:"
cat $exclusions; echo

echo "INCLUSIONS:"
cat $inclusions; echo

echo "BORG REPOS:"
cat $targets_borg; echo

echo "MISC FILES:"
cat $targets_files; echo


#
# Borg special handling: compact (conservatively) before uploading
#

for dir in "${targets_borg_p[@]}"; do
	if [[ -e "$dir/lock.exclusive" ]]; then
		log "$dir: Borg repository is busy, scheduling a rerun"
		NEED_RERUN=1
		continue
	fi

	if ! (( BORG_COMPACT )); then
		continue
	fi

	if (( BORG_COMPACT_FORCE )); then
		:
	elif [[ -e "$dir/x_force_compact" ]]; then
		log "$dir: Borg repository has x_force_compact, proceeding"
	elif find "$dir" -maxdepth 1 -mindepth 1 -type f -name "x_last_compact" -newermt '1 week ago' | grep -q .; then
		log "$dir: Borg repository was compacted less than 1 week ago, skipping"
		continue
	fi

	log "$dir: compacting Borg repository"
	if ! borg compact --verbose "${BORG_PROGRESS_ARGS[@]}" "$dir"; then
	       warn "$dir: failed to compact, skipping and scheduling a rerun"
	       echo "$dir" >>"$exclusions"
	       NEED_RERUN=1
	       continue
	fi
	touch "$dir/x_last_compact"
	rm -f "$dir/x_force_compact"
done

for dir in "${targets_borg_p[@]}"; do
	name="$BORGBASE_NAME/${dir#./}"
	url="$("$SCRIPT_DIR/borgbase-get-repo.sh" "$name" "$BORGBASE_CREATE_ARGS")"
	log "$dir: backing up to BorgBase repo $name at $url"

	do_rsync \
		"$dir/" \
		"$url:" \
		"${RSYNC_ARGS[@]}"
done

# specify all patterns with a leading / because that's how you anchor rsync patterns to the root of the transfer.
sed -r 's|^\./|/|' \
	-i "$exclusions" \
	-i "$inclusions" \

url="$("$SCRIPT_DIR/borgbase-get-repo.sh" "$BORGBASE_NAME_CATCH_ALL" "$BORGBASE_CREATE_ARGS")"
log ".: backing up all other files to BorgBase repo $BORGBASE_NAME_CATCH_ALL at $url"
do_rsync \
	--files-from="$targets_files" \
	--exclude-from="$exclusions" \
	--include-from="$inclusions" \
	./ \
	"$url:" \
	"${RSYNC_ARGS[@]}"

if (( NEED_RERUN && RETRY_COUNT < RETRY_COUNT_MAX )); then
	warn "Some directories were skipped -- restarting in a minute"
	sleep 60
	exec "$SCRIPT_PATH" -X-retry-count=$(( RETRY_COUNT + 1 )) "$@"
elif (( NEED_RERUN )); then
	err "Some directories were skipped -- bailing out, too many retries"
	RC=1
fi

exit $RC
