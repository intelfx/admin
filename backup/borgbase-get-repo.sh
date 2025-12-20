#!/bin/bash

set -eo pipefail
shopt -s lastpipe

cd "${BASH_SOURCE%/*}"
. lib/lib.sh

#
# constants
#

BORGBASE_API="https://api.borgbase.com/graphql"
BORGBASE_KEY="/etc/admin/keys/borgbase"
BORGBASE_MAX_WAIT=300

#
# arguments
#

_usage() {
	cat <<EOF
Usage: $0 <REPO-NAME> <REPOADD-PARAMS>

Returns a SSH URL of a BorgBase repository with given name, potentially
creating it.

Arguments:
	REPO-NAME	Name of BorgBase repository to acquire
	REPO-ADD-PARAMS	Parameters for BorgBase repoAdd API
			(jq syntax, without the top-level object)
EOF
}

if ! (( $# == 2 )); then
	usage "Expected 2 arguments, got $#"
fi
REPO_NAME="$1"
REPO_ADD_ARGS="$2"

#
# functions
#

borgbase_call() {
	local type="$1"
	local graphql="$2"
	local json="$(jq -c -n --arg type "$type" --arg graphql "$graphql" '{ ($type): $graphql }')"
	shift

	eval "$(ltraps)"
	local rc status response="$(mktemp)"
	ltrap 'rm -f "$response"'

	dbg "Invoking BorgBase API ($BORGBASE_API): $graphql"
	status="$(curl -sS \
		-XPOST \
		-H 'Content-Type: application/json' \
		-H 'Accept: application/json' \
		-H "Authorization: Bearer $(< "$BORGBASE_KEY")" \
		-d "$json" \
		"$BORGBASE_API" \
		-o "$response" \
		-w "%{response_code}" \
	)" && rc=0 || rc=$?

	if (( rc )); then
		err "Failed to invoke BorgBase API ($BORGBASE_API): curl returned $rc"
		err "Request: $json"
		err "Response:"
		jq <"$response" >&2
		return $rc
	fi

	if (( status < 200 || status > 299 )); then
		err "Failed to invoke BorgBase API ($BORGBASE_API): HTTP $status"
		err "Request: $json"
		err "Response:"
		jq <"$response" >&2
		return 22
	fi

	if jq -e '.errors' "$response" &>/dev/null; then
		err "Failed to invoke BorgBase API ($BORGBASE_API): error returned"
		err "Request: $json"
		err "Response:"
		jq <"$response" >&2
		return 1
	fi

	cat "$response"
}

borgbase_wait() {
	local host="$1"
	local start_ts="$(date +%s)" now_ts
	local timeout=1

	while :; do
		if getent hosts "$host" &>/dev/null; then
			break
		fi
		now_ts="$(date +%s)"
		if ! (( now_ts < start_ts + BORGBASE_MAX_WAIT )); then
			err "Failed to wait for $url to resolve ($((now_ts-start_ts))s >= ${BORGBASE_MAX_WAIT}s)"
			return 1
		fi

		log "Waiting ${timeout}s for $host to resolve..."
		sleep "$timeout"
		(( timeout = timeout*2 < 60 ? timeout*2 : 60 ))
	done
}

id_to_host() {
	echo "$1.repo.borgbase.com"
}

id_to_url() {
	echo "$1@$1.repo.borgbase.com"
}

borgbase_respond() {
	local id="$1"

	borgbase_wait "$(id_to_host "$id")"
	id_to_url "$id"  # prints to stdout
}

#
# main
#

borgbase_call "query" "{ repoList{id, name} }" | jq -r -e '.data.repoList[] | "\(.id)\t\(.name)"' | while IFS=$'\t' read id name; do
	if [[ "$REPO_NAME" == "$name" ]]; then
		borgbase_respond "$id"
		exit 0
	fi
done

borgbase_call "query" "mutation { repoAdd(name:\"$REPO_NAME\", quotaEnabled: false, alertDays: 0, $REPO_ADD_ARGS) { repoAdded{id} } }" | jq -r -e '.data.repoAdd.repoAdded.id' | while read id; do
	borgbase_respond "$id"
	exit 0
done

err "Failed to get or create BorgBase repo \"$REPO_NAME\'"
exit 1
