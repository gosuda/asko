#!/system/bin/sh
set -eu
cd /data/data/com.termux/files/home/asko
unset LD_PRELOAD LD_LIBRARY_PATH
exec ./embedding/llama-server --model ./embedding/jina-q8.gguf \
  --alias jina-v5-nano-retrieval-q8 --embedding --pooling last \
  --host 127.0.0.1 --port 8081 --ctx-size 4096 --batch-size 4096 \
  --ubatch-size 4096 --threads 2 --parallel 1 --no-warmup --no-webui
