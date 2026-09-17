#!/system/bin/sh
set -eu
unset LD_PRELOAD LD_LIBRARY_PATH
asko_home=/data/data/com.termux/files/home
if [ "$(/system/bin/id -u)" != 0 ]; then
    exec /product/bin/su -c "/system/bin/sh $asko_home/fix"
fi
umask 077
asko_dir=/data/adb/asko-ssh
asko_script=$asko_dir/supervise.sh
asko_caps=$(awk '/^CapEff:/ {print $2}' /proc/self/status)
if [ "$asko_caps" = 0000000000000000 ]; then
    printf '%s\n' 'Open the Termux app on the phone and run: sh ~/fix' >&2
    exit 1
fi
if grep -q '/product/bin/su -d -g 10323' "$asko_script"; then
    test -f "$asko_script.before-capability-fix" || cp -p "$asko_script" "$asko_script.before-capability-fix"
    sed 's|/product/bin/su -d -g 10323|/product/bin/su -g 10323|' "$asko_script" >"$asko_script.next"
    /system/bin/sh -n "$asko_script.next"
    chmod 700 "$asko_script.next"
    mv "$asko_script.next" "$asko_script"
fi
if [ -f "$asko_dir/supervisor.pid" ]; then
    asko_pid=$(cat "$asko_dir/supervisor.pid")
    case "$asko_pid" in ''|*[!0-9]*) exit 1;; esac
    if [ -r "/proc/$asko_pid/cmdline" ]; then
        tr '\000' ' ' <"/proc/$asko_pid/cmdline" | grep -q '/data/adb/asko-ssh/supervise.sh'
        kill "$asko_pid"
    fi
    asko_count=0
    while [ -e "$asko_dir/supervisor.pid" ] && [ "$asko_count" -lt 50 ]; do
        /system/bin/sleep 0.2
        asko_count=$((asko_count+1))
    done
    test ! -e "$asko_dir/supervisor.pid"
fi
asko_pidfile=$(awk 'tolower($1)=="pidfile" {print $2; exit}' "$asko_home/.ssh/asko-sshd.conf")
asko_pidfile=${asko_pidfile:-/data/data/com.termux/files/usr/var/run/sshd.pid}
if [ -f "$asko_pidfile" ]; then
    asko_pid=$(cat "$asko_pidfile")
    case "$asko_pid" in ''|*[!0-9]*) exit 1;; esac
    if [ -r "/proc/$asko_pid/exe" ]; then
        test "$(readlink "/proc/$asko_pid/exe")" = /data/data/com.termux/files/usr/bin/sshd
        kill "$asko_pid"
    fi
fi
/system/bin/nohup /system/bin/sh "$asko_script" >>"$asko_dir/sshd.log" 2>&1 </dev/null &
printf '%s\n' 'SSH restriction removed. Reconnecting is required.'
if [ -f "$asko_home/asko/iris-install/iris-install-root.sh" ]; then
    /system/bin/sh "$asko_home/asko/iris-install/iris-install-root.sh" || {
        printf '%s\n' 'SSH fixed. Iris installation needs follow-up.'
        exit 1
    }
fi
printf '%s\n' 'Done.'
