# Local Android package overrides

This repository supplements [opam-cross-android at 91d9d804](https://github.com/ocaml-cross/opam-cross-android/tree/91d9d8041a90b11c7a4bf77423cfe018c0f295dc).

- `build-gmp-android` retains the upstream MIT-licensed package recipe and source checksum, but skips regenerating Texinfo manuals. Runtime libraries are built normally.
- `build-sqlite3-android` builds the official SQLite amalgamation as a position-independent static archive.
- `conf-sqlite3-android` checks target linking, and `sqlite3-android` installs the upstream MIT-licensed OCaml bindings into the Android sysroot.

Packages are build dependencies; they are not installed on the phone. SQLite's published SHA3-256 checksum was verified before recording the equivalent SHA256 used by opam.
