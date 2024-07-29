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

DRY_RUN=0
RETRY_COUNT_MAX=5
RETRY_COUNT=0

BORG_COMPACT=1
BORG_COMPACT_FORCE=0
RSYNC_ARGS=()
ALL_ARGS=()

for arg; do
	case "$arg" in
	-Xretry-count=*)
		# not appending to $ALL_ARGS, will be set to N+1 on reexec
		RETRY_COUNT="${arg#-Xretry-count=}"
		;;
	-Xno-compact)
		ALL_ARGS+=( "$arg" )
		BORG_COMPACT=0
		;;
	-Xforce-compact)
		ALL_ARGS+=( "$arg" )
		BORG_COMPACT_FORCE=1
		;;
	-Xdry-run)
		DRY_RUN=1
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

	# do not --delay-updates at the final retry
	local delay_updates_flag=( --delay-updates )
	if ! (( RETRY_COUNT > RETRY_COUNT_MAX )); then
		delay_updates_flag=()
	fi

	Trace rsync \
		-arAX --fake-super \
		"${RSYNC_PROGRESS_ARGS[@]}" \
		--human-readable \
		--delete-after \
		--partial-dir="$RSYNC_PARTIAL" \
		"${delay_updates_flag[@]}" \
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
blacklist="$(mktemp)"

targets_borg="$(mktemp)"
targets_files="$(mktemp)"

cleanup() {
	rm -f "$inclusions" "$exclusions" "$blacklist" "$targets_borg" "$targets_files"
}
trap cleanup TERM HUP INT EXIT


#
# main
#

log "$LIB_ARGV: backing up $LOCAL_PATH to BorgBase (mirror)"
LIBSH_LOG_PREFIX="$LIB_ARGV0: $LOCAL_PATH"

if (( RETRY_COUNT != 0 )); then
	log "retry count: $RETRY_COUNT of $RETRY_COUNT_MAX"
fi
if (( ! BORG_COMPACT )); then
	log "disabling automatic compaction of Borg repositories"
elif (( BORG_COMPACT_FORCE )); then
	log "forcing compaction of Borg repositories"
fi

NEED_RERUN=0
RC=0

# easiest this way, the rest of the script hardcodes "."
cd "$LOCAL_PATH"

log "Constructing blacklist (*.wip, *.tmp)"
find . \
	! -readable -prune -or \
	-type d \
	\( -name '*.wip' -or -name '*.tmp' \) \
	-printf '%p\n' \
	-prune \
	>"$blacklist" \
|| true
readarray -t blacklist_p <"$blacklist"

log "Constructing exclusions (CACHEDIR.TAG, NOBACKUP.TAG)"
find . \
	! -readable -prune -or \
	-type f \
	\( -name CACHEDIR.TAG -or -name NOBACKUP.TAG \) \
	-printf '%h\n' \
	>"$exclusions" \
|| true
readarray -t exclusions_p <"$exclusions"

log "Constructing nested inclusions (CACHEDIR.TAG, NOBACKUP.TAG -> BACKUP.TAG)"
maybe_find "${exclusions_p[@]}" \
	! -readable -prune -or \
	-type f \
	-name BACKUP.TAG \
	-printf '%h\n' \
	>"$inclusions" \
|| true
readarray -t inclusions_p <"$inclusions"

findctl_init FIND
findctl_add_targets FIND .
findctl_add_exclusions FIND "${blacklist_p[@]}"
findctl_add_exclusions FIND "${exclusions_p[@]}"
findctl_add_inclusions FIND "${inclusions_p[@]}"
findctl_add_pre_args FIND \
	! -readable -prune -or

# some less-than-superficial checks whether $1 is a borg repository
log "Looking for borg repositories"
findctl_run FIND \
	-type f \
	-name 'config' \
	-execdir test -d 'data' \; \
	-execdir grep -q -Fx '[repository]' {} \; \
	-printf '%h\n' \
	>"$targets_borg" \
|| true
readarray -t targets_borg_p <"$targets_borg"

# other locations that have to be backed up with rsync into a separate raw repo, bypassing borg
#findctl_add_exclusions FIND "${targets_borg_p[@]}"
log "Looking for raw files (DONTBORG.TAG)"
findctl_run FIND \
	-type f \
	-name DONTBORG.TAG \
	-printf '%h\n' \
	>"$targets_files" \
|| true
readarray -t targets_files_p <"$targets_files"

echo "BLACKLIST:"
cat $blacklist; echo

echo "EXCLUSIONS:"
cat $exclusions; echo

echo "INCLUSIONS:"
cat $inclusions; echo

echo "BORG REPOS:"
cat $targets_borg; echo

echo "MISC FILES:"
cat $targets_files; echo

if (( DRY_RUN )); then
	exit
fi


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
	exec "$SCRIPT_PATH" -Xretry-count=$(( RETRY_COUNT + 1 )) "${ALL_ARGS[@]}"
elif (( NEED_RERUN )); then
	err "Some directories were skipped -- bailing out, too many retries"
	RC=1
fi

exit $RC
