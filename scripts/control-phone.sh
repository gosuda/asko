#!/usr/bin/env bash
set -euo pipefail
asko_action=${1:-status}
asko_target=${2:-asko-phone}
case "$asko_action" in start|stop|status|restart) ;; *) printf '%s\n' 'Usage: control-phone.sh start|stop|status|restart [SSH alias]' >&2; exit 2;; esac
if [[ ! "$asko_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then exit 2; fi
ssh -o BatchMode=yes -- "$asko_target" /system/bin/sh -s -- "$asko_action" <<'REMOTE'
set -eu
cd /data/data/com.termux/files/home/asko
asko_action=$1
asko_stop() {
    touch var/disabled
    if [ -f var/supervisor.pid ]; then
        asko_pid=$(cat var/supervisor.pid)
        case "$asko_pid" in ''|*[!0-9]*) exit 1;; esac
        if [ -r "/proc/$asko_pid/cmdline" ]; then
            asko_command=$(tr '\000' ' ' <"/proc/$asko_pid/cmdline")
            case "$asko_command" in *supervise-phone.sh*) kill "$asko_pid";; *) printf '%s\n' 'Refusing to stop a different process' >&2; exit 1;; esac
        fi
        asko_count=0
        while [ -f var/supervisor.pid ] && [ "$asko_count" -lt 100 ]; do
            /system/bin/sleep 0.1; asko_count=$((asko_count+1))
        done
        if [ -f var/supervisor.pid ]; then
            printf '%s\n' 'Shutdown is still in progress; retry after it finishes.' >&2
            exit 1
        fi
    fi
}
if [ "$asko_action" = stop ] || [ "$asko_action" = restart ]; then asko_stop; fi
if [ "$asko_action" = start ] || [ "$asko_action" = restart ]; then
    rm -f var/disabled
    /system/bin/nohup /system/bin/sh ./supervise-phone.sh >/dev/null 2>&1 </dev/null &
    /system/bin/sleep 0.2
fi
if [ "$asko_action" = status ]; then ./run-phone.sh status; fi
if [ -f var/supervisor.pid ]; then printf 'supervisor PID: '; cat var/supervisor.pid; else printf '%s\n' 'supervisor stopped'; fi
REMOTE
