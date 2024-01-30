#!/bin/sh

# needrestart - Restart daemons after library updates.
#
# Restarting systemd using special systemctl call.
#

# enable xtrace if we should be verbose
if [ "$NR_VERBOSE" = '1' ]; then
    set -x
fi

trace() {
    echo "-> $*" >&2
    "$@"
}

rc=0
trace systemctl daemon-reexec || rc=1

systemctl show --state=active --property User --value 'user@*.service' | grep -v -Fx '' | while read uid; do
    trace systemctl -M "$uid@.host" --user daemon-reexec || rc=1
done

exit $rc
