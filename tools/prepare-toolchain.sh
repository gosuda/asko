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
if [ ! -f "$asko_root/android-ndk-r30-linux.zip" ]; then
    curl --fail --location --retry 2 -o "$asko_root/android-ndk-r30-linux.zip.part" https://dl.google.com/android/repository/android-ndk-r30-linux.zip
    mv "$asko_root/android-ndk-r30-linux.zip.part" "$asko_root/android-ndk-r30-linux.zip"
fi
printf '%s  %s\n' 5107f898313790e449e87eee2183d9a20602dee9 "$asko_root/android-ndk-r30-linux.zip" | sha1sum --check --status
if [ ! -d "$asko_root/android-ndk-r30" ]; then
    unzip -q "$asko_root/android-ndk-r30-linux.zip" -d "$asko_root"
fi

fi

if [ ! -f "$asko_root/ocaml-5.5.2.tar.gz" ]; then
    curl --fail --location --retry 2 -o "$asko_root/ocaml-5.5.2.tar.gz.part" https://github.com/ocaml/ocaml/releases/download/5.5.2/ocaml-5.5.2.tar.gz
    mv "$asko_root/ocaml-5.5.2.tar.gz.part" "$asko_root/ocaml-5.5.2.tar.gz"
fi
printf '%s  %s\n' bb3ffef5e4fce4f04915b9f254f570663311e1f227fd669aa87a5ef7de9a1523 "$asko_root/ocaml-5.5.2.tar.gz" | sha256sum --check --status
for asko_src in host-src-5.5.2; do
    mkdir -p "$asko_root/$asko_src"
    if [ ! -f "$asko_root/$asko_src/configure" ]; then
        tar -xzf "$asko_root/ocaml-5.5.2.tar.gz" -C "$asko_root/$asko_src" --strip-components=1
    fi
done
if [ ! -x "$asko_root/host-5.5.2/bin/ocamlopt" ]; then
    cd "$asko_root/host-src-5.5.2"
    ./configure --prefix="$asko_root/host-5.5.2" --without-zstd --disable-warn-error
    make -j"${ASKO_JOBS:-6}" world.opt
    make install
fi
[ "$("$asko_root/host-5.5.2/bin/ocamlopt" -version)" = 5.5.2 ]
