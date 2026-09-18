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
asko_embedding=
asko_embedding_mode=$(./run-phone.sh embedding-mode) || exit 1
asko_stop() {
    if [ -n "$asko_embedding" ]; then
        kill "$asko_embedding" 2>/dev/null || true
        wait "$asko_embedding" 2>/dev/null || true
    fi
    if [ -n "$asko_child" ]; then
        kill "$asko_child" 2>/dev/null || true
        wait "$asko_child" 2>/dev/null || true
    fi
    rm -f var/supervisor.pid var/child.pid var/embedding.pid
    exit 0
}
trap asko_stop TERM INT HUP
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
    kill "$asko_child" 2>/dev/null || true
    [ -z "$asko_embedding" ] || kill "$asko_embedding" 2>/dev/null || true
    wait "$asko_child" 2>/dev/null || true
    [ -z "$asko_embedding" ] || wait "$asko_embedding" 2>/dev/null || true
    asko_child=
    asko_embedding=
    rm -f var/child.pid var/embedding.pid
    [ -f var/disabled ] || /system/bin/sleep 5
done
asko_stop
