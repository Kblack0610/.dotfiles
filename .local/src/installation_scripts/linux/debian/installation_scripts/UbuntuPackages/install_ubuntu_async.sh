#!/usr/bin/env bash
set +x
set -e
# inspired by https://stackoverflow.com/a/29535256/2860309
. ./install_requirements_functions.sh 
pids=""
failures=0

function my_process() {
    seconds_to_sleep=$1
    exit_code=$2
    sleep "$seconds_to_sleep"
    return "$exit_code"
}

(install_reqs 1 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: running reqs"

(install_tools 1 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: runnning tools"

(install_git 2 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: runnning git "

(install_bash_reqs 2 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: runnning bash reqs"

(install_kitty 2 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: runnning kitty"

(install_lazygit 2 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: runnning lazygit"

(install_nvim 2 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: runnning nvim"

(install_google_chrome 2 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: runnning google chrome"

(install_stow 2 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: runnning stow"

(install_i3 2 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: runnning stow"

(install_dotfiles 2 0) &
pid=$!
pids+=" ${pid}"
echo "${pid}: runnning dotfiles"




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

