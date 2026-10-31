# Android setup

Build asko from source on a Linux x86_64 PC and deploy to a rooted Android ARM64 phone over Termux SSH. There is no prebuilt asko release distribution. Scripts use `/data/data/com.termux/files/home/asko` on the phone.

## Prerequisites

The phone needs Termux, root access (the Iris installer uses Magisk), KakaoTalk signed in to the bot account, and [Iris v0.33](https://github.com/dolidolih/Iris/releases/tag/v0.33). Install Iris with the project script in [Connect Iris](#connect-iris) after deploying asko. The phone needs no OCaml compiler or Linux container. OpenRouter supplies chat and embeddings by default; Go chat and local Jina embeddings are optional.

In Termux, install and start SSH, and note the username from `whoami`:

```sh
pkg install openssh
whoami
sshd
```

Create an SSH key on the PC if needed and put its public key in the phone's `~/.ssh/authorized_keys` (directory mode 700, file mode 600). Define an alias in the PC's `~/.ssh/config`, replacing the address and username:

```sshconfig
Host asko-phone
    HostName PHONE_IP
    User TERMUX_USER
    Port 8022
```

`asko-phone` is an example; choose your own alias and use it in every command below. Confirm that `ssh -o BatchMode=yes asko-phone true` works before deployment. The scripts require key-based SSH without an interactive password prompt.

## Build tools

On the PC, install `gcc`, `make`, `git`, `curl`, `tar`, `bzip2`, `xz`, `unzip`, `patch`, `python3`, `pkg-config`, `readelf`, `file`, and an OpenSSH client. Jina also needs CMake and Ninja. On Debian/Ubuntu, missing GMP and SQLite headers are downloaded with `apt-get download` and unpacked locally; their runtime libraries must already be installed. Allow several GB for tools and sources. Run the following from the source checkout:

```sh
./scripts/setup-dev.sh
./scripts/dev dune exec asko -- init --config config.local.json --profile openrouter
./scripts/dev dune exec asko -- check-config --config config.local.json
./scripts/dev dune exec asko -- doctor --config config.local.json
```

Skip `init` if this configuration already exists: it refuses to overwrite any file. New files have mode 0600, `dry_run=true`, an empty `bot_id`, and no allowed rooms. It writes a preset only; bot identity and room choices are explicit configuration edits. `openrouter` is the default profile; `opencode-go` and `local-jina` are alternatives. See the [default example](../config.example.json), [Go preset](../examples/config.opencode-go.json), and [local Jina preset](../examples/config.local-jina.json). Configuration paths are explicit so local checks need not use a deployment's configuration.

`check-config` validates configuration. `doctor` reports JSON readiness checks offline, without paid calls or database writes. It exits 1 for missing requirements or errors and 0 when ready; a dry-run warning alone does not block readiness. Missing keys, a webhook token, a bot ID, and allowed rooms are expected at this point. Add keys as described below if checking credential presence on the PC; offline checks cannot validate a provider key. The PC's configuration and keys are not copied to the phone during deployment.

Build the Android executable from the same checkout:

```sh
./scripts/setup-android.sh
make android
```

Tools stay in `.cache/`. The scripts use OCaml 5.5.2, opam 2.6.1, NDK r30, a pinned Android package repository, and `asko.opam.locked`. Android SQLite and GMP recipes live in `opam/`. Local overrides also pin the Android compiler and updated HTTP, TLS, cryptography, and build libraries. SQLite bindings remain at 5.4.2, with SQLite 3.54.1 statically linked on Android.

The host compiler is installed under `host-5.5.2` and packages use the `asko-5.5.2` opam switch, so setup can retain the previous compiler and switch. Native and Android dependencies are installed separately; refresh both with `make setup-android`. The lock uses opam's `ocamlfind 1.9.9~preview` package (fixed upstream commit and checksums), because 1.9.8 excludes OCaml 5.5. This is a build tool, not a phone runtime dependency.

Use `ASKO_TOOLCHAIN_DIR=/path/to/toolchain` to reuse tools. Set `ASKO_DISABLE_OPAM_SANDBOX=1` only on runners that cannot support opam's sandbox. Setup leaves shell profiles and system packages unchanged.

For a separate opam dependency root, export `ASKO_OPAM_ROOT=/absolute/path/to/fresh-opam` and keep it set when using `scripts/dev`, `scripts/setup-dev.sh`, and `scripts/setup-android.sh`. The default remains the checkout's `.cache/opam`.

After moving the checkout, rebuild the host compiler and opam switch at the new path: both embed absolute paths. Do not recreate the old checkout path with a compatibility symlink or link caches into Trash. Use fresh `.cache/bin`, `.cache/opam`, and `.cache/toolchain` directories and rerun `make setup-android`; verified source archives and the NDK may be reused. Remove or update `.cache/toolchain-path` if it still names the old location.

For a regular opam environment, install OCaml 5.5.2 and the GMP and SQLite development libraries, then run `opam install . --deps-only --locked` and `dune build`. The Make targets wrap the project-local scripts:

```sh
make setup
make test
make setup-android
make test-android SSH_TARGET=asko-phone
make deploy SSH_TARGET=asko-phone
```

For local development after setup, `./scripts/dev dune exec asko -- serve --config config.local.json` starts the service with that configuration. Its default Iris URL points to loopback on the machine running asko; use the phone for Iris checks unless you have explicitly arranged access from the PC.

## Deploy and control

Deploy the backend from the PC:

```sh
make deploy SSH_TARGET=asko-phone
```

Deployment verifies SHA256 checksums and switches the `current` symlink. It reuses identical releases, preserves configuration, secrets, and the database, and leaves running processes alone. Use `control-phone.sh restart` to load a new release. `~/asko/previous-release` records the previous target.

On the phone, use the existing `~/asko/config.local.json` if deployment created it. If no configuration exists, initialize one with the chosen profile:

```sh
cd ~/asko
./run-phone.sh init --profile openrouter
```

`run-phone.sh` supplies `--config ~/asko/config.local.json`. Initialization refuses to overwrite an existing configuration, including when choosing a different profile. For an existing installation, keep its configuration and edit only the fields you intend to change. Continue with credentials and Iris before starting a new installation.

From the PC, service controls are:

```sh
./scripts/control-phone.sh start asko-phone
./scripts/control-phone.sh status asko-phone
./scripts/control-phone.sh stop asko-phone
./scripts/control-phone.sh restart asko-phone
```

Consecutive requests are queued with no default cooldown. The first configuration has `dry_run=true` and no allowed rooms. The backend listens on `127.0.0.1:8080` and runs as the Termux user. The supervisor starts Jina for local Jina embeddings; `auto` retains the previous loopback behavior. `stop` leaves `var/disabled`, which also prevents startup after a reboot; `start` removes it.

## Credentials and rooms

The default OpenRouter profile uses one key for chat and embeddings at `https://openrouter.ai/api/v1`. Its model is [Gemini 3.5 Flash Lite](https://openrouter.ai/google/gemini-3.5-flash-lite), with `reasoning_enabled=true` and a 2,048-token [reasoning budget](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens) added to the response allowance. The conversation loop uses tool calling; `response_format` is used for structured context planning, batch notes, and grounding checks.

Keep keys out of Git. Use a separate file, or set `api_key` in the phone's `~/asko/config.local.json` and keep that file mode at 600. Keep existing key files when updating an installation. To create a new default key file from a Bash session on the phone:

```sh
cd ~/asko
umask 077
mkdir -p secrets
read -rs -p 'OpenRouter API key: ' asko_key
printf '%s\n' "$asko_key" > secrets/openrouter.key
chmod 600 secrets/openrouter.key
unset asko_key
```

`run-phone.sh` loads nonempty key files under these conditions. An explicitly empty Go or embedding variable suppresses file loading; OpenRouter retains its legacy behavior:

| Profile/use | Phone file | Environment variable | File is loaded when |
| --- | --- | --- | --- |
| OpenRouter chat and default embeddings | `secrets/openrouter.key` | `OPENROUTER_API_KEY` | Variable is unset or empty |
| OpenCode Go chat | `secrets/opencode-go.key` | `OPENCODE_GO_API_KEY` | Variable is unset only |
| Separate remote embeddings (Go preset) | `secrets/embedding.key` | `ASKO_EMBEDDING_API_KEY` | Variable is unset only |

For Go, repeat the prompt/write steps with `secrets/opencode-go.key` for the Go key and `secrets/embedding.key` for an OpenRouter key. Set `chat_backend` to `opencode_go`, `chat_url` to `https://opencode.ai/zen/go/v1`, `model` to `glm-5.3-flash`, `response_format` to `json_object`, and `api_key_env` to `OPENCODE_GO_API_KEY`; keep remote embeddings on OpenRouter and set `api_key_embed_env` to `ASKO_EMBEDDING_API_KEY`. The [Go preset](../examples/config.opencode-go.json) shows these fields together, with larger optional token budgets.

For local commands, export the variables named by the profile in your shell. A nonempty value in the variable named by `api_key_env` takes priority over `api_key`. For embeddings, the variable named by `api_key_embed_env` takes priority when nonempty, then inline `api_key_embed` is tried. Naming an embedding-key variable disables fallback to the chat key even if that variable is unset or empty. Shared-chat-key fallback requires an omitted or empty `api_key_embed_env`, no inline embedding key, and matching endpoints. Local embeddings send no API key. The application does not log keys or store them in SQLite.

`chat_url` is an alias for the legacy `openrouter_url` field; use one name, as conflicting values fail validation. `embedding_backend` accepts `auto`, `openrouter`, `openai_compatible`, or `jina`. Omitting it retains `auto` and the previous local-versus-remote behavior; an explicit backend selects its API request format. Existing configuration defaults and runtime behavior are unchanged.

`ingest_token_env` names the variable holding the webhook token. Deployment generates `~/asko/secrets/ingest.token`; `run-phone.sh` loads it into `ASKO_INGEST_TOKEN`. Iris supplies the value through its endpoint's `token` query parameter or the `X-Asko-Token` header. Without a token, the backend trusts local callers.

## Connect Iris

Install with `./scripts/deploy-iris-phone.sh asko-phone`. It downloads [Iris v0.33](https://github.com/dolidolih/Iris/releases/tag/v0.33), verifies the published SHA256, and installs the original APK for this text bot. If a different APK is already running, the installer stops that Iris process and starts the new one; the existing Iris configuration is kept. The [upstream installation instructions](https://github.com/dolidolih/Iris#시작하기) describe the `app_process` entry point.

The launcher gives Iris a private mount namespace and maps its `/sdcard` view to `/data/local/tmp/asko-iris/private-sdcard`. Its image cleanup stays in that private directory. Other apps keep their normal storage view, and the upstream APK is unchanged. Iris v0.33 copies KakaoTalk databases and extracts its SQLCipher library into a private work directory; the launcher sets `IRIS_WORK_DIR=/data/local/tmp/asko-iris/work` instead of the upstream default `/data/local/tmp/Iris.work`.

The launcher blocks external access to Iris on port 3000 and rejects loopback connections from every UID except Termux, for both IPv4 and IPv6. The UID rule requires `--socket-exists` so kernel-generated TCP ACK/RST packets without an owning socket can complete connection teardown. Without this condition, closed client sockets can leave Iris stuck in `LAST_ACK`, causing repeated FIN retransmissions and intermittent connection timeouts despite fast database queries. The launcher installs the replacement before removing copies of its older rule; unrelated firewall rules are preserved. It checks these rules even when Iris is already running and stops Iris if it cannot install them. Iris must keep `botHttpPort` at 3000; the launcher refuses to start it with another port. Iris files and logs stay under the root-owned `/data/local/tmp/asko-iris`. This text-only Iris installer does not configure image delivery or install a boot service; startup after reboot is a separate [opt-in step](#boot-service).

If SSH was launched with a restricted capability bounding set, Magisk can return UID 0 without the capabilities needed for installation. In that case, open the Termux app on the phone and run the already staged installer:

```sh
su -c '/system/bin/sh /data/data/com.termux/files/home/asko/iris-install/iris-install-root.sh'
```

The installer needs Magisk root permission for Termux. It preserves an existing Iris configuration. Send a message to yourself from the bot's KakaoTalk account so Iris can discover a nonzero bot ID, then check it on the phone:

```sh
cd ~/asko
./run-phone.sh iris-info
./run-phone.sh check-config
```

An empty bot ID or `0` is not ready. Run `./scripts/sync-iris-id.sh asko-phone` on the PC to save the ID in the phone configuration and any existing local `config.local.json`. `iris-info` itself does not edit configuration.

On the phone, explicitly list the rooms available through Iris:

```sh
./run-phone.sh rooms
```

This lists room IDs and names without enabling rooms, saving room choices, or importing history. Add only your chosen test room IDs as strings in `rooms` in `~/asko/config.local.json`, for example `"rooms": ["123456789"]` with the actual ID. Only allowed rooms can have their messages stored, searched, or answered. A native mention identifies the account by ID and is required for every request. Replies supply context only when they also mention the bot. Slash commands and fixed reply phrases do not invoke it.

Connect the authenticated callback on the phone:

```sh
./run-phone.sh configure-iris
./run-phone.sh doctor
./run-phone.sh doctor --online
```

`configure-iris` sets Iris's callback URL to the local backend with the generated webhook token, without printing the token. `doctor --online` explicitly reads Iris `/config` to check bot identity and the token-authenticated callback, and checks the local asko `/health` endpoint. It reads no room history, sends no messages, makes no model calls, and does not write the database. Before the backend starts, its health check will be unavailable. Start it from the PC with `./scripts/control-phone.sh start asko-phone`, then repeat `doctor --online` on the phone. Restart the backend after later configuration changes.

Keep `dry_run=true` while testing mentions in the chosen room and inspect `./run-phone.sh outbox`. Dry-run prevents sending replies but still permits paid chat and embedding calls. The optional `./run-phone.sh probe-chat` makes one small synthetic model request and consumes provider usage; it does not read room history or send a KakaoTalk reply. Set `dry_run=false` and restart only when ready to send replies. Verify the actual Iris message IDs, mention fields, and reply metadata in the chosen test room.

## Embeddings

The default is [Gemini Embedding 001](https://openrouter.ai/google/gemini-embedding-001) at `https://openrouter.ai/api/v1`, using 3,072 dimensions. It uses the existing OpenRouter key and up to 16 chunks per request. [OpenRouter input types](https://openrouter.ai/docs/api/api-reference/embeddings/submit-an-embedding-request) distinguish `search_document` from `search_query`. Replies include a plain-text `@nickname` prefix for the requester; this does not create a KakaoTalk mention notification.

Embedding cache keys are separated by model. Chunks use stable message-ID windows, so appending messages does not shift completed windows. To backfill every retained message in every allowed room on the phone:

```sh
cd ~/asko
./run-phone.sh backfill-embeddings --embedding-model google/gemini-embedding-001
```

The command reports room, snapshot boundary, message count, completed chunks, and total chunks. Completed chunks are committed incrementally and reused on reruns. Changing `embedding_model` in `config.local.json` and restarting activates the new model; an override only applies to that command. Old model caches are preserved for rollback.

For a historical quality check without posting to KakaoTalk, use `./run-phone.sh replay-job --job-id ID`. This uses the configured models and can incur API charges. Its output includes the new answer and measured coverage; it never queues an outbox item.

### Optional local Jina

To run Jina on the phone, stop the backend, run `./scripts/deploy-jina-phone.sh asko-phone` from the PC, and set `embedding_backend` to `jina`, `embedding_model` to `jina-v5-nano-retrieval-q8`, and `embedding_url` to `http://127.0.0.1:8081/v1` before restarting. The [local Jina preset](../examples/config.local-jina.json) keeps OpenRouter chat, so its chat API key is still required. `init --profile local-jina` only writes configuration; it does not install the model or server.

Jina uses the official `jinaai/jina-embeddings-v5-text-nano-retrieval-GGUF` Q8_0 weights, about 233 MB, under CC-BY-NC-4.0. The installer pins the model checksum and llama.cpp v0.8.0 at revision `8642541b255bfb5dc39cd351a178be09013a55d6`.

Jina listens at `http://127.0.0.1:8081/v1` and needs no API key. Queries use `Query: ` and conversation chunks use `Document: `. The server uses last-token pooling, 768 dimensions, two CPU threads, and a 4096-token context. asko sends conversation chunks of about 2000 bytes one at a time. The model ID separates its cache from older embeddings. `embedding_url` is independent of the chat endpoint; another remote endpoint needs its own embedding key. Local embedding calls carry no OpenRouter key and consume no OpenRouter budget; remote calls use the key and the shared budget.

## Boot service

From the PC, install the backend-only boot entry (the default):

```sh
./scripts/install-boot-service.sh asko-phone
```

To include a separate Iris boot entry, install Iris with `deploy-iris-phone.sh` first, then explicitly opt in:

```sh
./scripts/install-boot-service.sh --with-iris asko-phone
```

Magisk must grant Termux root access. Boot entries wait indefinitely for the first unlock. `/data/adb/service.d/asko-backend.sh` then launches the supervisor as the Termux user. Installation preserves the SSH boot service, accepts identical entries, and refuses to replace differing scripts, including older managed versions. It does not start or restart services. Phone reboot and long-term sleep behavior still need a live trial.

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
