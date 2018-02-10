#!/bin/bash -e

set -o pipefail

PSQL=/usr/bin/psql
CURL=/usr/bin/curl
LIST_URL="https://www.hello-matrix.net/public_servers.php?update_users=intelfx.name"

echo "SELECT is_guest, (password_hash IS NULL) AS is_deactivated, (password_hash='') AS is_bridged, COUNT(*) AS user_count FROM users GROUP BY is_guest, is_deactivated, is_bridged" | \
  psql -Aqt synapse | \
  curl -s --max-time 10 -X POST --data-binary @- "$LIST_URL"
