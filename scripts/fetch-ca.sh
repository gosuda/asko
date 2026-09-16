#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$asko_repo/dist"
curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 120 \
    -o "$asko_repo/dist/cacert.pem.part" https://curl.se/ca/cacert.pem
curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 60 \
    -o "$asko_repo/dist/cacert.pem.sha256.part" https://curl.se/ca/cacert.pem.sha256
python3 - "$asko_repo/dist" <<'PY'
import hashlib, pathlib, sys
folder = pathlib.Path(sys.argv[1])
expected = (folder / 'cacert.pem.sha256.part').read_text().split()[0]
if hashlib.sha256((folder / 'cacert.pem.part').read_bytes()).hexdigest() != expected:
    raise SystemExit('CA bundle checksum mismatch')
(folder / 'cacert.pem.part').replace(folder / 'cacert.pem')
(folder / 'cacert.pem.sha256.part').replace(folder / 'cacert.pem.sha256')
print('Verified Mozilla CA bundle:', expected)
PY
