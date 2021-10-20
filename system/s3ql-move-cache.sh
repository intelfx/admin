#!/bin/bash

. /etc/admin/scripts/lib/lib.sh || exit 1

if ! (( $# == 3 )); then
	die "Bad argument count (got $#, expected 3)"
fi

S3QL_NAME="$1"
S3QL_DIR="$2"
TARGET_DIR="$3"

log "Using escaped s3ql URI: $S3QL_NAME"
log "Using s3ql directory: $S3QL_DIR"
log "Movinc cache to directory: $TARGET_DIR"

S3QL_FS_DIR="$S3QL_DIR/$S3QL_NAME-cache"
TARGET_FS_DIR="$TARGET_DIR/$S3QL_NAME-cache"

if [[ -d "$S3QL_FS_DIR" && ! -L "$S3QL_FS_DIR" ]]; then
	if [[ -d "$TARGET_FS_DIR" ]]; then
		die "Both orig and target cache directories exist"
	else
		install -d -m700 "$(dirname "$TARGET_FS_DIR")"
		mv -v "$S3QL_FS_DIR" -T "$TARGET_FS_DIR"
	fi
else
	rm -vrf "$S3QL_FS_DIR"
	mkdir -pv "$TARGET_FS_DIR"
fi
ln -vsf "$TARGET_FS_DIR" -T "$S3QL_FS_DIR"
