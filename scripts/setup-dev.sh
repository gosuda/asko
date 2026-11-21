#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$asko_repo"
case "$(uname -sm)" in 'Linux x86_64') ;; *) printf '%s\n' 'This bootstrap supports Linux x86_64; ordinary opam workflows can be used elsewhere.' >&2; exit 1;; esac
for asko_command in gcc ar flock sha256sum make curl git tar bzip2 xz unzip patch python3 pkg-config readelf file; do
    command -v "$asko_command" >/dev/null || { printf 'Missing build tool: %s\n' "$asko_command" >&2; exit 1; }
done
mkdir -p .cache/bin
asko_opam=$asko_repo/.cache/bin/opam
asko_opam_sha=b533d393a6967150d6ef41cb3d71e147e93ecbabeb59e921aa412c0ae79ebe3d
if ! printf '%s  %s\n' "$asko_opam_sha" "$asko_opam" | sha256sum --check --status 2>/dev/null; then
    asko_opam_tmp=$(mktemp .cache/bin/opam.XXXXXX)
    trap 'rm -f -- "$asko_opam_tmp"' EXIT
    curl --fail --location --silent --show-error --retry 2 -o "$asko_opam_tmp" \
      https://github.com/ocaml/opam/releases/download/2.6.1/opam-2.6.1-x86_64-linux
    printf '%s  %s\n' "$asko_opam_sha" "$asko_opam_tmp" | sha256sum --check --status
    chmod 700 "$asko_opam_tmp"
    mv -f "$asko_opam_tmp" "$asko_opam"
    trap - EXIT
fi
chmod 700 "$asko_opam"
ASKO_NATIVE_ONLY=1 "$asko_repo/tools/prepare-toolchain.sh"
asko_toolchain=$(cat .cache/toolchain-path)
export PATH="$asko_toolchain/host-5.5.2/bin:$asko_repo/.cache/bin:$PATH"
"$asko_repo/scripts/prepare-native-sqlite.sh"
if ! pkg-config --exists gmp && ! PKG_CONFIG_PATH="$asko_repo/.cache/native-sysroot/usr/lib/x86_64-linux-gnu/pkgconfig" pkg-config --exists gmp; then
    command -v apt-get >/dev/null || { printf '%s\n' 'Install the native GMP development library first.' >&2; exit 1; }
    mkdir -p .cache/debs .cache/native-sysroot
    if ! compgen -G '.cache/debs/libgmp-dev_*.deb' >/dev/null; then
        (cd .cache/debs && apt-get download libgmp-dev)
    fi
    for asko_deb in .cache/debs/libgmp-dev_*.deb; do dpkg-deb -x "$asko_deb" .cache/native-sysroot; done
    python3 - <<'PY'
from pathlib import Path
prefix = Path('.cache/native-sysroot/usr').resolve()
libdir = prefix / 'lib/x86_64-linux-gnu'
for pc in (libdir / 'pkgconfig').glob('gmp*.pc'):
    pc.write_text(pc.read_text().replace('=/usr', '=' + str(prefix)))
runtime = Path('/usr/lib/x86_64-linux-gnu/libgmp.so.10')
if not runtime.exists():
    raise SystemExit('Install the native GMP runtime library first: libgmp.so.10')
target = libdir / 'libgmp.so'
target.unlink(missing_ok=True)
target.symlink_to(runtime.resolve())
PY
fi
if ! command -v m4 >/dev/null; then
    command -v apt-get >/dev/null || { printf '%s\n' 'Install GNU m4 first.' >&2; exit 1; }
    mkdir -p .cache/debs .cache/native-tools
    (cd .cache/debs && apt-get download m4)
    for asko_deb in .cache/debs/m4_*.deb; do dpkg-deb -x "$asko_deb" .cache/native-tools; done
    ln -sf ../native-tools/usr/bin/m4 .cache/bin/m4
fi
export OPAMROOT="${ASKO_OPAM_ROOT:-$asko_repo/.cache/opam}"
if [ ! -f "$OPAMROOT/config" ]; then
    asko_sandbox=()
    if [ "${ASKO_DISABLE_OPAM_SANDBOX:-0}" = 1 ]; then asko_sandbox=(--disable-sandboxing); fi
    "$asko_opam" init --bare --no-setup --yes "${asko_sandbox[@]}" default https://opam.ocaml.org
else
    "$asko_opam" update default
fi
if ! "$asko_opam" switch list --short | grep -qx asko-5.5.2; then
    "$asko_opam" switch create asko-5.5.2 ocaml-system.5.5.2 --yes
fi
"$asko_repo/scripts/add-opam-repository.sh" asko-local "file://$asko_repo/opam" 1
asko_dev=$asko_repo/scripts/dev
asko_opam_args=(--assume-depexts --yes --jobs="${ASKO_JOBS:-6}")
"$asko_dev" "$asko_opam" install --deps-only --locked "${asko_opam_args[@]}" .

# The binding records pkg-config's link flags at install time. Changing search
# paths alone cannot repair an installed .cmxa or its bytecode stub.
asko_binding_is_private() {
    local flags dynamic archive=$asko_repo/.cache/native-sqlite-3.54.1/lib/libsqlite3.a
    flags=$(ocamlobjinfo "$asko_lib/sqlite3/sqlite3.cmxa" | sed -n 's/^Extra C object files: //p') || return 1
    [[ " $flags " == *" $archive "* && " $flags " != *' -lsqlite3 '* ]] || return 1
    dynamic=$(LC_ALL=C readelf -dW "$asko_lib/stublibs/dllsqlite3_stubs.so" "$asko_lib/sqlite3/sqlite3.cmxs") || return 1
    [[ $dynamic != *libsqlite3.so* ]]
}
asko_lib=$("$asko_opam" var --switch=asko-5.5.2 lib)
if ! asko_binding_is_private; then
    "$asko_dev" "$asko_opam" reinstall "${asko_opam_args[@]}" sqlite3
    asko_binding_is_private || { printf '%s\n' 'SQLite binding still references the wrong engine after reinstall.' >&2; exit 1; }
fi
"$asko_dev" dune build @all
