#!/usr/bin/env bash
set -euo pipefail
asko_action=${1:-status}
asko_target=${2:-asko-phone}
case "$asko_action" in start|stop|status|restart) ;; *) printf '%s\n' 'Usage: control-phone.sh start|stop|status|restart [SSH alias]' >&2; exit 2;; esac
if [[ ! "$asko_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then exit 2; fi
ssh -o BatchMode=yes -- "$asko_target" /system/bin/sh -s -- "$asko_action" <<'REMOTE'
set -eu
asko_dir=/data/data/com.termux/files/home/asko
cd "$asko_dir"
asko_cwd=$(pwd -P)
mkdir -p var
asko_action=$1
asko_clear_pids() {
    # Called only while holding the supervisor lock. Leave its inode in place.
    rm -f var/supervisor.pid var/child.pid var/embedding.pid
}
asko_is_supervisor() {
    case "$asko_pid" in ''|*[!0-9]*|0|1) return 1;; esac
    [ -r "/proc/$asko_pid/cmdline" ] || return 1
    [ "$(readlink "/proc/$asko_pid/cwd" 2>/dev/null)" = "$asko_cwd" ] || return 1
    asko_command=$(tr '\000' '\n' <"/proc/$asko_pid/cmdline") || return 1
    # Match complete arguments, not a substring in an unrelated command.
    asko_relative=$(printf '/system/bin/sh\n./supervise-phone.sh')
    asko_absolute=$(printf '/system/bin/sh\n%s/supervise-phone.sh' "$asko_dir")
    [ "$asko_command" = "$asko_relative" ] || [ "$asko_command" = "$asko_absolute" ]
}
asko_stop() {
    touch var/disabled
    exec 9>>var/supervisor.lock
    if /system/bin/flock -n 9 9>&9; then
        asko_clear_pids
        exec 9>&-
        return 0
    fi
    asko_pid=$(cat var/supervisor.pid 2>/dev/null) || asko_pid=
    if ! asko_is_supervisor; then
        printf '%s\n' 'Supervisor lock is held but its process cannot be verified; refusing to signal a PID.' >&2
        return 1
    fi
    kill "$asko_pid" 2>/dev/null || true
    asko_count=0
    while [ "$asko_count" -lt 100 ]; do
        if /system/bin/flock -n 9 9>&9; then
            asko_clear_pids
            exec 9>&-
            return 0
        fi
        /system/bin/sleep 0.1; asko_count=$((asko_count+1))
    done
    printf '%s\n' 'Shutdown is still in progress; retry after it finishes.' >&2
    return 1
}
if [ "$asko_action" = stop ] || [ "$asko_action" = restart ]; then asko_stop; fi
if [ "$asko_action" = start ] || [ "$asko_action" = restart ]; then
    rm -f var/disabled
    /system/bin/nohup /system/bin/sh ./supervise-phone.sh >>var/service.log 2>&1 </dev/null &
    /system/bin/sleep 0.2
    if [ ! -s var/supervisor.pid ]; then
        printf '%s\n' 'Supervisor did not start; check var/service.log.' >&2
        exit 1
    fi
fi
if [ "$asko_action" = status ]; then ./run-phone.sh status; fi
if [ -f var/supervisor.pid ]; then printf 'supervisor PID: '; cat var/supervisor.pid; else printf '%s\n' 'supervisor stopped'; fi
REMOTE
