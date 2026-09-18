# Android setup

Build on Linux x86_64 and deploy to Android ARM64 over Termux SSH. Scripts use `/data/data/com.termux/files/home/asko` on the phone.

## Build tools

```sh
./scripts/setup-dev.sh
make test
./scripts/setup-android.sh
make android
```

Tools stay in `.cache/`. The scripts use OCaml 5.4.1, opam 2.5.2, NDK r29, a pinned Android package repository, and `asko.opam.locked`. Android SQLite and GMP recipes live in `opam/`.

Install `gcc`, `make`, `git`, `curl`, `tar`, `bzip2`, `xz`, `unzip`, `patch`, `python3`, `pkg-config`, `readelf`, and `file`. Jina also needs CMake and Ninja. On Debian/Ubuntu, missing GMP and SQLite headers are downloaded with `apt-get download` and unpacked locally; their runtime libraries must already be installed. Allow several GB for tools and sources.

Use `ASKO_TOOLCHAIN_DIR=/path/to/toolchain` to reuse tools. Set `ASKO_DISABLE_OPAM_SANDBOX=1` only on runners that cannot support opam's sandbox. Setup leaves shell profiles and system packages unchanged.

For a regular opam environment, install OCaml 5.4.1 and the GMP and SQLite development libraries, then run `opam install . --deps-only --locked` and `dune build`. The Make targets wrap the project-local scripts:

```sh
make setup
make test
make setup-android
make test-android SSH_TARGET=asko-phone
make deploy SSH_TARGET=asko-phone
```

For local development after setup:

```sh
cp config.example.json config.local.json
./scripts/dev dune exec asko -- check-config --config config.local.json
./scripts/dev dune exec asko -- serve --config config.local.json
```

The phone needs no OCaml compiler or Linux container. Embeddings use OpenRouter by default; local Jina is optional.

## Deploy and control

Deploy the backend:

```sh
make deploy SSH_TARGET=asko-phone
./scripts/control-phone.sh start asko-phone
./scripts/control-phone.sh status asko-phone
./scripts/control-phone.sh stop asko-phone
```

Deployment verifies SHA256 checksums and switches the `current` symlink. It reuses identical releases, preserves configuration, secrets, and the database, and leaves running processes alone. Use `control-phone.sh restart` to load a new release. `~/asko/previous-release` records the previous target.

Consecutive requests are queued with no default cooldown. The first configuration has `dry_run=true` and no allowed rooms. The backend listens on `127.0.0.1:8080` and runs as the Termux user. The supervisor starts Jina only when `embedding_url` is local. `stop` leaves `var/disabled`, which also prevents startup after a reboot; `start` removes it.

## Credentials and rooms

Put the OpenRouter key in `api_key` in the phone's `~/asko/config.local.json`. Keep the file mode at 600. The default model is [Gemini 3.5 Flash Lite](https://openrouter.ai/google/gemini-3.5-flash-lite) with `reasoning_enabled=true`. A 2,048-token [reasoning budget](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens) is added to the response allowance. The conversation loop uses tool calling; `response_format` is used only by the older summary helpers.

You can also keep the key in a separate file. From a Bash session on the phone:

```sh
cd ~/asko
umask 077
read -rs -p 'OpenRouter API key: ' asko_key
printf '%s\n' "$asko_key" > secrets/openrouter.key
unset asko_key
```

`run-phone.sh` loads this file into `OPENROUTER_API_KEY`. A nonempty environment value takes priority over `api_key`. The application does not log the key or store it in SQLite. PC configuration files are not copied during normal deployment.

`ingest_token_env` names the variable holding the webhook token. Deployment generates `~/asko/secrets/ingest.token`; `run-phone.sh` loads it into `ASKO_INGEST_TOKEN`. Iris supplies the value through its endpoint's `token` query parameter or the `X-Asko-Token` header. Without a token, the backend trusts local callers.

## Connect Iris

Install with `./scripts/deploy-iris-phone.sh asko-phone`. It downloads [Iris v0.32](https://github.com/dolidolih/Iris/releases/tag/v0.32), verifies the published SHA256, and installs the original APK for this text bot. The [upstream installation instructions](https://github.com/dolidolih/Iris#시작하기) describe the `app_process` entry point.

The launcher gives Iris a private mount namespace and maps its `/sdcard` view to `/data/local/tmp/asko-iris/private-sdcard`. Its image cleanup stays in that private directory. Other apps keep their normal storage view, and the upstream APK is unchanged.

The launcher blocks non-loopback access to port 3000 with IPv4 and IPv6 firewall rules. Iris files and logs stay under the root-owned `/data/local/tmp/asko-iris`. This text-only setup does not configure image delivery or automatic startup after reboot.

If SSH was launched with a restricted capability bounding set, Magisk can return UID 0 without the capabilities needed for installation. In that case, open the Termux app on the phone and run the already staged installer:

```sh
su -c '/system/bin/sh /data/data/com.termux/files/home/asko/iris-install/iris-install-root.sh'
```

The installer needs Magisk root permission for Termux. It preserves an existing Iris configuration.

```sh
cd ~/asko
./run-phone.sh iris-info
./run-phone.sh check-config
```

Run `./scripts/sync-iris-id.sh asko-phone` on the PC to save the Iris bot ID in the phone configuration and any existing local `config.local.json`. Add your chosen test room IDs as strings. `iris-info` itself does not edit configuration. A native mention identifies the account by ID and is required for every request. Replies supply context only when they also mention the bot. Slash commands and fixed reply phrases do not invoke it. Only rooms in `rooms` can be stored, searched, or answered.

```sh
./run-phone.sh configure-iris
```

This sets Iris's callback URL to the local backend with the generated webhook token. It does not print the token. Restart the backend after changing its configuration.

Start with dry-run and inspect `./run-phone.sh outbox`. Set `dry_run=false` when ready to send replies. Dry-run still permits paid model calls. Verify the actual Iris message IDs, mention fields, and reply metadata in the chosen test room.

## Embeddings

The default is `openai/text-embedding-3-small` at `https://openrouter.ai/api/v1`. It uses the same OpenRouter key as the chat model and sends up to 32 conversation chunks per request. Replies include a plain-text `@nickname` prefix for the requester; this does not create a KakaoTalk mention notification.

### Optional local Jina

To run Jina on the phone, stop the backend, run `./scripts/deploy-jina-phone.sh asko-phone`, and set `embedding_model` to `jina-v5-nano-retrieval-q8` and `embedding_url` to `http://127.0.0.1:8081/v1` before restarting.

Jina uses the official `jinaai/jina-embeddings-v5-text-nano-retrieval-GGUF` Q8_0 weights, about 233 MB, under CC-BY-NC-4.0. The installer pins the model checksum and llama.cpp revision `ebbb185227c31f1652f1445e2623563d2f67fe5a`.

Jina listens at `http://127.0.0.1:8081/v1` and needs no API key. Queries use `Query: ` and conversation chunks use `Document: `. The server uses last-token pooling, 768 dimensions, two CPU threads, and a 4096-token context. asko sends conversation chunks of about 2000 bytes one at a time. The model ID separates its cache from older embeddings. `embedding_url` accepts a local address or the configured OpenRouter URL. Local embedding calls carry no OpenRouter key and consume no OpenRouter budget; remote calls use the key and the shared budget.

## Boot service

```sh
./scripts/install-boot-service.sh asko-phone
```

Magisk must grant Termux root access. `/data/adb/service.d/asko-backend.sh` launches the supervisor as the Termux user after the first unlock. Installation preserves the SSH boot service and refuses to replace an unrelated script. Phone reboot and long-term sleep behavior still need a live trial.

## Backup and retention

```sh
./scripts/backup-phone.sh asko-phone
```

The script uses `VACUUM INTO` to snapshot the live database, downloads it to `.cache/backups`, compares SHA256 checksums, then removes the phone's temporary copy. Set `ASKO_BACKUP_DIR` to choose the PC destination. Existing backups are never overwritten; manage their retention separately.

Messages expire after seven days by default. Source edits, deletion, and expiry invalidate cached embeddings and summaries. Every 30 minutes, a complete source scan marks missing messages as deleted; failed scans do not. Messages already sent to KakaoTalk remain there.

If KakaoTalk rebuilds its database and reuses `_id` values, change the generation in `source_id`. Database paths are relative to the configuration file. `status` reports queue counts; `outbox` shows recent results and their evidence. Both accept `--config`.

## Optional checks

`./run-phone.sh diagnose-jobs` reports recent job states, time since receipt, and delivery errors without printing questions or answers.

`./run-phone.sh diagnose-recovery` inspects the next backfill page for each enabled room. It reports cursor positions and invalid field types without printing message text.

```sh
make test-android SSH_TARGET=asko-phone
```

This runs native ARM64 tests with mock Iris/OpenRouter servers and a public HTTPS request to OpenRouter's model list. It sends no KakaoTalk messages and makes no paid calls. Test servers exit; binaries remain in `~/asko-runtime-test`. See [validation notes](implementation.md) for what has actually been run.

## Nicknames

Run `./run-phone.sh sync-names` to refresh the enabled rooms immediately. It prints counts, not names.

The backend refreshes room-specific OpenChat profiles when needed, at most once per minute. It also observes names in live events. Current and previously observed names map to a stable user ID within each room; old names from before collection are available only if present in stored messages. `find_participants` resolves a name to IDs, and history tools accept a `speaker_id` filter. Profile updates do not invalidate message snapshots.
