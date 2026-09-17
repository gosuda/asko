#!/system/bin/sh
set -eu
umask 077
unset LD_PRELOAD LD_LIBRARY_PATH
asko_iris=/data/local/tmp/asko-iris
cd "$asko_iris"
if [ -f iris.pid ]; then
    asko_pid=$(cat iris.pid)
    case "$asko_pid" in ''|*[!0-9]*) exit 1;; esac
    if [ -r "/proc/$asko_pid/cmdline" ] && tr '\000' ' ' <"/proc/$asko_pid/cmdline" | grep -q 'party.qwer.iris.Main'; then
        printf '%s\n' 'Iris is already running.'
        exit 0
    fi
fi
for asko_filter in /system/bin/iptables /system/bin/ip6tables; do
    "$asko_filter" -w 5 -C INPUT ! -i lo -p tcp --dport 3000 -j REJECT 2>/dev/null ||
        "$asko_filter" -w 5 -I INPUT ! -i lo -p tcp --dport 3000 -j REJECT
done
if [ ! -f config.json ]; then
    printf '%s\n' '{"botName":"Iris","botHttpPort":3000,"webServerEndpoint":"","dbPollingRate":1000,"messageSendRate":1000,"botId":0}' >config.json
fi
mkdir -p private-sdcard
/system/bin/nohup /system/bin/unshare -m /system/bin/sh "$asko_iris/iris-inner.sh" >>iris.log 2>&1 </dev/null &
printf '%s\n' "$!" >iris.pid
printf '%s\n' 'Iris launch requested.'
