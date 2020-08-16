#!/bin/bash -e

RCU_PID="$(pgrep rcu_preempt || pgrep rcu_sched)"

# display current scheduling parameters of the RCU process
chrt -p "$RCU_PID"
# reset the RCU process to normal scheduling
chrt --other -p 0 "$RCU_PID"
