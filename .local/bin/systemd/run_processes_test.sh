#!/usr/bin/env bash

# inspired by https://stackoverflow.com/a/29535256/2860309

pids=""
failures=0

function my_process() {
    seconds_to_sleep=$1
    exit_code=$2
    sleep "$seconds_to_sleep"
    return "$exit_code"
}

(my_process 1 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: 1 second to success"

(my_process 1 1) &
pid=$!
pids+=" ${pid}"
echo "${pid}: 1 second to failure"

(my_process 2 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: 2 seconds to success"

(my_process 2 1) &
pid=$!
pids+=" ${pid}"
echo "${pid}: 2 seconds to failure"

echo "..."

for pid in $pids; do
        if wait "$pid"; then
                echo "Process $pid succeeded"
        else
                echo "Process $pid failed"
                failures=$((failures+1))
        fi
done

echo
echo "${failures} failures detected"

