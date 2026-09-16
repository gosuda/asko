#!/bin/sh
set -eu
asko_cc=$1
asko_ar=$2
asko_prefix=$3
"$asko_cc" -O2 -fPIC -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_MEMSTATUS=0 -c sqlite3.c -o sqlite3.o
"$asko_ar" rcs libsqlite3.a sqlite3.o
cat > sqlite3.pc <<EOF
prefix=$asko_prefix
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: SQLite
Description: SQLite library for Android
Version: 3.53.4
Libs: -L\${libdir} -lsqlite3 -lm -ldl
Cflags: -I\${includedir}
EOF
