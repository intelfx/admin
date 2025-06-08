#!/bin/bash

set -eo pipefail
shopt -s lastpipe

install_one() {
	local src="$1"
	local dest="/etc/systemd/system/$src"
	local destdir="${dest%/*}"

	local -
	set -x

	mkdir -p "$destdir"
	ln -rsfT "$src" "$dest"
}
export -f install_one

cd "$(dirname "$BASH_SOURCE")"
find -type f -not -path './install.sh' -printf '%P\n' \
	| parallel install_one
