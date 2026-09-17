#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
asko_target=${1:-asko-phone}
if [[ ! "$asko_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then exit 2; fi
asko_backup_dir=${ASKO_BACKUP_DIR:-$asko_repo/.cache/backups}
if [ ! -d "$asko_backup_dir" ]; then mkdir -p -m 700 "$asko_backup_dir"; fi
asko_local=$(mktemp "$asko_backup_dir/asko-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX.sqlite")
asko_name=$(basename -- "$asko_local")
asko_verified=0
trap 'if [ "$asko_verified" -eq 0 ]; then rm -f -- "$asko_local"; fi' EXIT
ssh -o BatchMode=yes -- "$asko_target" "cd asko && ./run-phone.sh backup --output var/$asko_name"
scp -q "$asko_target:asko/var/$asko_name" "$asko_local"
chmod 600 "$asko_local"
asko_remote_hash=$(ssh -o BatchMode=yes -- "$asko_target" "sha256sum asko/var/$asko_name" | cut -d ' ' -f 1)
asko_local_hash=$(sha256sum "$asko_local" | cut -d ' ' -f 1)
test "$asko_remote_hash" = "$asko_local_hash"
asko_verified=1
ssh -o BatchMode=yes -- "$asko_target" "rm -- asko/var/$asko_name"
printf 'Verified backup: %s\n' "$asko_local"
