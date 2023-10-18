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
	RSYNC_PROGRESS_ARGS+=( --itemize-changes )
fi


#
# arguments
#

BORG_COMPACT=1
BORG_COMPACT_FORCE=0
ARGS=()

for arg; do
	case "$arg" in
	-Xno-compact)
		BORG_COMPACT=0
		log "Disabling automatic compaction of Borg repositories"
		;;
	-Xforce-compact)
		BORG_COMPACT_FORCE=1
		log "Forcing compaction of Borg repositories"
		;;
	-X*)
		die "Unrecognized: $arg"
		;;
	*)
		ARGS+=( "$arg" )
		;;
	esac
done


#
# functions
#

do_rsync() {
	rsync \
		-arAX --fake-super \
		"${RSYNC_PROGRESS_ARGS[@]}" \
		--human-readable \
		--delete-after \
		--partial-dir="$RSYNC_PARTIAL" \
		--delay-updates \
		"$@"
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

NEED_RERUN=0

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
	log "$dir: looks like a borg repository${BORG_COMPACT:+", trying to compact"}"
	#if ! borg with-lock --lock-wait=0 "$dir" -- true; then
	if [[ -e "$dir/lock.exclusive" ]]; then
		log "$dir: Borg repository is busy, skipping and scheduling a rerun"
		echo "$dir" >>"$exclusions"
		NEED_RERUN=1
		continue
	fi

	if ! (( BORG_COMPACT )); then
		continue
	fi

	if ! (( BORG_COMPACT_FORCE )) && find "$dir" -maxdepth 1 -mindepth 1 -type f -name "x_last_compact" -newermt '1 week ago' | grep -q .; then
		log "$dir: Borg repository was compacted less than 1 week ago, skipping"
		continue
	fi
	if ! borg compact --verbose "${BORG_PROGRESS_ARGS[@]}" "$dir"; then
	       log "$dir: failed to compact, skipping and scheduling a rerun"
	       echo "$dir" >>"$exclusions"
	       NEED_RERUN=1
	       continue
	fi
	touch "$dir/x_last_compact"
done

for dir in "${targets_borg_p[@]}"; do
	name="$BORGBASE_NAME/${dir#./}"
	url="$("$SCRIPT_DIR/borgbase-get-repo.sh" "$name" "$BORGBASE_CREATE_ARGS")"
	log "$dir: backing up to BorgBase repo $name at $url"

	do_rsync \
		"$dir/" \
		"$url:" \
		"${ARGS[@]}"
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
	"${ARGS[@]}" 

if (( NEED_RERUN )); then
	log "Some directories were skipped -- restarting in a minute"
	sleep 60
	exec "$SCRIPT_PATH" "$@"
fi
