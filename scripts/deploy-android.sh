#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
asko_target=${1:-asko-phone}
if [[ ! "$asko_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then
    printf '%s\n' 'Use a configured SSH host alias.' >&2; exit 2
fi
cd "$asko_repo"
"$asko_repo/scripts/build-android.sh"
test -f dist/cacert.pem || "$asko_repo/scripts/fetch-ca.sh"
mkdir -p .cache
asko_stage=$(mktemp -d "$asko_repo/.cache/deploy.XXXXXX")
trap 'rm -f -- "$asko_stage/SHA256SUMS" "$asko_stage/ingest.token"; rmdir -- "$asko_stage"' EXIT
python3 - "$asko_stage/SHA256SUMS" <<'PY'
import hashlib, pathlib, sys
paths = ['dist/asko', 'dist/cacert.pem', 'config.example.json',
         'scripts/run-phone.sh', 'scripts/supervise-phone.sh']
pathlib.Path(sys.argv[1]).write_text(''.join(
    hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() + '  ' + pathlib.Path(p).name + '\n'
    for p in paths))
PY
asko_release=$(sha256sum "$asko_stage/SHA256SUMS" | cut -c 1-16)
asko_pending=".pending-$asko_release-${asko_stage##*.}"
ssh -o BatchMode=yes -- "$asko_target" "umask 077; mkdir -p asko/releases asko/secrets asko/var; chmod 700 asko asko/secrets asko/var; mkdir asko/releases/$asko_pending"
scp -q dist/asko dist/cacert.pem config.example.json scripts/run-phone.sh scripts/supervise-phone.sh "$asko_stage/SHA256SUMS" "$asko_target:asko/releases/$asko_pending/"
if ! ssh -o BatchMode=yes -- "$asko_target" 'test -s asko/secrets/ingest.token'; then
    python3 - "$asko_stage/ingest.token" <<'PY'
import pathlib, secrets, sys
p=pathlib.Path(sys.argv[1])
p.write_text(secrets.token_hex(32)+'\n')
p.chmod(0o600)
PY
    scp -q "$asko_stage/ingest.token" "$asko_target:asko/secrets/ingest.token"
fi
ssh -o BatchMode=yes -- "$asko_target" /system/bin/sh -s -- "$asko_release" "$asko_pending" <<'REMOTE'
set -eu
umask 077
asko_release=$1
asko_pending=$2
cd /data/data/com.termux/files/home/asko
exec 9>var/deploy.lock
/system/bin/flock -n 9 9>&9
test "$(sha256sum "releases/$asko_pending/SHA256SUMS" | cut -c 1-16)" = "$asko_release"
(cd "releases/$asko_pending" && sha256sum -c SHA256SUMS)
if [ -e current ] && [ ! -L current ]; then printf '%s\n' 'current must be a release symlink' >&2; exit 1; fi
if [ -e current.next ] && [ ! -L current.next ]; then printf '%s\n' 'current.next must be a release symlink' >&2; exit 1; fi
asko_config="$PWD/config.local.json"
if [ ! -f "$asko_config" ]; then
    if [ -e "$asko_config" ] || [ -L "$asko_config" ]; then
        printf '%s\n' 'config.local.json must be a configuration file.' >&2; exit 1
    fi
    asko_config="$PWD/releases/$asko_pending/config.example.json"
fi
chmod 700 "releases/$asko_pending/asko"
# Check the candidate before changing the active release, launchers or config.
# Keep secret loading identical to run-phone.sh, including legacy empty-key fallback.
(
    export SSL_CERT_FILE="$PWD/releases/$asko_pending/cacert.pem"
    export TMPDIR=/data/data/com.termux/files/usr/tmp
    unset LD_PRELOAD LD_LIBRARY_PATH
    if [ -z "${OPENROUTER_API_KEY:-}" ] && [ -s secrets/openrouter.key ]; then
        OPENROUTER_API_KEY=$(cat secrets/openrouter.key)
        export OPENROUTER_API_KEY
    fi
    if [ "${OPENCODE_GO_API_KEY+x}" != x ] && [ -s secrets/opencode-go.key ]; then
        OPENCODE_GO_API_KEY=$(cat secrets/opencode-go.key)
        export OPENCODE_GO_API_KEY
    fi
    if [ "${ASKO_EMBEDDING_API_KEY+x}" != x ] && [ -s secrets/embedding.key ]; then
        ASKO_EMBEDDING_API_KEY=$(cat secrets/embedding.key)
        export ASKO_EMBEDDING_API_KEY
    fi
    if [ -z "${ASKO_INGEST_TOKEN:-}" ] && [ -s secrets/ingest.token ]; then
        ASKO_INGEST_TOKEN=$(cat secrets/ingest.token)
        export ASKO_INGEST_TOKEN
    fi
    "./releases/$asko_pending/asko" check-config --config "$asko_config"
    "./releases/$asko_pending/asko" version --config "$asko_config"
)
if [ -e "releases/$asko_release" ]; then
    test ! -L "releases/$asko_release"
    cmp "releases/$asko_pending/SHA256SUMS" "releases/$asko_release/SHA256SUMS"
    (cd "releases/$asko_release" && sha256sum -c SHA256SUMS)
    rm -- "releases/$asko_pending/asko" "releases/$asko_pending/cacert.pem" \
        "releases/$asko_pending/config.example.json" "releases/$asko_pending/run-phone.sh" \
        "releases/$asko_pending/supervise-phone.sh" "releases/$asko_pending/SHA256SUMS"
    rmdir "releases/$asko_pending"
else
    chmod 700 "releases/$asko_pending/asko" "releases/$asko_pending/run-phone.sh" "releases/$asko_pending/supervise-phone.sh"
    mv "releases/$asko_pending" "releases/$asko_release"
fi
for asko_script in run-phone.sh supervise-phone.sh; do
    cp "releases/$asko_release/$asko_script" "$asko_script.next"
    chmod 700 "$asko_script.next"
    mv -f "$asko_script.next" "$asko_script"
done
chmod 600 secrets/ingest.token
if [ ! -f config.local.json ]; then cp "releases/$asko_release/config.example.json" config.local.json; fi
chmod 600 config.local.json
if [ -L current ] && [ "$(readlink current)" != "releases/$asko_release" ]; then readlink current > previous-release; fi
if [ -L current.next ]; then rm current.next; fi
ln -s "releases/$asko_release" current.next
mv -Tf current.next current
REMOTE
printf 'Deployed verified release %s. Existing configuration and database preserved; process not restarted.\n' "$asko_release"
