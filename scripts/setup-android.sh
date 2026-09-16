#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$asko_repo"
"$asko_repo/scripts/setup-dev.sh"
"$asko_repo/tools/prepare-toolchain.sh"
asko_toolchain=$(cat .cache/toolchain-path)
export PATH="$asko_toolchain/host/bin:$asko_repo/.cache/bin:$PATH"
export OPAMROOT="$asko_repo/.cache/opam"
export ANDROID_NDK_ROOT="$asko_toolchain/android-ndk-r29"
export ANDROID_API=26
if ! opam repository list --short | grep -qx android; then
    opam repository add --switch asko --yes android "$asko_toolchain/opam-cross-android"
fi
if ! opam repository list --short | grep -qx asko-local; then
    opam repository add --switch asko --yes asko-local "$asko_repo/opam"
fi
opam update asko-local
opam install --switch asko --yes --assume-depexts --jobs="${ASKO_JOBS:-6}" \
    ocaml-android.5.4.1 yojson-android.3.0.0 cohttp-lwt-unix-android.6.2.1 \
    tls-lwt-android.2.1.0 build-gmp-android.6.3.0 sqlite3-android.5.4.2
"$asko_repo/scripts/build-android.sh"
