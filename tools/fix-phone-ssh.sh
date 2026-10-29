#!/system/bin/sh
set -eu
unset LD_PRELOAD LD_LIBRARY_PATH
asko_fail() {
    printf '%s\n' "$1" >&2
    exit 1
}
asko_home=/data/data/com.termux/files/home
asko_uid=$(/system/bin/stat -c %u /data/data/com.termux) || asko_fail 'Cannot determine the Termux UID.'
case "$asko_uid" in ''|*[!0-9]*) asko_fail 'Invalid Termux UID.';; esac
[ "$asko_uid" -ge 10000 ] || asko_fail 'Termux must run as an Android app UID.'
asko_su=$(command -v su 2>/dev/null || :)
if [ ! -f "$asko_su" ] || [ ! -x "$asko_su" ]; then
    asko_su=
    for asko_candidate in /product/bin/su /system/bin/su /system/xbin/su /sbin/su /su/bin/su /debug_ramdisk/su; do
        if [ -f "$asko_candidate" ] && [ -x "$asko_candidate" ]; then
            asko_su=$asko_candidate
            break
        fi
    done
fi
[ -n "$asko_su" ] || asko_fail 'Cannot find an executable su.'
# The path will also be embedded as a command in the supervisor.
case "$asko_su" in /*) ;; *) asko_fail 'su must have an absolute path.';; esac
case "$asko_su" in *[!A-Za-z0-9_./-]*) asko_fail 'Unsupported su path.';; esac
if [ "$(/system/bin/id -u)" != 0 ]; then
    case "$0" in
        /*) asko_self=$0;;
        *) asko_self="$(pwd -P)/$0";;
    esac
    asko_self=$(/system/bin/readlink -f "$asko_self") || asko_fail 'Cannot resolve this maintenance script.'
    [ -f "$asko_self" ] && [ -r "$asko_self" ] || asko_fail 'Cannot read this maintenance script.'
    case "$asko_self" in /*) ;; *) asko_fail 'The maintenance script path must be absolute.';; esac
    asko_self_quoted=$(printf '%s' "$asko_self" | sed "s/'/'\\\\''/g")
    exec "$asko_su" -c "/system/bin/sh '$asko_self_quoted'"
fi
umask 077
asko_dir=/data/adb/asko-ssh
asko_script=$asko_dir/supervise.sh
asko_caps=$(awk '/^CapEff:/ {print $2}' /proc/self/status)
if [ "$asko_caps" = 0000000000000000 ]; then
    printf '%s\n' 'Open the Termux app on the phone and rerun this maintenance script.' >&2
    exit 1
fi
# Accept exactly one direct invocation, optionally prefixed with exec. Do not
# mistake comments, UID prefixes, or a different su command for this migration.
asko_match=$(awk -v uid="$asko_uid" -v su="$asko_su" '
    function starts_with(command, prefix, next_char) {
        next_char = substr(command, length(prefix) + 1, 1)
        return index(command, prefix) == 1 && (next_char == "" || next_char ~ /[ \t]/)
    }
    {
        command = $0
        sub(/^[ \t]*/, "", command)
        sub(/^exec[ \t]+/, "", command)
        split(command, args, /[ \t]+/)
        if (args[1] !~ /(^|\/)su$/) next
        count++
        if (args[1] != "/product/bin/su" && args[1] != su) {
            invalid = 1
            next
        }
        legacy = args[1] " -d -g " uid
        fixed = args[1] " -g " uid
        if (starts_with(command, legacy)) prefix = legacy
        else if (starts_with(command, fixed)) prefix = fixed
        else {
            invalid = 1
            next
        }
        result = NR ":" prefix
    }
    END {
        if (invalid || count != 1) exit 1
        print result
    }
' "$asko_script") || asko_fail 'Refusing to modify an unrecognized SSH supervisor.'
/system/bin/sh -n "$asko_script"
asko_line=${asko_match%%:*}
asko_old=${asko_match#*:}
asko_fixed="$asko_su -g $asko_uid"
if [ "$asko_old" != "$asko_fixed" ]; then
    test -f "$asko_script.before-capability-fix" || cp -p "$asko_script" "$asko_script.before-capability-fix"
    awk -v line="$asko_line" -v old="$asko_old" -v fixed="$asko_fixed" '
        NR == line {
            start = index($0, old)
            $0 = substr($0, 1, start - 1) fixed substr($0, start + length(old))
        }
        { print }
    ' "$asko_script" >"$asko_script.next"
    /system/bin/sh -n "$asko_script.next"
    chmod 700 "$asko_script.next"
    mv "$asko_script.next" "$asko_script"
fi
if [ -f "$asko_dir/supervisor.pid" ]; then
    asko_pid=$(cat "$asko_dir/supervisor.pid")
    case "$asko_pid" in ''|*[!0-9]*) exit 1;; esac
    if [ -r "/proc/$asko_pid/cmdline" ]; then
        tr '\000' ' ' <"/proc/$asko_pid/cmdline" | grep -q '/data/adb/asko-ssh/supervise.sh'
        kill "$asko_pid"
    fi
    asko_count=0
    while [ -e "$asko_dir/supervisor.pid" ] && [ "$asko_count" -lt 50 ]; do
        /system/bin/sleep 0.2
        asko_count=$((asko_count+1))
    done
    test ! -e "$asko_dir/supervisor.pid"
fi
asko_pidfile=$(awk 'tolower($1)=="pidfile" {print $2; exit}' "$asko_home/.ssh/asko-sshd.conf")
asko_pidfile=${asko_pidfile:-/data/data/com.termux/files/usr/var/run/sshd.pid}
if [ -f "$asko_pidfile" ]; then
    asko_pid=$(cat "$asko_pidfile")
    case "$asko_pid" in ''|*[!0-9]*) exit 1;; esac
    if [ -r "/proc/$asko_pid/cmdline" ]; then
        # Termux may execute sshd through linker64; /proc/PID/exe then names the linker.
        asko_command=$(tr '\000' ' ' <"/proc/$asko_pid/cmdline")
        case "$asko_command" in
            *'/data/data/com.termux/files/usr/bin/sshd -D -e -f /data/data/com.termux/files/home/.ssh/asko-sshd.conf'*) ;;
            *) printf '%s\n' 'Refusing to stop an unrelated process.' >&2; exit 1;;
        esac
        kill "$asko_pid"
    fi
fi
/system/bin/nohup /system/bin/sh "$asko_script" >>"$asko_dir/sshd.log" 2>&1 </dev/null &
printf '%s\n' 'SSH restriction removed. Reconnecting is required.'
if [ -f "$asko_home/asko/iris-install/iris-install-root.sh" ]; then
    /system/bin/sh "$asko_home/asko/iris-install/iris-install-root.sh" || {
        printf '%s\n' 'SSH fixed. Iris installation needs follow-up.'
        exit 1
    }
fi
printf '%s\n' 'Done.'
