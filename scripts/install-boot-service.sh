#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
asko_target=${1:-asko-phone}
if [[ ! "$asko_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then exit 2; fi
asko_uid=$(ssh -o BatchMode=yes -- "$asko_target" id -u)
if [[ ! "$asko_uid" =~ ^[0-9]+$ ]] || [ "$asko_uid" -lt 10000 ]; then
    printf '%s\n' 'SSH must use the Termux app account, not root.' >&2; exit 1
fi
mkdir -p "$asko_repo/.cache"
asko_boot=$(mktemp "$asko_repo/.cache/asko-boot.XXXXXX")
trap 'rm -f -- "$asko_boot"' EXIT
sed "s/@UID@/$asko_uid/g" "$asko_repo/tools/magisk-asko.sh.in" >"$asko_boot"
scp -q "$asko_boot" "$asko_target:asko/boot-service.pending.sh"
ssh -o BatchMode=yes -- "$asko_target" "/product/bin/su -c '/system/bin/sh -n /data/data/com.termux/files/home/asko/boot-service.pending.sh && if [ -e /data/adb/service.d/asko-backend.sh ]; then cmp /data/data/com.termux/files/home/asko/boot-service.pending.sh /data/adb/service.d/asko-backend.sh; else cp /data/data/com.termux/files/home/asko/boot-service.pending.sh /data/adb/service.d/asko-backend.sh && chmod 700 /data/adb/service.d/asko-backend.sh; fi'"
printf '%s\n' 'Installed backend boot entrypoint. Use control-phone.sh start to start it now.'
