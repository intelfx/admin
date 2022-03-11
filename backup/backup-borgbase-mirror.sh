#!/bin/bash

set -eo pipefail
shopt -s lastpipe
shopt -s extglob

SCRIPT_DIR="$(realpath -s "${BASH_SOURCE%/*}")"
SCRIPT_PATH="$(realpath -s "$BASH_SOURCE")"
cd "$SCRIPT_DIR"
. lib/lib.sh || exit 1

LOCAL_PATH=/mnt/data
export RSYNC_RSH="ssh -oBatchMode=yes -oIdentitiesOnly=yes -i/etc/admin/keys/id_ed25519"

BORGBASE_NAME="$(hostname --short)/tank/files"
BORGBASE_NAME_CATCH_ALL="$BORGBASE_NAME"
BORGBASE_CREATE_ARGS="region:\"eu\", borgVersion:\"V_1_2_X\", rsyncKeys:[\"18566\"]"

NEED_RERUN=0

BORG_COMPACT=1
ARGS=()

for arg; do
	case "$arg" in
	-Xno-compact)
		BORG_COMPACT=
		log "Disabling automatic compaction of Borg repositories"
		;;
	*)
		ARGS+=( "$arg" )
		;;
	esac
done

# rsync does not have any facilities to filter by "tag files" (CACHEDIR.TAG),
# sunrise by hand
all="$(mktemp)"
targets="$(mktemp)"
inclusions="$(mktemp)"
exclusions="$(mktemp)"

# directories with special transfer rules
special_borg="$(mktemp)"

cleanup() {
	rm -f "$all" "$targets" "$inclusions" "$exclusions" "$special_borg"
}
trap cleanup TERM HUP INT EXIT

# easiest this way, the rest of the script hardcodes "."
cd "$LOCAL_PATH"

# NOTE: -prune doesn't work, don't include nested DONTBORG.TAG!
find . \
	! -readable -prune -or \
	-type f \
	-name DONTBORG.TAG \
	-printf '%h\n' \
	>"$targets"
readarray -t targets_p <"$targets"

find "${targets_p[@]}" \
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

# some less-than-superficial checks whether $1 is a borg repository
find "${targets_p[@]}" \
	-type f \
	-name 'config' \
	-execdir test -d 'data' \; \
	-execdir grep -q -Fx '[repository]' {} \; \
	-printf '%h\n' \
	>"$special_borg"

echo "TARGETS:"
cat $targets; echo

echo "EXCLUSIONS:"
cat $exclusions; echo

echo "INCLUSIONS:"
cat $inclusions; echo

echo "BORG REPOS:"
cat $special_borg; echo

#
# Borg special handling: compact (conservatively) before uploading
#

readarray -t special_borg_p <"$special_borg"
for dir in "${special_borg_p[@]}"; do
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

	if find "$dir" -maxdepth 1 -mindepth 1 -type f -name "x_last_compact" -newermt '1 week ago' | grep -q .; then
		log "$dir: Borg repository was compacted less than 1 week ago, skipping"
		continue
	fi
	borg compact --verbose --progress "$dir" || die "$dir: failed to compact"
	touch "$dir/x_last_compact"
done

RSYNC_PARTIAL=".rsync-partial"

do_rsync() {
	rsync \
		-arAX --fake-super \
		--info=progress2 \
		--human-readable \
		--delete-after \
		--partial-dir="$RSYNC_PARTIAL" \
		--delay-updates \
		"$@"

}

for dir in "${special_borg_p[@]}"; do
	if grep -qx "$dir" "$exclusions"; then
		continue
	fi
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
	-i "$special_borg" \

url="$("$SCRIPT_DIR/borgbase-get-repo.sh" "$BORGBASE_NAME_CATCH_ALL" "$BORGBASE_CREATE_ARGS")"
log ".: backing up all other files to BorgBase repo $BORGBASE_NAME_CATCH_ALL at $url"
do_rsync \
	--files-from="$targets" \
	--exclude-from="$exclusions" \
	--include-from="$inclusions" \
	--exclude-from="$special_borg" \
	./ \
	"$url:" \
	"${ARGS[@]}" 

if (( NEED_RERUN )); then
	log "Some directories were skipped -- restarting in a minute"
	sleep 60
	exec "$SCRIPT_PATH" "$@"
fi
