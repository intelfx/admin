#!/bin/bash -e

SCRIPTDIR="$(dirname "$(realpath "$BASH_SOURCE")")"
exec "$SCRIPTDIR/../isolate/isolate.sh" "hook" "$@"
