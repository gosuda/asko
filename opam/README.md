# Local Android package overrides

This repository supplements [opam-cross-android at 91d9d804](https://github.com/ocaml-cross/opam-cross-android/tree/91d9d8041a90b11c7a4bf77423cfe018c0f295dc). The local `ocaml-android.5.5.2` recipe uses the official OCaml release archive and the same host compiler version. OCaml 5.5 handles platforms without `pthread_cancel` directly, so the previous Android runtime patch is no longer needed.

The OCaml library overrides use the release sources, checksums and dependency bounds from [the native opam repository at a04b045f](https://github.com/ocaml/opam-repository/tree/a04b045f1534714416da6b4f8e8e67d2defbb750/packages), adapted to the existing Android build/install conventions.

| Android packages (all use the `-android` suffix) | Version |
| --- | --- |
| `tls`, `tls-lwt` | 2.1.4 |
| `mirage-crypto`, `mirage-crypto-ec`, `mirage-crypto-pk`, `mirage-crypto-rng` | 2.4.1 |
| `x509` | 1.2.0 |
| `digestif` | 1.4.1 |
| `kdf` | 1.1.2 |
| `cohttp`, `cohttp-lwt`, `cohttp-lwt-unix`, `http` | 6.3.0 |
| `dune-configurator` | 3.24.2 |
| `ppxlib` | 0.39.0 |
| `ocaml_intrinsics_kernel` | v0.17.3 |
| `asn1-combinators` | 0.3.3 |
| `re` | 1.14.0 |

Dune, configuration executables and PPX generators run on the build host. Their native dependencies stay unsuffixed; libraries linked into the target use Android dependencies. Cohttp, PPXLib and dune-configurator declare the native libraries needed by their generators as well as their target libraries. The GMP constant-time exponentiation check uses `conf-gmp-powm-sec-android`, so it validates the target library.

These recipes build `@install` for the configured Android ARM64 target. Upstream test, documentation and development-tool dependencies are omitted because the recipes do not run those targets. Unix comes from `ocaml-android`; native `base-unix` and host-architecture availability filters are not used to describe the Android target. The OCaml version bounds are retained, including PPXLib's upper bound of `< 5.7.0`.

- `build-gmp-android` remains at 6.3.0. It retains the upstream MIT-licensed package recipe and source checksum, but skips regenerating Texinfo manuals. Runtime libraries are built normally.
- `build-sqlite3-android` builds the official SQLite 3.54.1 amalgamation as a position-independent static archive and publishes the same version in `sqlite3.pc`.
- `conf-sqlite3-android` checks target linking, and `sqlite3-android` retains the upstream MIT-licensed OCaml bindings at 5.4.2, installing them into the Android sysroot.

All library source archive checksums were verified against actual downloads. For SQLite, the [published SHA3-256](https://www.sqlite.org/download.html) for `sqlite-amalgamation-3540100.zip` was independently verified before recording the SHA256 used by opam:

```text
SHA3-256 92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30
SHA256   0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
```

The packages are installed in the build host's switch and Android sysroot. The phone receives the resulting binary, not an opam installation. Updating the native lock file alone does not update Android; keep the explicit versions in `scripts/setup-android.sh` aligned with these overrides.
