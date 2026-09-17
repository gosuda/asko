#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$asko_repo"
"$asko_repo/scripts/dev" env -u C_INCLUDE_PATH -u CPATH -u LIBRARY_PATH -u PKG_CONFIG_PATH \
    dune build -x android _build/default.android/bin/main.exe
mkdir -p dist
install -m 755 _build/default.android/bin/main.exe dist/asko
file dist/asko
readelf -l dist/asko | grep '/system/bin/linker64'
readelf -d dist/asko | grep NEEDED
sha256sum dist/asko
