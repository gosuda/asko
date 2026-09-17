#!/system/bin/sh
set -eu
umask 077
unset LD_PRELOAD LD_LIBRARY_PATH
asko_stage=/data/data/com.termux/files/home/asko/iris-install
asko_iris=/data/local/tmp/asko-iris
test "$(id -u)" = 0
cd "$asko_stage"
printf '%s  %s\n' 00eaa7800f904b7e3082277525adbbc0581ffe9efdb1c7a475561361f918eab0 Iris.apk | sha256sum -c -
mkdir -p "$asko_iris"
chmod 700 "$asko_iris"
cp Iris.apk "$asko_iris/Iris.apk.next"
mv "$asko_iris/Iris.apk.next" "$asko_iris/Iris.apk"
cp iris-start.sh iris-inner.sh "$asko_iris/"
chmod 700 "$asko_iris/iris-start.sh" "$asko_iris/iris-inner.sh"
/system/bin/sh "$asko_iris/iris-start.sh"
