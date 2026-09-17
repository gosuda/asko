#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$asko_repo"
asko_target=${1:-asko-phone}
if [[ ! "$asko_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then exit 2; fi
mkdir -p .cache/iris
if [ ! -f .cache/iris/Iris.apk ]; then
    curl -fLsS --retry 2 -o .cache/iris/Iris.apk.part https://github.com/dolidolih/Iris/releases/download/v0.32/Iris.apk
    mv .cache/iris/Iris.apk.part .cache/iris/Iris.apk
fi
printf '%s  %s\n' 00eaa7800f904b7e3082277525adbbc0581ffe9efdb1c7a475561361f918eab0 .cache/iris/Iris.apk | sha256sum -c -
asko_hash=$(python3 tools/prepare-iris.py)
printf '%s  %s\n' "$asko_hash" Iris-asko.apk >.cache/iris/Iris-asko.sha256
ssh -o BatchMode=yes -- "$asko_target" 'umask 077; mkdir -p asko/iris-install'
scp -q .cache/iris/Iris-asko.apk .cache/iris/Iris-asko.sha256 tools/iris-start.sh tools/iris-install-root.sh "$asko_target:asko/iris-install/"
ssh -o BatchMode=yes -- "$asko_target" "env -u LD_PRELOAD -u LD_LIBRARY_PATH /product/bin/su -c '/system/bin/sh /data/data/com.termux/files/home/asko/iris-install/iris-install-root.sh'"
