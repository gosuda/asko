#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$asko_repo"
"$asko_repo/scripts/setup-dev.sh"
"$asko_repo/tools/prepare-toolchain.sh"
asko_toolchain=$(cat .cache/toolchain-path)
export PATH="$asko_toolchain/host-5.5.2/bin:$asko_repo/.cache/bin:$PATH"
export OPAMROOT="${ASKO_OPAM_ROOT:-$asko_repo/.cache/opam}"
export ANDROID_NDK_ROOT="$asko_toolchain/android-ndk-r30"
export ANDROID_API=26

"$asko_repo/scripts/add-opam-repository.sh" asko-android "$(cat .cache/android-repo-url)" 2

"$asko_repo/.cache/bin/opam" install --switch asko-5.5.2 --yes --assume-depexts --jobs="${ASKO_JOBS:-6}" \
    opam-file-format.2.2.0 ocaml-android.5.5.2 yojson-android.3.0.0 \
    cohttp-lwt-unix-android.6.3.0 lwt-android.6.1.3 tls-lwt-android.2.1.5 \
    build-gmp-android.6.3.0 sqlite3-android.5.4.2 \
    build-sqlite3-android.3.54.1 mirage-crypto-android.2.4.1 \
    mirage-crypto-ec-android.2.4.1 mirage-crypto-pk-android.2.4.1 \
    mirage-crypto-rng-android.2.4.1 x509-android.1.2.0 \
    digestif-android.1.4.2 kdf-android.1.1.2 \
    dune-configurator-android.3.25.0 ppxlib-android.0.39.0 \
    ocaml_intrinsics_kernel-android.v0.17.3 \
    asn1-combinators-android.0.3.3 re-android.1.14.0
"$asko_repo/scripts/build-android.sh"
