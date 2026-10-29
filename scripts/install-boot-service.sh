#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
asko_target=asko-phone
asko_with_iris=0
asko_target_set=0
asko_usage() {
    cat <<'USAGE'
Usage: scripts/install-boot-service.sh [--with-iris] [SSH_TARGET]

Install the backend boot entry; --with-iris also installs the packaged Iris entry.
SSH_TARGET defaults to asko-phone and must log in as the Termux app account.
Requires Magisk service.d; --with-iris requires packaged Iris to be installed first.
Identical entries are accepted. Different existing entries (including older
managed versions) are refused and left unchanged; there is no automatic update.
Installation does not start or restart either service. Boot waits in the
background for first unlock and storage readiness, without a deadline.
USAGE
}
for asko_arg in "$@"; do
    case "$asko_arg" in
        --with-iris) asko_with_iris=1;;
        -h|--help) asko_usage; exit 0;;
        -*) asko_usage >&2; exit 2;;
        *)
            if [ "$asko_target_set" = 1 ]; then asko_usage >&2; exit 2; fi
            asko_target=$asko_arg
            asko_target_set=1
            ;;
    esac
done
if [[ ! "$asko_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then asko_usage >&2; exit 2; fi

# Inspect identity and executable prerequisites, without reading app data or
# invoking a service. Only stdout's validated UID is used locally.
asko_uid=$(ssh -o BatchMode=yes -- "$asko_target" /system/bin/sh -s -- "$asko_with_iris" <<'REMOTE'
set -eu
unset LD_PRELOAD LD_LIBRARY_PATH
asko_uid=$(id -u)
case "$asko_uid" in ''|*[!0-9]*) exit 1;; esac
if ! [ "$asko_uid" -ge 10000 ] ||
   [ "$(/system/bin/stat -c %u /data/data/com.termux)" != "$asko_uid" ]; then
    printf '%s\n' 'SSH must use the Termux app account, not root or another app UID.' >&2
    exit 1
fi
asko_su=$(command -v su 2>/dev/null || true)
if [ -z "$asko_su" ] || [ ! -x "$asko_su" ]; then
    asko_su=
    for asko_candidate in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su /su/bin/su /product/bin/su; do
        if [ -x "$asko_candidate" ]; then asko_su=$asko_candidate; break; fi
    done
fi
[ -n "$asko_su" ] || { printf '%s\n' 'No executable su found.' >&2; exit 1; }
# Verify the same UID/GID drop used by the backend boot launcher.
asko_drop_uid=$("$asko_su" -d -g "$asko_uid" -G 3003 -s /system/bin/sh "$asko_uid" -c '/system/bin/id -u')
[ "$asko_drop_uid" = "$asko_uid" ] || { printf '%s\n' 'su cannot launch the backend as the Termux UID.' >&2; exit 1; }
"$asko_su" -c "/system/bin/sh -s -- $1" <<'ROOT'
set -eu
[ "$(id -u)" = 0 ] || exit 1
[ -d /data/adb/service.d ] && [ -w /data/adb/service.d ] || {
    printf '%s\n' 'Writable Magisk /data/adb/service.d is required.' >&2; exit 1;
}
for asko_command in /system/bin/sh /system/bin/stat /system/bin/sleep; do
    [ -x "$asko_command" ] || { printf 'Missing executable: %s\n' "$asko_command" >&2; exit 1; }
done
for asko_command in cmp cp chmod mktemp ln rm; do
    command -v "$asko_command" >/dev/null || exit 1
done
if [ "$1" = 1 ]; then
    for asko_command in /system/bin/iptables /system/bin/ip6tables /system/bin/unshare /system/bin/mount /system/bin/app_process /system/bin/nohup; do
        [ -x "$asko_command" ] || { printf 'Missing Iris executable: %s\n' "$asko_command" >&2; exit 1; }
    done
    [ -f /data/local/tmp/asko-iris/Iris.apk ] &&
        [ -x /data/local/tmp/asko-iris/iris-start.sh ] &&
        [ -r /data/local/tmp/asko-iris/iris-inner.sh ] || {
        printf '%s\n' 'Install packaged Iris with scripts/deploy-iris-phone.sh first.' >&2; exit 1;
    }
    /system/bin/sh -n /data/local/tmp/asko-iris/iris-start.sh
    /system/bin/sh -n /data/local/tmp/asko-iris/iris-inner.sh
fi
ROOT
printf '%s\n' "$asko_uid"
REMOTE
)
if [[ ! "$asko_uid" =~ ^[0-9]+$ ]] || ! [ "$asko_uid" -ge 10000 ]; then
    printf '%s\n' 'Preflight did not return a valid Termux UID.' >&2; exit 1
fi
mkdir -p "$asko_repo/.cache"
asko_boot=$(mktemp -d "$asko_repo/.cache/asko-boot.XXXXXX")
trap 'rm -rf -- "$asko_boot"' EXIT
sed "s/@UID@/$asko_uid/g" "$asko_repo/tools/magisk-asko.sh.in" >"$asko_boot/backend.sh"
scp -q "$asko_boot/backend.sh" "$asko_target:asko/boot-service.pending.sh"
if [ "$asko_with_iris" = 1 ]; then
    sed "s/@UID@/$asko_uid/g" "$asko_repo/tools/magisk-iris.sh.in" >"$asko_boot/iris.sh"
    scp -q "$asko_boot/iris.sh" "$asko_target:asko/iris-boot-service.pending.sh"
fi
ssh -o BatchMode=yes -- "$asko_target" /system/bin/sh -s -- "$asko_with_iris" <<'REMOTE'
set -eu
unset LD_PRELOAD LD_LIBRARY_PATH
asko_su=$(command -v su 2>/dev/null || true)
if [ -z "$asko_su" ] || [ ! -x "$asko_su" ]; then
    asko_su=
    for asko_candidate in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su /su/bin/su /product/bin/su; do
        if [ -x "$asko_candidate" ]; then asko_su=$asko_candidate; break; fi
    done
fi
[ -n "$asko_su" ] || exit 1
"$asko_su" -c "/system/bin/sh -s -- $1" <<'ROOT'
set -eu
umask 077
[ "$(id -u)" = 0 ] || exit 1
asko_backend=/data/data/com.termux/files/home/asko/boot-service.pending.sh
asko_iris=/data/data/com.termux/files/home/asko/iris-boot-service.pending.sh
asko_with_iris=$1
asko_pending=
trap 'rm -f -- "$asko_backend"; [ "$asko_with_iris" != 1 ] || rm -f -- "$asko_iris"; [ -z "$asko_pending" ] || rm -f -- "$asko_pending"' EXIT
asko_check_entry() {
    [ -f "$1" ] && [ ! -L "$1" ] || exit 1
    /system/bin/sh -n "$1"
    if [ -e "$2" ] || [ -L "$2" ]; then
        if [ -L "$2" ] || [ ! -f "$2" ] || ! cmp -s "$1" "$2"; then
            printf 'Refusing to replace existing boot entry: %s\n' "$2" >&2
            exit 1
        fi
    fi
}
asko_install_entry() {
    if [ -e "$2" ] || [ -L "$2" ]; then
        asko_check_entry "$1" "$2"
        return 0
    fi
    asko_pending=$(mktemp /data/adb/service.d/.asko-boot.XXXXXX)
    cp "$1" "$asko_pending"
    chmod 700 "$asko_pending"
    # Publish the complete file without overwriting a concurrently added entry.
    if ! ln "$asko_pending" "$2"; then asko_check_entry "$1" "$2"; fi
    rm -f -- "$asko_pending"
    asko_pending=
}
# Validate both selected destinations before installing either one.
asko_check_entry "$asko_backend" /data/adb/service.d/asko-backend.sh
if [ "$asko_with_iris" = 1 ]; then asko_check_entry "$asko_iris" /data/adb/service.d/asko-iris.sh; fi
asko_install_entry "$asko_backend" /data/adb/service.d/asko-backend.sh
if [ "$asko_with_iris" = 1 ]; then asko_install_entry "$asko_iris" /data/adb/service.d/asko-iris.sh; fi
ROOT
REMOTE
printf '%s\n' 'Backend boot entry installed or already identical.'
if [ "$asko_with_iris" = 1 ]; then printf '%s\n' 'Iris boot entry installed or already identical.'; fi
printf '%s\n' 'No service was started or restarted. Boot waits in the background for first unlock and storage readiness.'
