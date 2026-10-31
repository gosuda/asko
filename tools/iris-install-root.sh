#!/system/bin/sh
# Install the pinned Iris build, or restore the previous one with "rollback". Runs as root.
set -eu
umask 077
unset LD_PRELOAD LD_LIBRARY_PATH
asko_stage=/data/data/com.termux/files/home/asko/iris-install
asko_iris=/data/local/tmp/asko-iris
asko_sha=16bfed70f55d06b1553e2de9b923bf8515fdb26b5675fba5f315e66631a3f80f
test "$(id -u)" = 0
asko_running_pid() {
    asko_pid=$(cat "$asko_iris/iris.pid" 2>/dev/null || :)
    case "$asko_pid" in ''|*[!0-9]*) return 1;; esac
    [ -r "/proc/$asko_pid/cmdline" ] && tr '\000' ' ' <"/proc/$asko_pid/cmdline" | grep -q 'party.qwer.iris.Main'
}
asko_stop_iris() {
    asko_running_pid || return 0
    kill "$asko_pid"
    asko_wait=0
    while [ -d "/proc/$asko_pid" ] && [ "$asko_wait" -lt 30 ]; do
        /system/bin/sleep 1
        asko_wait=$((asko_wait + 1))
    done
    if [ -d "/proc/$asko_pid" ]; then
        printf '%s\n' 'The running Iris did not stop.' >&2
        return 1
    fi
}
asko_start_checked() {
    /system/bin/sh "$asko_iris/iris-start.sh"
    /system/bin/sleep 3
    asko_running_pid
}
asko_restore() {
    asko_backup=$(cat "$asko_iris/releases/last-backup" 2>/dev/null || :)
    case "$asko_backup" in "$asko_iris"/releases/before-*) ;; *) printf '%s\n' 'No Iris backup to restore.' >&2; return 1;; esac
    test -f "$asko_backup/Iris.apk"
    asko_stop_iris
    for asko_file in Iris.apk iris-inner.sh iris-start.sh config.json; do
        if [ -f "$asko_backup/$asko_file" ]; then
            cp "$asko_backup/$asko_file" "$asko_iris/$asko_file.rollback"
            mv -f "$asko_iris/$asko_file.rollback" "$asko_iris/$asko_file"
        fi
    done
    /system/bin/sh "$asko_iris/iris-start.sh"
    printf 'Restored Iris from %s\n' "$asko_backup"
}
if [ "${1:-install}" = rollback ]; then
    asko_restore
    exit 0
fi
cd "$asko_stage"
printf '%s  %s\n' "$asko_sha" Iris.apk | sha256sum -c -
mkdir -p "$asko_iris/releases"
chmod 700 "$asko_iris" "$asko_iris/releases"
asko_changed=
for asko_file in Iris.apk iris-start.sh iris-inner.sh; do
    cmp -s "$asko_file" "$asko_iris/$asko_file" || asko_changed=1
done
if [ -z "$asko_changed" ]; then
    # Same build: only make sure Iris and its firewall rules are up.
    /system/bin/sh "$asko_iris/iris-start.sh"
    exit 0
fi
if [ -f "$asko_iris/Iris.apk" ]; then
    asko_backup="$asko_iris/releases/before-$(date +%Y%m%d-%H%M%S)"
    mkdir "$asko_backup"
    for asko_file in Iris.apk iris-inner.sh iris-start.sh config.json; do
        if [ -f "$asko_iris/$asko_file" ]; then cp "$asko_iris/$asko_file" "$asko_backup/"; fi
    done
    printf '%s\n' "$asko_backup" >"$asko_iris/releases/last-backup"
fi
for asko_file in Iris.apk iris-start.sh iris-inner.sh; do
    cp "$asko_file" "$asko_iris/$asko_file.next"
done
chmod 600 "$asko_iris/Iris.apk.next"
chmod 700 "$asko_iris/iris-start.sh.next" "$asko_iris/iris-inner.sh.next"
asko_stop_iris
for asko_file in Iris.apk iris-start.sh iris-inner.sh; do
    mv -f "$asko_iris/$asko_file.next" "$asko_iris/$asko_file"
done
if ! asko_start_checked; then
    printf '%s\n' 'The new Iris did not stay up; restoring the previous build.' >&2
    if [ -f "$asko_iris/releases/last-backup" ]; then asko_restore; fi
    exit 1
fi
# Keep the three newest automatic backups.
asko_count=0
for asko_old in $(ls -1d "$asko_iris"/releases/before-2* 2>/dev/null | sort -r); do
    asko_count=$((asko_count + 1))
    if [ "$asko_count" -gt 3 ]; then rm -rf -- "$asko_old"; fi
done
printf '%s\n' 'Iris installed.'
