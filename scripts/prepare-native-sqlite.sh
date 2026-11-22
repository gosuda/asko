#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
cache=$asko_repo/.cache
prefix=$cache/native-sqlite-3.54.1
# Same official amalgamation and checksum as build-sqlite3-android.
source_name=sqlite-amalgamation-3540100
source_sha=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
mkdir -p "$cache"
exec 9>"$cache/native-sqlite.lock"
flock 9
if [[ -f "$prefix/checksums" ]] && grep -Fxq "prefix=$prefix" "$prefix/lib/pkgconfig/sqlite3.pc" &&
   (cd "$prefix" && sha256sum --check --status checksums); then
    exit 0
fi

work=$(mktemp -d "$cache/native-sqlite.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
archive=${ASKO_SQLITE_ARCHIVE:-${ASKO_OPAM_ROOT:-$cache/opam}/download-cache/sha256/${source_sha:0:2}/$source_sha}
if [[ -z ${ASKO_SQLITE_ARCHIVE:-} && ! -f $archive ]]; then
    archive=$work/$source_name.zip
    curl --fail --location --silent --show-error --retry 2 -o "$archive" \
        "https://www.sqlite.org/2026/$source_name.zip"
fi
printf '%s  %s\n' "$source_sha" "$archive" | sha256sum --check --status || {
    printf 'SQLite archive missing or SHA-256 mismatch: %s\n' "$archive" >&2
    exit 1
}
unzip -q "$archive" -d "$work"
cd "$work/$source_name"
mkdir -p "$work/install/include" "$work/install/lib/pkgconfig"
# Keep these symbols local even when a bytecode host already loaded another SQLite.
gcc -O2 -fPIC -fvisibility=hidden -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_MEMSTATUS=0 \
    -c sqlite3.c -o sqlite3.o
ar rcsD "$work/install/lib/libsqlite3.a" sqlite3.o
install -m 644 sqlite3.h sqlite3ext.h "$work/install/include/"
cat > "$work/install/lib/pkgconfig/sqlite3.pc" <<EOF
prefix=$prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: SQLite
Description: SQLite database engine
Version: 3.54.1
Libs: \${libdir}/libsqlite3.a -lm -ldl -lpthread
Cflags: -I\${includedir}
EOF
cd "$work/install"
sha256sum include/sqlite3.h include/sqlite3ext.h lib/libsqlite3.a lib/pkgconfig/sqlite3.pc > checksums
if [[ -e $prefix ]]; then mv -T -- "$prefix" "$work/previous"; fi
mv -T -- "$work/install" "$prefix"
