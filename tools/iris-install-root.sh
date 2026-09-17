#!/system/bin/sh
set -eu
umask 077
unset LD_PRELOAD LD_LIBRARY_PATH
asko_stage=/data/data/com.termux/files/home/asko/iris-install
asko_iris=/data/local/tmp/asko-iris
test "$(id -u)" = 0
cd "$asko_stage"
sha256sum -c Iris-asko.sha256
mkdir -p "$asko_iris"
chmod 700 "$asko_iris"
cp Iris-asko.apk "$asko_iris/Iris.apk.next"
mv "$asko_iris/Iris.apk.next" "$asko_iris/Iris.apk"
cp iris-start.sh "$asko_iris/iris-start.sh"
chmod 700 "$asko_iris/iris-start.sh"
/system/bin/sh "$asko_iris/iris-start.sh"
