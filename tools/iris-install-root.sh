#!/system/bin/sh
set -eu
umask 077
unset LD_PRELOAD LD_LIBRARY_PATH
asko_stage=/data/data/com.termux/files/home/asko/iris-install
asko_iris=/data/local/tmp/asko-iris
test "$(id -u)" = 0
cd "$asko_stage"
printf '%s  %s\n' c4f61523ac41353f97c3547e12f32bf3a9819d838c489b2150224a8f1f47932f Iris.apk | sha256sum -c -
mkdir -p "$asko_iris"
chmod 700 "$asko_iris"
asko_upgrade=
if [ -f "$asko_iris/Iris.apk" ] && ! cmp -s Iris.apk "$asko_iris/Iris.apk"; then
    asko_upgrade=1
fi
cp Iris.apk "$asko_iris/Iris.apk.next"
mv "$asko_iris/Iris.apk.next" "$asko_iris/Iris.apk"
cp iris-start.sh iris-inner.sh "$asko_iris/"
chmod 700 "$asko_iris/iris-start.sh" "$asko_iris/iris-inner.sh"
# A running Iris keeps the replaced APK open; restart it so the new version loads.
if [ -n "$asko_upgrade" ] && [ -f "$asko_iris/iris.pid" ]; then
    asko_pid=$(cat "$asko_iris/iris.pid" 2>/dev/null || :)
    case "$asko_pid" in
        ''|*[!0-9]*) ;;
        *) if [ -r "/proc/$asko_pid/cmdline" ] && tr '\000' ' ' <"/proc/$asko_pid/cmdline" | grep -q 'party.qwer.iris.Main'; then
               kill "$asko_pid"
               asko_wait=0
               while [ -d "/proc/$asko_pid" ] && [ "$asko_wait" -lt 30 ]; do
                   /system/bin/sleep 1
                   asko_wait=$((asko_wait + 1))
               done
               if [ -d "/proc/$asko_pid" ]; then
                   printf '%s\n' 'The previous Iris did not stop; the new APK was not started.' >&2
                   exit 1
               fi
               printf '%s\n' 'Stopped the previous Iris to load the new APK.'
           fi;;
    esac
fi
/system/bin/sh "$asko_iris/iris-start.sh"
