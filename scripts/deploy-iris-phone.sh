#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$asko_repo"
asko_target=${1:-asko-phone}
if [[ ! "$asko_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then exit 2; fi
asko_su=$(ssh -o BatchMode=yes -- "$asko_target" 'sh -s' <<'REMOTE'
set -eu
asko_uid=$(id -u)
case "$asko_uid" in
    ''|*[!0-9]*)
        printf '%s\n' 'Invalid SSH UID; connect as the Termux app user.' >&2
        exit 1
        ;;
esac
if ! [ "$asko_uid" -ge 10000 ]; then
    printf '%s\n' 'SSH UID must be a Termux app UID (>=10000), not root.' >&2
    exit 1
fi
asko_termux_uid=$(/system/bin/stat -c %u /data/data/com.termux)
if [ "$asko_uid" != "$asko_termux_uid" ]; then
    printf '%s\n' 'SSH UID does not own /data/data/com.termux.' >&2
    exit 1
fi
asko_su=$(command -v su 2>/dev/null || :)
if [ -z "$asko_su" ] || [ ! -x "$asko_su" ]; then
    asko_su=
    for asko_candidate in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su /su/bin/su /product/bin/su; do
        if [ -x "$asko_candidate" ]; then
            asko_su=$asko_candidate
            break
        fi
    done
fi
if [ -z "$asko_su" ]; then
    printf '%s\n' 'No executable su found on the phone.' >&2
    exit 1
fi
if ! asko_root_uid=$(env -u LD_PRELOAD -u LD_LIBRARY_PATH "$asko_su" -c 'id -u') || [ "$asko_root_uid" != 0 ]; then
    printf '%s\n' 'su did not grant root access.' >&2
    exit 1
fi
printf '%s\n' "$asko_su"
REMOTE
)
# SSH evaluates the command through the remote shell; escape embedded quotes.
asko_su_quoted=${asko_su//\'/\'\\\'\'}
asko_iris_version=v0.33
asko_iris_cache=.cache/iris/$asko_iris_version
mkdir -p "$asko_iris_cache"
if [ ! -f "$asko_iris_cache/Iris.apk" ]; then
    curl -fLsS --retry 2 -o "$asko_iris_cache/Iris.apk.part" "https://github.com/dolidolih/Iris/releases/download/$asko_iris_version/Iris.apk"
    mv "$asko_iris_cache/Iris.apk.part" "$asko_iris_cache/Iris.apk"
fi
printf '%s  %s\n' c4f61523ac41353f97c3547e12f32bf3a9819d838c489b2150224a8f1f47932f "$asko_iris_cache/Iris.apk" | sha256sum -c -
ssh -o BatchMode=yes -- "$asko_target" 'umask 077; mkdir -p asko/iris-install'
scp -q "$asko_iris_cache/Iris.apk" tools/iris-start.sh tools/iris-inner.sh tools/iris-install-root.sh "$asko_target:asko/iris-install/"
ssh -o BatchMode=yes -- "$asko_target" "env -u LD_PRELOAD -u LD_LIBRARY_PATH '$asko_su_quoted' -c '/system/bin/sh /data/data/com.termux/files/home/asko/iris-install/iris-install-root.sh'"
