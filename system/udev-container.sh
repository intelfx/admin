#!/bin/bash

# Loosely based on https://github.com/systemd/systemd/issues/21987#issuecomment-1058676889

set -eo pipefail
shopt -s lastpipe

if ! [[ -t 2 || -t 1 || -t 0 ]] && ! [[ ${UDEV_CONTAINER_REEXEC+set} ]]; then
        UDEV_CONTAINER_REEXEC=1 exec systemd-cat --identifier="udev-container" --level-prefix=true "$0" "$@"
fi

. /etc/admin/scripts/lib/lib.sh

_usage() {
        cat <<EOF
Usage:
        ${0##*/} add|remove <container> <sysfs-path> <dev-path> [links...]
        ${0##*/} execute <container>
Usage in udev rules:
        ACTION!="remove", RUN+="$0 add %E{CONTAINER} %S%p %N \$links
        ACTION=="remove", RUN+="$0 remove %E{CONTAINER} %S%p %N \$links
EOF
}


#
# args
#

STATE_DIR="/run/hacks/udev-container"
STATE_FILE="$STATE_DIR/known"
LOCK_FILE="$STATE_DIR/lock"

if (( $# < 1 )); then
        usage "wrong number of positional arguments (none provided)"
fi

ACTION="$1"
CONTAINER="$2"
SYSPATH="$3"
DEVNODE="$4"
LINKS=("${@:5}")

case "$ACTION" in
add|remove)
        if (( $# < 4 )); then
                usage "wrong number of positional arguments (expected 4 or more): ${*@Q}"
        fi
        ;;

execute)
        if (( $# != 2 )); then
                usage "wrong number of positional arguments (expected 2): ${*@Q}"
        fi
        CONTAINER="$2"
        ;;

*)
        die "invalid action argument: ${ACTION@Q}"
        ;;
esac

#
# function
#

execute() {
        local container="$1" script="$2"

        # log "executing script: $script"

        # if this fails, grant SystemCallFilter=@mount to your execution environment (i.e., systemd-udevd.service)
        systemd-run --quiet --machine="$container" --pipe --wait --collect --service-type=oneshot \
                /usr/bin/env sh -c "$script" </dev/null
        # fallback:
        # machinectl shell "$container" /bin/sh -c "$script" </dev/null
}

action_add() {
        local devtype cmd

        if [[ -b "$DEVNODE" ]]; then devtype="b"
        elif [[ -c "$DEVNODE" ]]; then devtype="c"
        else die "$DEVNODE: not a block or character device node"
        fi

        log "$DEVNODE: type=$devtype, links=(${LINKS[*]@Q})"

        LINKS=( "${LINKS[@]/#/'/dev/'}" )

        # we are (ab)using `stat --format=%N` to shell-quote the arg,
        # but it not only quotes the arg but also appends "-> 'target'" garbage if arg is a symlink
        [[ ! -L "$DEVNODE" ]] || die "internal error: devnode ${DEVNODE@Q} is a symlink"

        # build a POSIX sh script to inject into container
        cmd="main() { set -e"

        # create the main node (use `stat --format` for a cute hack)
        cmd+="
$(stat --format="mknod %N $devtype 0x%t 0x%T || test -$devtype %N; chown %u:%g %N; chmod 0%a %N" "$DEVNODE")
"

        # emit a loop to create symlinks with their parent directories
        # only do this if links exist to avoid emitting an empty loop
        if [[ ${LINKS+set} ]]; then
                cmd+="
for link in ${LINKS[*]@Q}; do
        mkdir -p \"\$(dirname \"\$link\")\"
        ln -rsfT ${DEVNODE@Q} \"\$link\"
done
"
        fi

        cmd+="}; main"

        execute "$CONTAINER" "$cmd"
}

action_remove() {
        local devtype cmd

        log "$DEVNODE: removing, links=(${LINKS[*]@Q})"

        LINKS=( "${LINKS[@]/#/'/dev/'}" )

        # build a POSIX sh script to inject into container
        cmd="main() { set -e"

        # remove the symlinks (do not bother about empty parent directories) first
        # only do this if links exist to avoid emitting an empty loop
        if [[ ${LINKS+set} ]]; then
                cmd+="
for link in ${LINKS[*]@Q}; do
        rm -f \"\$link\"
done
"
        fi

        # remove the main node
        cmd+="
rm -f ${DEVNODE@Q}
"

        cmd+="}; main"

        execute "$CONTAINER" "$cmd"
}

action_stage() (
        # do not stage actions executed as part the list of staged actions
        if [[ "${UDEV_CONTAINER_EXECUTE+set}" ]]; then
                return
        fi

        exec 9<>"$STATE_FILE"
        flock 9

        log "$DEVNODE: staging"

        case "$ACTION" in
        add)
                sed -r "\\&^'add' ${CONTAINER@Q} ${SYSPATH@Q} &d" -i "$STATE_FILE"
                echo "${*@Q}" >>"$STATE_FILE"
                ;;
        remove)
                sed -r "\\&^'add' ${CONTAINER@Q} ${SYSPATH@Q} &d" -i "$STATE_FILE"
                ;;
        *)
                die "invalid action argument"
                ;;
        esac
)

action_execute() (
        export UDEV_CONTAINER_EXECUTE=1

        exec 9<>"$STATE_FILE"
        flock 9

        log "executing staged actions"

        local -a lines
        readarray -t lines <&9
        exec 9>&-

        local line rc=0
        for line in "${lines[@]}"; do
                if [[ $line =~ ^[[:space:]]*($|\#.*) ]]; then
                        continue
                fi
                eval "${0@Q} $line" || rc=1
        done

        return $rc
)


#
# main
#

mkdir -p "$STATE_DIR"

# exec 8<>"$LOCK_FILE"
# flock 8

LIBSH_LOG_PREFIX="$ACTION($CONTAINER)"

# keep track of eligible devices, whike the container is running or not
# (a container can be rebooted multiple times)
case "$ACTION" in
add|remove)
        action_stage "$@" ;;
esac

case "$(systemctl -M "$CONTAINER" is-system-running 2>/dev/null)" in
running|starting) ;;
*) exit ;;
esac

case "$ACTION" in
add)
        action_add ;;
remove)
        action_remove ;;
execute)
        action_execute ;;
*)
        die "invalid action argument" ;;
esac
