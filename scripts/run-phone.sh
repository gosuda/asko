#!/system/bin/sh
set -eu
umask 077
asko_dir=/data/data/com.termux/files/home/asko
cd "$asko_dir"
export SSL_CERT_FILE="$asko_dir/current/cacert.pem"
export TMPDIR=/data/data/com.termux/files/usr/tmp
unset LD_PRELOAD LD_LIBRARY_PATH
if [ -z "${OPENROUTER_API_KEY:-}" ] && [ -s secrets/openrouter.key ]; then
    OPENROUTER_API_KEY=$(cat secrets/openrouter.key)
    export OPENROUTER_API_KEY
fi
if [ -z "${ASKO_INGEST_TOKEN:-}" ] && [ -s secrets/ingest.token ]; then
    ASKO_INGEST_TOKEN=$(cat secrets/ingest.token)
    export ASKO_INGEST_TOKEN
fi
if [ "$#" = 0 ]; then set -- serve; fi
exec "$asko_dir/current/asko" "$@" --config "$asko_dir/config.local.json"
