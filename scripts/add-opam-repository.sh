#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
name=$1
url=$2
rank=$3
# Repository names are global to the opam root. Distinguish different checkouts.
digest=$(printf '%s' "$url" | sha256sum)
exec "$asko_repo/.cache/bin/opam" repository add --switch=asko-5.5.2 --yes \
    --rank="$rank" "$name-${digest:0:12}" "$url"
