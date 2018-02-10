#!/bin/bash

exec systemctl start "nfcapd-process@$(systemd-escape --path "$1").service"
