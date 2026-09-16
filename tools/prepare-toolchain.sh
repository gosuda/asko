#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
asko_root=${ASKO_TOOLCHAIN_DIR:-$asko_repo/.cache/toolchain}
if [ -f "$asko_repo/.cache/toolchain-path" ] && [ -z "${ASKO_TOOLCHAIN_DIR:-}" ]; then
    asko_root=$(cat "$asko_repo/.cache/toolchain-path")
fi
mkdir -p "$asko_repo/.cache" "$asko_root"
printf '%s\n' "$asko_root" > "$asko_repo/.cache/toolchain-path"
asko_recipe_commit=91d9d8041a90b11c7a4bf77423cfe018c0f295dc

if [ ! -d "$asko_root/opam-cross-android/.git" ]; then
    git init "$asko_root/opam-cross-android"
    git -C "$asko_root/opam-cross-android" remote add origin https://github.com/ocaml-cross/opam-cross-android.git
    git -C "$asko_root/opam-cross-android" fetch --depth 1 origin "$asko_recipe_commit"
    git -C "$asko_root/opam-cross-android" checkout --detach FETCH_HEAD
fi
[ "$(git -C "$asko_root/opam-cross-android" rev-parse HEAD)" = "$asko_recipe_commit" ]

if [ "${ASKO_NATIVE_ONLY:-0}" != 1 ]; then
if [ ! -f "$asko_root/android-ndk-r29-linux.zip" ]; then
    curl --fail --location --retry 2 -o "$asko_root/android-ndk-r29-linux.zip.part" https://dl.google.com/android/repository/android-ndk-r29-linux.zip
    mv "$asko_root/android-ndk-r29-linux.zip.part" "$asko_root/android-ndk-r29-linux.zip"
fi
printf '%s  %s\n' 87e2bb7e9be5d6a1c6cdf5ec40dd4e0c6d07c30b "$asko_root/android-ndk-r29-linux.zip" | sha1sum --check --status
if [ ! -d "$asko_root/android-ndk-r29" ]; then
    unzip -q "$asko_root/android-ndk-r29-linux.zip" -d "$asko_root"
fi

fi

if [ ! -f "$asko_root/ocaml-5.4.1.tar.gz" ]; then
    curl --fail --location --retry 2 -o "$asko_root/ocaml-5.4.1.tar.gz.part" https://github.com/ocaml/ocaml/releases/download/5.4.1/ocaml-5.4.1.tar.gz
    mv "$asko_root/ocaml-5.4.1.tar.gz.part" "$asko_root/ocaml-5.4.1.tar.gz"
fi
printf '%s  %s\n' d4528517aaa1a44b8e2b1bc109a1ed0a5e0014f3ddc4feb8906b11a7e063e89a "$asko_root/ocaml-5.4.1.tar.gz" | sha256sum --check --status
for asko_src in host-src android-src; do
    mkdir -p "$asko_root/$asko_src"
    if [ ! -f "$asko_root/$asko_src/configure" ]; then
        tar -xzf "$asko_root/ocaml-5.4.1.tar.gz" -C "$asko_root/$asko_src" --strip-components=1
    fi
done
if [ ! -x "$asko_root/host/bin/ocamlopt" ]; then
    cd "$asko_root/host-src"
    ./configure --prefix="$asko_root/host" --without-zstd --disable-warn-error
    make -j8 world.opt
    make install
fi
[ "$("$asko_root/host/bin/ocamlopt" -version)" = 5.4.1 ]
