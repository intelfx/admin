#!/bin/bash

set -eo pipefail
shopt -s lastpipe

INVOCATION_DIR="$PWD"

cd "${BASH_SOURCE%/*}"
. lib/lib.sh || exit 1

format_time() {
	local arg="$1"
	local days hours
	days=$(( arg / day ))
	hours=$(( (arg % day) / hour ))
	echo "${days}d ${hours}h"
}

if ! (( $# == 3 )); then
	err "Expected 3 arguments, got $#"
	err "Usage: $0 <path to Macrium Reflect imageset> <at least days worth of backups to preserve> <at most days worth of backups to keep>"
	exit 1
fi

IMAGESET_DIR="$1"
DAYS_MIN="$2"
DAYS_MAX="$3"

if ! [[ -d "$IMAGESET_DIR" ]]; then
	die "Bad imageset directory: $IMAGESET_DIR"
fi

# [ is used on purpose to check for a valid integer
if ! [ "$DAYS_MIN" -eq "$DAYS_MIN" ] || ! [[ "$DAYS_MIN" -ge 0 ]]; then
	die "Bad number of min. days worth of backups to preserve: $DAYS_MIN"
fi
if ! [ "$DAYS_MAX" -eq "$DAYS_MAX" ] || ! [[ "$DAYS_MAX" -ge 0 ]]; then
	die "Bad number of max. days worth of backups to preserve: $DAYS_MAX"
fi

log "$IMAGESET_DIR: analyzing backup sets"

if [[ -e "$IMAGESET_DIR/backup_running" || -e "$IMAGESET_DIR/merge_running" ]]; then
	die "$IMAGESET_DIR: Macrium Reflect directory is busy"
fi

find "$IMAGESET_DIR" -maxdepth 1 -type f -name '*-00-00.mrimg' -printf '%f\n' | readarray -t macrium_fulls
for file in "${macrium_fulls[@]}"; do
	imageid="${file%-00-00.mrimg}"
	log "$IMAGESET_DIR: found backup set: $imageid ($file)"

	full_file="$file"
	full_mtime="$(stat -c '%Y' "$IMAGESET_DIR/$file")"

	# find oldest local incremental
	find "$IMAGESET_DIR" -maxdepth 1 -type f -name "$imageid-*.mrimg" -not -name "$imageid-00-00.mrimg" -printf '%f\t%T@\n' \
		| sort -t $'\t' -k2 -n \
		| readarray -t incrementals

	if (( ${#incrementals[@]} == 0 )); then
		log "$IMAGESET_DIR: $file: no incrementals"
		continue
	fi

	IFS=$'\t' read oldest_file oldest_mtime <<< "${incrementals[0]}"
	IFS=$'\t' read newest_file newest_mtime <<< "${incrementals[-1]}"

	# strip decimal part
	oldest_mtime="${oldest_mtime%.*}"
	newest_mtime="${newest_mtime%.*}"

	day="$(( 24 * 3600 ))"
	hour="$(( 3600 ))"

	full_mtime_ok=1
	if ! (( full_mtime < oldest_mtime )); then
		warn "$IMAGESET_DIR: full mtime unreliable, ignoring"
		full_mtime="$oldest_mtime"
		full_mtime_ok=0
	fi

	# TODO: verify that name ordering matches mtime ordering

	if (( full_mtime_ok )); then
	log "$IMAGESET_DIR:   full: $full_file @ $(date -d "@$full_mtime")"
	else
	log "$IMAGESET_DIR:   full: $full_file (no mtime)"
	fi
	log "$IMAGESET_DIR: oldest: $oldest_file @ $(date -d "@$oldest_mtime")"
	log "$IMAGESET_DIR: newest: $newest_file @ $(date -d "@$newest_mtime")"

	days=$(( (newest_mtime - full_mtime) / day ))
	hours=$(( ((newest_mtime - full_mtime) % day) / hour ))
	if (( newest_mtime - full_mtime < day * DAYS_MAX )); then
		log "$IMAGESET_DIR: found $(format_time $((newest_mtime-full_mtime))) < ${DAYS_MAX} days worth of backups, skipping"
		continue
	else
		log "$IMAGESET_DIR: found $(format_time $((newest_mtime-full_mtime))) >= ${DAYS_MAX} days worth of backups, consolidating"
	fi

	# find last file that is >= $DAYS_MIN away
	last_file=
	last_mtime=
	for line in "${incrementals[@]}"; do
		read file mtime <<< "$line"
		# strip decimal part
		mtime="${mtime%.*}"
		if (( newest_mtime - mtime >= day * DAYS_MIN )); then
			last_file="$file"
			last_mtime="$mtime"
		else
			break
		fi
	done

	# pretty-print stuff
	for line in "${incrementals[@]}"; do
		read file mtime <<< "$line"
		# strip decimal part
		mtime="${mtime%.*}"
		if (( mtime < last_mtime )); then
			log "$IMAGESET_DIR:  merge: $file @ $(date -d "@$mtime")  # $(format_time $((newest_mtime-mtime))) older than newest"
		else
			log "$IMAGESET_DIR: retain: $file @ $(date -d "@$mtime")  # $(format_time $((newest_mtime-mtime))) older than newest"
		fi
	done

	# consolidate everything up to "$last_file"
	for line in "${incrementals[@]}"; do
		read file mtime <<< "$line"
		./consolidate/consolidate.sh "$IMAGESET_DIR/$full_file" "$IMAGESET_DIR/$file"
		if [[ "$file" == "$last_file" ]]; then
			break
		fi
	done

done

xinit /usr/bin/env LC_ALL=C WINEPREFIX=/etc/admin/wineprefix /usr/bin/wineboot -k -- /usr/bin/Xvnc :9 -auth /etc/admin/Xauthority
