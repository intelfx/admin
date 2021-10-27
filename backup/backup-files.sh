#!/bin/bash

set -eo pipefail
shopt -s lastpipe

cd "${BASH_SOURCE%/*}"
. lib/lib.sh || exit 1

all_parents() {
	local d
	for d; do
		while [[ $d && $d != '.' && $d != '/' ]]; do
			echo "$d"
			d="${d%/*}"
		done
	done
}

LOCAL_PATH=/mnt/data
REMOTE_PATH=/mnt/b2/files
PROCESS_BORG=1
PROCESS_MACRIUM=1

NEED_RERUN=0

# rsync does not have any facilities to filter by "tag files" (CACHEDIR.TAG),
# sunrise by hand
targets="$(mktemp)"
inclusions="$(mktemp)"
exclusions="$(mktemp)"
all="$(mktemp)"

# directories with special transfer rules
special_macrium="$(mktemp)"
special_borg="$(mktemp)"
special_incrementals="$(mktemp)"
special_incrementals_l="$(mktemp)"

cleanup() {
	rm -f "$all" "$targets" "$inclusions" "$exclusions" "$special_macrium" "$special_borg" "$special_incrementals" "$special_incrementals_l"
}
trap cleanup TERM HUP INT EXIT

# easiest this way, the rest of the script hardcodes "."
cd "$LOCAL_PATH"

# NOTE: -prune doesn't work, don't include nested DONTBORG.TAG!
find . \
	-type f \
	-name DONTBORG.TAG \
	-printf '%h\n' \
	>"$targets"
readarray -t targets_p <"$targets"

find "${targets_p[@]}" \
	-type f \
	\( -name CACHEDIR.TAG -or -name NOBACKUP.TAG \) \
	-printf '%h\n' \
	>"$exclusions"
readarray -t exclusions_p <"$exclusions"

find "${exclusions_p[@]}" \
	-type f \
	-name BACKUP.TAG \
	-printf '%h\n' \
	>"$inclusions"
readarray -t inclusions_p <"$inclusions"

# checks whether $1 contains Macrium Reflect backup sets
find "${targets_p[@]}" \
	-type f \
	-name '*.mrimg' \
	-printf '%h\n' \
	| uniq \
	>"$special_macrium"

# some less-than-superficial checks whether $1 is a borg repository
find "${targets_p[@]}" \
	-type f \
	-name 'config' \
	-execdir test -d 'data' \; \
	-execdir grep -q -Fx '[repository]' {} \; \
	-printf '%h\n' \
	>"$special_borg"

#printf '%s\n' \
#	"./Backups/SMB/smb-arcadia/test/" \
#	>"$targets"

echo "TARGETS:"
cat $targets; echo

echo "EXCLUSIONS:"
cat $exclusions; echo

echo "INCLUSIONS:"
cat $inclusions; echo

echo "MACRIUM BACKUP LOCATIONS:"
cat $special_macrium; echo

echo "BORG REPOS:"
cat $special_borg; echo

#
# Borg special handling: compact (conservatively) before uploading
#

if (( PROCESS_BORG )); then

readarray -t special_borg_p <"$special_borg"
for dir in "${special_borg_p[@]}"; do
	log "$dir: looks like a borg repository, trying to compact"
	if ! borg with-lock --lock-wait=0 "$dir" -- true; then
		log "$dir: Borg repository is busy, skipping and scheduling a rerun"
		echo "$dir" >>"$exclusions"
		NEED_RERUN=1
		continue
	fi
	borg compact --threshold=50 --verbose --progress "$dir" || die "$dir: failed to compact"
done

fi

#
# Macrium special handling: constantly overwriting synthetic fulls is wasteful.
# only update synthetic fulls (and remove redundant incrementals) if remote full
# is 1 week or more behind local full (that is, by mtime). otherwise only transfer
# new incrementals.
#
# NOTE: expecting that fulls are named '{IMAGEID}-00-00.mrimg'
#

if (( PROCESS_MACRIUM )); then

readarray -t special_macrium_p <"$special_macrium"
for dir in "${special_macrium_p[@]}"; do
	log "$dir: looks like a Macrium Reflect backup destination, locating backup sets"

	if [[ -e "$dir/backup_running" || -e "$dir/merge_running" ]]; then
		log "$dir: Macrium Reflect directory is busy, skipping and scheduling a rerun"
		echo "$dir" >>"$exclusions"
		NEED_RERUN=1
		continue
	fi

	find "$dir" -type f -name '*-00-00.mrimg' -printf '%f\n' | readarray -t macrium_fulls
	for file in "${macrium_fulls[@]}"; do
		imageid="${file%-00-00.mrimg}"
		#log "$dir: $file: looks like a Macrium backup set ($imageid), processing"

		local_file="$dir/$file"
		remote_file="$REMOTE_PATH/${dir#./}/$file"  # $dir is .-based, should be safe
		if ! [[ -e "$remote_file" ]]; then
			log "$dir: $file: remote ($remote_file) does not exist"
			continue
		fi
		local_mtime="$(stat -c '%Y' "$local_file")"
		remote_mtime="$(stat -c '%Y' "$remote_file")"

		week="$(( 7 * 24 * 3600 ))"
		if (( local_mtime >= remote_mtime + week )); then
			# FIXME
			#log "$dir: $file: remote ($remote_file) older than local by 1 week or more, will transfer in full"
			#continue
			log "$dir: $file: remote ($remote_file) older than local by 1 week or more, but ignoring this"
		fi

		log "$dir: $file: remote ($remote_file) is not old enough, will only transfer new incrementals"
		echo "$dir/$imageid-*" >>"$special_incrementals"
	done
done

fi

echo "MACRIUM INCREMENTAL-ONLY SETS:"
cat "$special_incrementals"; echo

# this will backup "." by default!
# intended to be used with filters (--files-from, --exclude-from)
do_rsync_with_filters() {
	rsync \
		-arAX --fake-super \
		--info=progress2 \
		--human-readable \
		--partial \
		--delete-after \
		"$@" \
		./ \
		"$REMOTE_PATH"
}

# specify all paths with a leading / because that's how you anchor rsync patterns to the root of the transfer.
sed -r 's|^\./|/|' \
	-i "$targets" \
	-i "$inclusions" \
	-i "$exclusions" \
	-i "$special_incrementals" \

# poor man's wildcard-aware --files-from
# compute all parent directories for --include-from
readarray -t dirs <"$special_incrementals"
all_parents "${dirs[@]}" >"$special_incrementals_l"
do_rsync_with_filters \
	--ignore-existing \
	--include-from="$special_incrementals_l" \
	--exclude='/' \
	--exclude='*' \
	"$@"

do_rsync_with_filters \
	--files-from=<(cat "$targets" "$inclusions") \
	--exclude-from="$exclusions" \
	--exclude-from="$special_incrementals" \
	"$@"

if (( NEED_RERUN )); then
	log "Some directories were skipped -- restarting in a minute"
	sleep 60
	exec "$0" "$@"
fi
