#!/hint/bash

ARGS=( "$@" )
ACTIONS=()
PLAYBOOK=()
FAILS=()

hook() {
	local opt opt_priv=0 opt_regex=0 OPTIND=1
	while getopts ':PEF' opt "$@"; do
		case "$opt" in
		P) opt_priv=1 ;;
		E) opt_regex=1 ;;
		F) opt_regex=0 ;;
		'?') die "invalid hook() invocation: ${@@Q}" ;;
		esac
	done
	shift $(( OPTIND-1 ))

	local i in_arg expr_arg
	for (( i = 1; i < $#; ++i )); do
		expr_arg="${!i}"
		if [[ $expr_arg == -- ]]; then
			break
		fi
		if ! (( i-1 < ${#ARGS[@]} )); then
			# no match
			return
		fi
		in_arg="${ARGS[i-1]}"
		if (( opt_regex )) && ! [[ ${in_arg} =~ ^${expr_arg}$ ]]; then
			# no match
			return
		fi
		if (( !opt_regex )) && ! [[ ${in_arg} == ${expr_arg} ]]; then
			# no match
			return
		fi
	done
	local cmd=( "${@:i+1}" "${ARGS[@]}" )
	if (( opt_priv )); then
		PLAYBOOK+=( "${cmd[*]@Q}" )
	else
		ACTIONS+=( "${cmd[*]@Q}" )
	fi
}

run_playbook() {
	log "running playbook"

	if [[ -e playbook ]]; then
		readarray -t ACTIONS < playbook
		rm -f playbook
	fi

	# perform privileged actions from the playbook
	set +e
	for cmd in "${ACTIONS[@]}"; do
		log "action (from playbook): $cmd"
		( set -e; eval "$cmd" )
		(( $? )) && FAILS+=( "$cmd" )
	done
	set -e

	if ! (( ${#ACTIONS[@]} )); then
		# log if nothing happened
		log "empty playbook, nothing to run"
	fi

	if (( ${#FAILS[@]} )); then
		# log if some of the actions failed
		err "${#FAILS[@]} failed actions:"
		printf "${_LIBSH_PREFIX[error]} * %s\n" "${FAILS[@]}" >&2
		return 1
	fi
}

run_actions() {
	dbg "evaluating: ${ARGS[@]@Q}"

	# perform unprivileged actions
	set +e
	for cmd in "${ACTIONS[@]}"; do
		log "action: $cmd"
		( set -e; eval "$cmd" )
		(( $? )) && FAILS+=( "$cmd" )
	done
	set -e

	# record privileged actions into playbook
	for cmd in "${PLAYBOOK[@]}"; do
		log "action (into playbook): $cmd"
		echo "$cmd" >> playbook
	done

	if ! (( ${#ACTIONS[@]} || ${#PLAYBOOK[@]} )); then
		# log if nothing happened
		dbg "nothing to do"
	fi

	if (( ${#FAILS[@]} )); then
		# log if some of the actions failed
		err "${#FAILS[@]} failed actions:"
		printf "${_LIBSH_PREFIX[error]} * %s\n" "${FAILS[@]}" >&2
		return 1
	fi
}
