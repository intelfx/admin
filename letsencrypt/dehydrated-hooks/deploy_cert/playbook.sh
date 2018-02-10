#!/bin/bash -e

. "${BASH_SOURCE%/*}/lib/lib.sh" || exit

echo "$1_real ${*:2}" >> playbook
