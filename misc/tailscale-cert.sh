#!/bin/bash

set -exo pipefail
shopt -s lastpipe

tailscale status --self=true --peers=false --json \
| jq -r '.Self.DNSName | sub("\\.$"; "")' \
| read hostname

mkdir -p "${hostname}"
cd "${hostname}"
exec tailscale cert "${hostname}"
