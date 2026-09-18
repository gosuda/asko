#!/system/bin/sh
set -eu
umask 077
unset LD_PRELOAD LD_LIBRARY_PATH
asko_iris=/data/local/tmp/asko-iris
cd "$asko_iris"
asko_running_pid=
asko_bad_pid=
if [ -f iris.pid ]; then
    asko_pid=$(cat iris.pid 2>/dev/null) || asko_bad_pid=1
    case "$asko_pid" in
        ''|*[!0-9]*) asko_bad_pid=1;;
        *) if [ -r "/proc/$asko_pid/cmdline" ] && tr '\000' ' ' <"/proc/$asko_pid/cmdline" | grep -q 'party.qwer.iris.Main'; then
               asko_running_pid=$asko_pid
           fi;;
    esac
fi
asko_fail() {
    printf '%s\n' "$1" >&2
    if [ -n "$asko_running_pid" ]; then
        kill "$asko_running_pid" || true
        printf '%s\n' 'Stopped Iris because its API could not be protected.' >&2
    fi
    exit 1
}
asko_uid=$(/system/bin/stat -c %u /data/data/com.termux) || asko_fail 'Cannot determine the Termux UID.'
case "$asko_uid" in ''|*[!0-9]*) asko_fail 'Invalid Termux UID.';; esac
[ "$asko_uid" -ge 10000 ] || asko_fail 'Termux must run as an Android app UID.'
for asko_filter in /system/bin/iptables /system/bin/ip6tables; do
    asko_first=$("$asko_filter" -w 5 -S INPUT | sed -n '2p') || asko_fail 'Cannot inspect the Iris firewall.'
    asko_expected='-A INPUT ! -i lo -p tcp -m tcp --dport 3000 -j REJECT'
    case "$asko_first" in
        "$asko_expected"|"$asko_expected --reject-with "*) ;;
        *) "$asko_filter" -w 5 -I INPUT 1 ! -i lo -p tcp --dport 3000 -j REJECT ||
               asko_fail 'Cannot block external access to Iris.';;
    esac
    asko_first=$("$asko_filter" -w 5 -S OUTPUT | sed -n '2p') || asko_fail 'Cannot inspect the Iris firewall.'
    asko_expected="-A OUTPUT -o lo -p tcp -m tcp --dport 3000 -m owner ! --uid-owner $asko_uid -j REJECT"
    case "$asko_first" in
        "$asko_expected"|"$asko_expected --reject-with "*) ;;
        *) "$asko_filter" -w 5 -I OUTPUT 1 -o lo -p tcp --dport 3000 -m owner ! --uid-owner "$asko_uid" -j REJECT ||
               asko_fail 'Cannot block other apps from the Iris API.';;
    esac
done
if [ ! -f config.json ]; then
    printf '%s\n' '{"botName":"Iris","botHttpPort":3000,"webServerEndpoint":"","dbPollingRate":1000,"messageSendRate":1000,"botId":0}' >config.json
fi
asko_port=$(sed -n 's/.*"botHttpPort"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' config.json)
[ "$asko_port" = 3000 ] || asko_fail 'Iris must use the protected port 3000.'
[ -z "$asko_bad_pid" ] || asko_fail 'Invalid Iris PID file.'
if [ -n "$asko_running_pid" ]; then
    printf '%s\n' 'Iris is already running with API firewall rules installed.'
    exit 0
fi
mkdir -p private-sdcard
/system/bin/nohup /system/bin/unshare -m /system/bin/sh "$asko_iris/iris-inner.sh" >>iris.log 2>&1 </dev/null &
printf '%s\n' "$!" >iris.pid
printf '%s\n' 'Iris launch requested.'
