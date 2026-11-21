# Local opam package overrides

This repository supplements [opam-cross-android at 386b2b24](https://github.com/ocaml-cross/opam-cross-android/tree/386b2b24b105188cb7b1ec7e82ef357a999626e2). The local `ocaml-android.5.5.2` recipe uses the official OCaml release archive and requires the same host compiler version.

Android setup caches the cross repository under `$ASKO_TOOLCHAIN_DIR/opam-cross-android-<commit>` and gives opam the exact Git revision. The existing host compiler and NDK can be reused from the same toolchain directory. Each repository URL gets its own opam name. On each run, setup refreshes both sources and gives the current checkout's local overrides first priority in the `asko-5.5.2` switch.

The updated TLS, Lwt, Digestif, dune-configurator and conditional PPX recipes use the release archives and dependency bounds from [opam-repository at 78f35b91](https://github.com/ocaml/opam-repository/tree/78f35b9177940ff299f8676f91db81fb98d7455d/packages). The other OCaml library overrides were adapted from [the earlier a04b045f snapshot](https://github.com/ocaml/opam-repository/tree/a04b045f1534714416da6b4f8e8e67d2defbb750/packages).

| Android packages (all use the `-android` suffix) | Version |
| --- | --- |
| `tls`, `tls-lwt` | 2.1.5 |
| `lwt` | 6.1.3 |
| `mirage-crypto`, `mirage-crypto-ec`, `mirage-crypto-pk`, `mirage-crypto-rng` | 2.4.1 |
| `x509` | 1.2.0 |
| `digestif` | 1.4.2 |
| `kdf` | 1.1.2 |
| `cohttp`, `cohttp-lwt`, `cohttp-lwt-unix`, `http` | 6.3.0 |
| `dune-configurator` | 3.25.0 |
| `ppx_devtools-optcomp` | 0.1 |
| `ppxlib` | 0.39.0 |
| `ocaml_intrinsics_kernel` | v0.17.3 |
| `asn1-combinators` | 0.3.3 |
| `re` | 1.14.0 |

Dune, configuration executables and PPX generators run on the build host. Lwt uses the native `ppx_devtools-optcomp` rewriter and its matching package in Dune's Android context. Lwt's discovery program probes the NDK's API 26 compiler with `--android-target true` and tests libev only when `conf-libev-android` is installed. Android setup selects `opam-file-format.2.2.0` for the host's opam tools.

The native and Android Lwt 6.1.3 recipes carry the same one-line fix for systems that use non-reentrant service lookups, including Android. Both recipes record the same patch SHA-256 because opam expects regular files when refreshing a repository. The fix restores the OCaml GC root chain when those C stubs return. The unpatched Android build crashed during the HTTP regression test. [Lwt 6.1.3 lookup implementation](https://github.com/ocsigen/lwt/blob/6.1.3/src/unix/unix_c/unix_getprotoby_getservby_job.c#L224-L245)

The library recipes build `@install` for Android ARM64. Unix comes from `ocaml-android`. Cohttp, PPXLib and dune-configurator declare the native libraries their generators need as well as their target libraries. Opam 2.6 tracks the files installed under the switch, including the Android sysroot and compiler symlinks, and uses that record for removal.

- `build-gmp-android` builds static PIC GMP 6.3.0 with `MAKEINFO=true` and retains the upstream recipe's explicit cleanup. `conf-gmp-powm-sec-android` checks constant-time exponentiation against the target library.
- `build-sqlite3-android` builds the official SQLite 3.54.1 amalgamation as a position-independent static archive and publishes the same version in `sqlite3.pc`.
- `conf-sqlite3-android` checks target linking, and `sqlite3-android` retains the upstream MIT-licensed OCaml bindings at 5.4.2, installing them into the Android sysroot.

All library source archive checksums were verified against actual downloads. The SHA-256 used by opam and SQLite's published SHA3-256 both identify the `sqlite-amalgamation-3540100.zip` archive. [SQLite downloads](https://www.sqlite.org/download.html)

```text
SHA3-256 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30
SHA256   0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
```

The packages are installed in the build host's switch and Android sysroot. The phone receives the resulting executable. When updating the native lock, keep the explicit Android versions in `scripts/setup-android.sh` aligned with these overrides.
