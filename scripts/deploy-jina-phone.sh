#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$asko_repo"
asko_target=${1:-asko-phone}
if [[ ! "$asko_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then exit 2; fi
./scripts/build-jina-android.sh
ssh -o BatchMode=yes -- "$asko_target" 'umask 077; cd asko; test ! -f var/supervisor.pid; mkdir -p embedding'
scp -q .cache/jina/build-android/bin/llama-server "$asko_target:asko/embedding/llama-server.next"
asko_hash=$(sha256sum .cache/jina/build-android/bin/llama-server | cut -d ' ' -f 1)
test "$(ssh -o BatchMode=yes -- "$asko_target" 'sha256sum asko/embedding/llama-server.next' | cut -d ' ' -f 1)" = "$asko_hash"
asko_model_hash=86b6e6279e9b9e71389f02a082764a2ac2b15a50e37482c26f98d69092f12442
if ! ssh -o BatchMode=yes -- "$asko_target" "test -f asko/embedding/jina-q8.gguf && echo '$asko_model_hash  asko/embedding/jina-q8.gguf' | sha256sum -c -"; then
    scp -q .cache/jina/model.gguf "$asko_target:asko/embedding/jina-q8.gguf.next"
    ssh -o BatchMode=yes -- "$asko_target" "echo '$asko_model_hash  asko/embedding/jina-q8.gguf.next' | sha256sum -c - && mv asko/embedding/jina-q8.gguf.next asko/embedding/jina-q8.gguf"
fi
scp -q scripts/run-embedding-phone.sh "$asko_target:asko/run-embedding-phone.sh.next"
ssh -o BatchMode=yes -- "$asko_target" 'cd asko && chmod 700 embedding/llama-server.next run-embedding-phone.sh.next && mv embedding/llama-server.next embedding/llama-server && mv run-embedding-phone.sh.next run-embedding-phone.sh'
