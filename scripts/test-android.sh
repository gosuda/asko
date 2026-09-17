#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
asko_target=${1:-asko-phone}
if [[ ! "$asko_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then printf '%s\n' 'Invalid SSH target' >&2; exit 2; fi
cd "$asko_repo"
"$asko_repo/scripts/build-android.sh"
"$asko_repo/scripts/dev" env -u C_INCLUDE_PATH -u CPATH -u LIBRARY_PATH -u PKG_CONFIG_PATH \
    dune build -x android \
    _build/default.android/test/test_core.exe _build/default.android/test/test_store.exe \
    _build/default.android/test/test_http.exe _build/default.android/test/test_summary.exe \
    _build/default.android/test/test_pipeline.exe
if [ ! -f dist/cacert.pem ]; then "$asko_repo/scripts/fetch-ca.sh"; fi
ssh -o BatchMode=yes "$asko_target" 'mkdir -p asko-runtime-test && chmod 700 asko-runtime-test'
scp -q dist/asko dist/cacert.pem _build/default.android/test/test_core.exe \
    _build/default.android/test/test_store.exe _build/default.android/test/test_http.exe \
    _build/default.android/test/test_summary.exe _build/default.android/test/test_pipeline.exe \
    "$asko_target:asko-runtime-test/"
ssh -o BatchMode=yes "$asko_target" /system/bin/sh -s <<'REMOTE'
set -eu
cd /data/data/com.termux/files/home/asko-runtime-test
export TMPDIR=/data/data/com.termux/files/usr/tmp
export SSL_CERT_FILE=/data/data/com.termux/files/home/asko-runtime-test/cacert.pem
unset LD_PRELOAD LD_LIBRARY_PATH
chmod 700 asko test_core.exe test_store.exe test_http.exe test_summary.exe test_pipeline.exe
./asko version
./test_core.exe
./test_store.exe
./test_http.exe
./test_summary.exe
./test_pipeline.exe
./asko probe-https
REMOTE
