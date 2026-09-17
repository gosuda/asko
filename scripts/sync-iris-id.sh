#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
asko_target=${1:-asko-phone}
if [[ ! "$asko_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then exit 2; fi
asko_id=$(ssh -o BatchMode=yes -- "$asko_target" 'cd asko && ./run-phone.sh iris-info' |
  python3 -c 'import json,sys; x=str(json.load(sys.stdin).get("bot_id", "")); assert x.isascii() and x.isdigit() and int(x)>0, "Iris has not found the bot ID"; print(x)')
ssh -o BatchMode=yes -- "$asko_target" /system/bin/sh -s -- "$asko_id" <<'REMOTE'
set -eu
umask 077
cd /data/data/com.termux/files/home/asko
test ! -e config.id.next.json
trap 'rm -f config.id.next.json' EXIT
test "$(grep -c '^[[:space:]]*"bot_id"[[:space:]]*:' config.local.json)" = 1
awk -v id="$1" '/^[[:space:]]*"bot_id"[[:space:]]*:/ {$0="  \"bot_id\": \"" id "\","} {print}' config.local.json >config.id.next.json
./current/asko check-config --config config.id.next.json >/dev/null
mv config.id.next.json config.local.json
REMOTE
python3 - "$asko_repo/config.local.json" "$asko_id" <<'PY'
import json, os, pathlib, sys, tempfile
p=pathlib.Path(sys.argv[1])
if p.exists():
    value=json.loads(p.read_text())
    value['bot_id']=sys.argv[2]
    fd,name=tempfile.mkstemp(dir=p.parent,prefix='.asko-config-')
    try:
        with os.fdopen(fd,'w') as output:
            json.dump(value,output,ensure_ascii=False,indent=2)
            output.write('\n')
        os.replace(name,p)
    finally:
        if os.path.exists(name):os.unlink(name)
PY
printf '%s\n' 'Iris bot ID saved to the phone and existing local configuration.'
