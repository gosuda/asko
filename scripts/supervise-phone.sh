#!/system/bin/sh
set -eu
umask 077
asko_dir=/data/data/com.termux/files/home/asko
cd "$asko_dir"
mkdir -p var
# Keep this inode in place: removing an empty lock file can split the lock.
exec 9>>var/supervisor.lock
/system/bin/flock -n 9 9>&9 || exit 0
asko_child=
asko_embedding=
asko_kill_child() {
    # A terminated/reaped child's PID may have been reused by another process.
    [ -r "/proc/$1/status" ] || return 0
    if [ "$(awk '/^PPid:/ {print $2}' "/proc/$1/status" 2>/dev/null)" = "$$" ]; then
        kill "$1" 2>/dev/null || true
    fi
}
asko_cleanup() {
    trap - EXIT TERM INT HUP
    if [ -n "$asko_embedding" ]; then
        asko_kill_child "$asko_embedding"
        wait "$asko_embedding" 2>/dev/null || true
    fi
    if [ -n "$asko_child" ]; then
        asko_kill_child "$asko_child"
        wait "$asko_child" 2>/dev/null || true
    fi
    rm -f var/supervisor.pid var/child.pid var/embedding.pid
}
trap asko_cleanup EXIT
trap 'exit 0' TERM INT HUP
printf '%s\n' "$$" >var/supervisor.pid
asko_embedding_mode=$(./run-phone.sh embedding-mode)
while [ ! -f var/disabled ]; do
    if [ "$asko_embedding_mode" = local ]; then
        ./run-embedding-phone.sh >>var/embedding.log 2>&1 &
        asko_embedding=$!
        printf '%s\n' "$asko_embedding" >var/embedding.pid
    fi
    ./run-phone.sh >>var/service.log 2>&1 &
    asko_child=$!
    printf '%s\n' "$asko_child" >var/child.pid
    while kill -0 "$asko_child" 2>/dev/null && { [ -z "$asko_embedding" ] || kill -0 "$asko_embedding" 2>/dev/null; }; do
        /system/bin/sleep 1
    done
    asko_kill_child "$asko_child"
    [ -z "$asko_embedding" ] || asko_kill_child "$asko_embedding"
    wait "$asko_child" 2>/dev/null || true
    [ -z "$asko_embedding" ] || wait "$asko_embedding" 2>/dev/null || true
    asko_child=
    asko_embedding=
    rm -f var/child.pid var/embedding.pid
    [ -f var/disabled ] || /system/bin/sleep 5
done
