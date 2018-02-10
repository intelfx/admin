#!/bin/bash -e

set -o pipefail
btrfs filesystem show "$1" | grep -Po '(?<=uuid: )[0-9a-f-]+'
