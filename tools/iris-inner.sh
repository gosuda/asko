#!/system/bin/sh
set -eu
umask 077
asko_iris=/data/local/tmp/asko-iris
# Keep upstream's image cleanup inside Iris's private mount namespace.
/system/bin/mount -o rprivate none /
/system/bin/mount --bind "$asko_iris/private-sdcard" /sdcard
printf '%s\n' "$$" >"$asko_iris/iris.pid"
export IRIS_CONFIG_PATH="$asko_iris/config.json"
# Iris v0.33 copies KakaoTalk databases and extracts native libraries here.
export IRIS_WORK_DIR="$asko_iris/work"
# gosuda Iris build: rotating daemon log (iris.log plus backups, 500 MiB total) and query traces.
export IRIS_LOG_PATH="$asko_iris/iris.log"
export IRIS_LOG_MAX_BYTES=524288000
export IRIS_QUERY_LOG_PATH="$asko_iris/query.jsonl"
export CLASSPATH="$asko_iris/Iris.apk"
exec /system/bin/app_process / party.qwer.iris.Main
