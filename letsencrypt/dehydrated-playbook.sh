#!/bin/bash -e

. "${BASH_SOURCE%/*}/lib/lib.sh" || exit

trap 'rm -vf playbook' EXIT ERR

log "Running dehydrated action playbook"
while read line; do
	"${BASH_SOURCE%/*}/dehydrated-hook.sh" $line ||:
done < playbook
