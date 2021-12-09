#!/bin/bash -e

set -eo pipefail
shopt -s lastpipe

cd "${BASH_SOURCE%/*}"
. lib/lib.sh || exit 1

BORGBASE_API="https://api.borgbase.com/graphql"
BORGBASE_KEY="/etc/admin/keys/borgbase"

if ! (( $# == 2 )); then
	die "Expected 2 argument, got $# (usage: $0 <repo name> <repoAdd arguments>)"
fi
REPO_NAME="$1"
REPO_ADD_ARGS="$2"
BORG_INIT=( borg init -e repokey-blake2 )

call_borgbase() {
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

id_to_url() {
	echo "$1@$1.repo.borgbase.com"
}

#call_borgbase "query" "{ repoList{id, name} }" | jq >&2

call_borgbase "query" "{ repoList{id, name} }" | jq -r -e '.data.repoList[] | "\(.id)\t\(.name)"' | while IFS=$'\t' read id name; do
	if [[ "$REPO_NAME" == "$name" ]]; then
		id_to_url "$id"
		exit 0
	fi
done

call_borgbase "query" "mutation { repoAdd(name:\"$REPO_NAME\", quotaEnabled: false, alertDays: 0, $REPO_ADD_ARGS) { repoAdded{id} } }" | jq -r -e '.data.repoAdd.repoAdded.id' | while read id; do
	id_to_url "$id"
	exit 0
done

err "Could not get or create repo"
exit 1
