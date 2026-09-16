#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
asko_compiler=${ASKO_OCAMLOPT:-ocamlopt}
mkdir -p "$asko_repo/.cache"
asko_build=$(mktemp -d "$asko_repo/.cache/core-test.XXXXXX")
trap 'rm -rf -- "$asko_build"' EXIT
for asko_module in types trigger intent scope; do
    cp "$asko_repo/lib/$asko_module.ml" "$asko_build/"
done
cp "$asko_repo/test/test_core.ml" "$asko_build/"
cat > "$asko_build/asko.ml" <<'ML'
module Types = Types
module Trigger = Trigger
module Intent = Intent
module Scope = Scope
ML
cd "$asko_build"
"$asko_compiler" -I +unix unix.cmxa types.ml trigger.ml intent.ml scope.ml asko.ml test_core.ml -o test-core
./test-core
