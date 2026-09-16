#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$asko_repo"
case "$(uname -sm)" in 'Linux x86_64') ;; *) printf '%s\n' 'This bootstrap supports Linux x86_64; ordinary opam workflows can be used elsewhere.' >&2; exit 1;; esac
for asko_command in gcc make curl git tar bzip2 xz unzip patch python3 pkg-config readelf file; do
    command -v "$asko_command" >/dev/null || { printf 'Missing build tool: %s\n' "$asko_command" >&2; exit 1; }
done
mkdir -p .cache/bin
if [ ! -f .cache/bin/opam ]; then
    curl --fail --location --silent --show-error --retry 2 -o .cache/bin/opam \
      https://github.com/ocaml/opam/releases/download/2.5.2/opam-2.5.2-x86_64-linux
fi
python3 - <<'PY'
from pathlib import Path
import hashlib
p=Path('.cache/bin/opam')
if hashlib.sha256(p.read_bytes()).hexdigest()!='edfca2630c373b44b7ee1c2f81cd8dcf67468d0db57d6c02158de553ac63dbd4':
    raise SystemExit('opam checksum mismatch')
p.chmod(0o700)
PY
ASKO_NATIVE_ONLY=1 "$asko_repo/tools/prepare-toolchain.sh"
asko_toolchain=$(cat .cache/toolchain-path)
export PATH="$asko_toolchain/host/bin:$asko_repo/.cache/bin:$PATH"
if ! pkg-config --exists gmp sqlite3 && ! PKG_CONFIG_PATH="$asko_repo/.cache/native-sysroot/usr/lib/x86_64-linux-gnu/pkgconfig" pkg-config --exists gmp sqlite3; then
    command -v apt-get >/dev/null || { printf '%s\n' 'Install native GMP and SQLite development libraries first.' >&2; exit 1; }
    mkdir -p .cache/debs .cache/native-sysroot
    (cd .cache/debs && apt-get download libgmp-dev libsqlite3-dev)
    python3 - <<'PY'
from pathlib import Path
import subprocess
cache=Path('.cache').resolve()
for pattern in ['libgmp-dev_*.deb','libsqlite3-dev_*.deb']:
    for deb in (cache/'debs').glob(pattern):
        subprocess.run(['dpkg-deb','-x',str(deb),str(cache/'native-sysroot')],check=True)
for pc in (cache/'native-sysroot').rglob('*.pc'):
    pc.write_text(pc.read_text().replace('prefix=/usr','prefix='+str(cache/'native-sysroot/usr')))
for link,soname in [('libgmp.so','libgmp.so.10'),('libsqlite3.so','libsqlite3.so.0')]:
    runtime=Path('/usr/lib/x86_64-linux-gnu')/soname
    if not runtime.exists():
        raise SystemExit('Install the native runtime library first: '+soname)
    target=cache/'native-sysroot/usr/lib/x86_64-linux-gnu'/link
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
export OPAMROOT="$asko_repo/.cache/opam"
if [ ! -f "$OPAMROOT/config" ]; then
    asko_sandbox=()
    if [ "${ASKO_DISABLE_OPAM_SANDBOX:-0}" = 1 ]; then asko_sandbox=(--disable-sandboxing); fi
    opam init --bare --no-setup --yes "${asko_sandbox[@]}" default https://opam.ocaml.org
fi
if ! opam switch list --short | grep -qx asko; then
    opam switch create asko ocaml-system.5.4.1 --yes
fi
"$asko_repo/scripts/dev" opam install --deps-only --locked --assume-depexts --yes --jobs="${ASKO_JOBS:-6}" .
"$asko_repo/scripts/dev" dune build @all
