#!/bin/bash -e

. "${BASH_SOURCE%/*}/lib/lib.sh" || exit

HOOK_DIR="${BASH_SOURCE%/*}/dehydrated-hooks"
ARGS=()

log "hook: $(printf "'%s' " "$@")"

while (( $# )); do
	arg="$1"
	if [[ -d "$HOOK_DIR/$arg" ]]; then
		HOOK_DIR="$HOOK_DIR/$arg"
		ARGS+=( "$arg" )
		shift
	else
		break
	fi
done

HOOKS=()
# I'd really appreciate zsh's advanced globbing here...
for f in "$HOOK_DIR"/*; do
	if [[ -f "$f" && -x "$f" ]]; then
		HOOKS+=( "$f" )
	fi
done
if (( ${#HOOKS[@]} )); then
	log "hook: running ${#HOOKS[@]} scripts in '$HOOK_DIR'"
	for f in "${HOOKS[@]}"; do
		"$f" "${ARGS[@]}" "$@"
	done
else
	log "hook: nothing to do"
fi
