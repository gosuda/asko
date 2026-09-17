#!/system/bin/sh
set -eu
umask 077
asko_iris=/data/local/tmp/asko-iris
# Keep upstream's image cleanup inside Iris's private mount namespace.
/system/bin/mount -o rprivate none /
/system/bin/mount --bind "$asko_iris/private-sdcard" /sdcard
printf '%s\n' "$$" >"$asko_iris/iris.pid"
export IRIS_CONFIG_PATH="$asko_iris/config.json"
export CLASSPATH="$asko_iris/Iris.apk"
exec /system/bin/app_process / party.qwer.iris.Main
