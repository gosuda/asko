#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
asko_root=${ASKO_TOOLCHAIN_DIR:-$asko_repo/.cache/toolchain}
if [ -f "$asko_repo/.cache/toolchain-path" ] && [ -z "${ASKO_TOOLCHAIN_DIR:-}" ]; then
    asko_root=$(cat "$asko_repo/.cache/toolchain-path")
fi
mkdir -p "$asko_repo/.cache" "$asko_root"
asko_root=$(cd -- "$asko_root" && pwd)
printf '%s\n' "$asko_root" > "$asko_repo/.cache/toolchain-path"

if [ "${ASKO_NATIVE_ONLY:-0}" != 1 ]; then
    asko_recipe_commit=386b2b24b105188cb7b1ec7e82ef357a999626e2
    asko_recipes="$asko_root/opam-cross-android-$asko_recipe_commit"
    if [[ ! -e "$asko_recipes" ]]; then
        (
            asko_tmp=$(mktemp -d "$asko_root/.opam-cross-android.XXXXXXXX")
            trap 'rm -rf -- "$asko_tmp"' EXIT
            asko_source=https://github.com/ocaml-cross/opam-cross-android.git
            asko_legacy="$asko_root/opam-cross-android"
            if [[ -e "$asko_legacy/.git" ]] && git -C "$asko_legacy" cat-file -e "$asko_recipe_commit^{commit}" 2>/dev/null; then
                asko_source=$asko_legacy
            fi
            git -C "$asko_tmp" init -q
            git -C "$asko_tmp" fetch --depth 1 "$asko_source" "$asko_recipe_commit"
            git -C "$asko_tmp" checkout -q --detach "$asko_recipe_commit"
            # Another worktree may have finished fetching the same snapshot.
            mv -Tn -- "$asko_tmp" "$asko_recipes" || [[ -d "$asko_recipes" ]]
        )
    fi
    if [[ ! -e "$asko_recipes/.git" ]] || ! git -C "$asko_recipes" cat-file -e "$asko_recipe_commit^{commit}"; then
        printf 'Missing cross snapshot %s in %s\n' "$asko_recipe_commit" "$asko_recipes" >&2
        exit 1
    fi
    printf 'git+file://%s#%s\n' "$asko_recipes" "$asko_recipe_commit" > "$asko_repo/.cache/android-repo-url"

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
