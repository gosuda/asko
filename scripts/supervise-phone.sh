#!/system/bin/sh
set -u
umask 077
asko_dir=/data/data/com.termux/files/home/asko
cd "$asko_dir"
mkdir -p var
exec 9>var/supervisor.lock
/system/bin/flock -n 9 9>&9 || exit 0
printf '%s\n' "$$" >var/supervisor.pid
asko_child=
asko_stop() {
    if [ -n "$asko_child" ]; then
        kill "$asko_child" 2>/dev/null || true
        wait "$asko_child" 2>/dev/null || true
    fi
    rm -f var/supervisor.pid var/child.pid
    exit 0
}
trap asko_stop TERM INT HUP
while [ ! -f var/disabled ]; do
    ./run-phone.sh >>var/service.log 2>&1 &
    asko_child=$!
    printf '%s\n' "$asko_child" >var/child.pid
    wait "$asko_child"
    asko_child=
    rm -f var/child.pid
    [ -f var/disabled ] || /system/bin/sleep 5
done
asko_stop
