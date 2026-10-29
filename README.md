# asko

An experimental AI assistant for KakaoTalk OpenChat, written in OCaml, with a focus on conversation summaries.

Mention the bot to catch up on a conversation, ask a question, or get help with a task. Reply to a message and mention the bot to give it context. You can follow up on its answers the same way.

## Use

Select the bot account in KakaoTalk's mention picker. The name below is an example; typing it as plain text does not invoke the bot.

```text
@요약봇 잠깐 못봤는데 뭐 있었음
@요약봇 오늘 중요한거
@요약봇 아까 postgres 얘기 결론 뭐임
[메시지에 답장하면서] @요약봇 이 얘기 결론 어떻게 됐어?
@요약봇 최근 2시간 대화 정리해줘
```

The bot can look up earlier messages when it needs more context. Each room's history stays separate.

## Setup

Build asko from source; no prebuilt binary releases are provided. You need a Linux x86_64 PC for the build and a rooted ARM64 Android phone with Termux, a KakaoTalk bot account, and [Iris v0.32](https://github.com/dolidolih/Iris/releases/tag/v0.32). Choose your own phone SSH alias in `~/.ssh/config`; `asko-phone` is only the example used in the instructions.

On the PC, set up the development tools and generate a local configuration:

```sh
./scripts/setup-dev.sh
./scripts/dev dune exec asko -- init --config config.local.json --profile openrouter
./scripts/dev dune exec asko -- check-config --config config.local.json
./scripts/dev dune exec asko -- doctor --config config.local.json
```

`init` accepts `--profile openrouter|opencode-go|local-jina`; omitting it selects the recommended `openrouter` profile. It creates a mode-0600 file, refuses to overwrite an existing file, and starts with `dry_run=true`, an empty `bot_id`, and `rooms=[]`. It only writes a preset; credentials, bot identity, and room choices must be configured explicitly. See [config.example.json](config.example.json) for configuration fields.

Follow [Android setup](docs/android.md) for the build prerequisites, cross-compilation, Iris installation, deployment, and service commands. Initialize the phone's `~/asko/config.local.json` only if it does not exist. Deployment preserves existing configuration, secrets, and the database; it does not copy your PC configuration.

### Readiness and room selection

`check-config` validates configuration. `doctor --config PATH` reports readiness as JSON offline, with no paid calls or database writes. It exits 1 for missing requirements or errors and 0 when ready; the dry-run warning alone does not block readiness. A fresh preset is expected to report missing setup. On the phone, `./run-phone.sh doctor --online` explicitly checks Iris `/config` for bot identity and the token-authenticated callback, plus the local asko `/health` endpoint. It reads no room history, sends no messages, makes no model calls, and does not write the database.

Send a self-message from the bot account in KakaoTalk so Iris can discover a nonzero bot ID. Inspect it with `./run-phone.sh iris-info`, then run `./scripts/sync-iris-id.sh asko-phone` from the PC to save the ID in the phone configuration and any existing PC configuration. `iris-info` itself does not edit configuration.

Run `rooms --config PATH` locally through `./scripts/dev dune exec asko --`, or `./run-phone.sh rooms` on the phone, to explicitly list Iris room IDs and names. Listing does not enable rooms, save room choices, or import history. Add only your chosen room IDs as strings in `rooms`; only enabled rooms can be stored, searched, or answered. Add the provider keys described below, then run `./run-phone.sh configure-iris` to set the authenticated callback to asko. Restart the backend after configuration changes.

`./run-phone.sh probe-chat` (or `./scripts/dev dune exec asko -- probe-chat --config PATH`) is a separate, optional provider check. It makes one synthetic JSON model request and can consume paid usage; it reads no room history and sends no KakaoTalk reply. Dry-run also permits paid model and embedding calls: it prevents replies, not API usage. Start in dry-run, inspect `./run-phone.sh outbox`, and set `dry_run=false` only when ready to send replies.

### Providers and credentials

The recommended `openrouter` profile uses `https://openrouter.ai/api/v1` for both chat and embeddings, sharing `OPENROUTER_API_KEY`. Keep credentials outside Git, in environment variables, a mode-0600 local configuration, or the phone's secret files:

| Phone file | Environment variable | File is loaded when |
| --- | --- | --- |
| `secrets/openrouter.key` | `OPENROUTER_API_KEY` | Variable is unset or empty (legacy behavior) |
| `secrets/opencode-go.key` | `OPENCODE_GO_API_KEY` | Variable is unset only |
| `secrets/embedding.key` | `ASKO_EMBEDDING_API_KEY` | Variable is unset only |

`api_key_env` selects the chat key variable; a nonempty environment value takes priority over `api_key`. Remote embeddings use `embedding_url` independently of chat. For embedding credentials, a nonempty value from the variable named by `api_key_embed_env` takes priority over inline `api_key_embed`. If that variable is unset or empty, the inline embedding key still applies, but setting `api_key_embed_env` to a variable name disables fallback to the chat key. Shared-chat-key fallback requires an omitted or empty `api_key_embed_env`, no inline embedding key, and matching endpoints. Local embeddings send no API key.

`chat_url` is an alias for the legacy `openrouter_url` chat endpoint field; conflicting values fail configuration validation. `embedding_backend` accepts `auto`, `openrouter`, `openai_compatible`, or `jina`; `auto` preserves the existing local-versus-remote behavior, while an explicit backend selects its API request format. These additions leave legacy runtime behavior and defaults unchanged, including the default `chat_backend: "openrouter"`.

### Optional OpenCode Go

Generate a separate configuration with `./scripts/dev dune exec asko -- init --config config.go.json --profile opencode-go`. This uses `chat_backend: "opencode_go"`, `chat_url: "https://opencode.ai/zen/go/v1"`, `model: "glm-5.3-flash"`, `response_format: "json_object"`, and `api_key_env: "OPENCODE_GO_API_KEY"`. Embeddings stay on OpenRouter at `https://openrouter.ai/api/v1`; set `api_key_embed_env` to `ASKO_EMBEDDING_API_KEY` and supply a separate OpenRouter key through that variable.

GLM replies are validated locally against the requested schema. The Go GLM endpoint rejects the `thinking` field, so asko omits it and preserves returned `reasoning_content` across tool turns. `reasoning_enabled` controls extra token headroom rather than the provider's thinking mode. Requests identify as asko and send a stable session ID per room. See [Go API requirements](https://opencode.ai/docs/go/#where-can-i-use-it) and [GLM API parameters](https://docs.z.ai/api-reference/llm/chat-completion).

The [advanced Go example](examples/config.opencode-go.json) retains `max_output_tokens: 16000` and `reasoning_max_tokens: 8192`: 24,192 total tokens for answers and context notes. Go shares this total between thinking and the final response; the headroom does not enforce a separate thinking limit. Context planning and answer auditing use smaller task-specific output budgets with the same headroom.

### Optional local Jina

Generate a separate configuration with `./scripts/dev dune exec asko -- init --config config.jina.json --profile local-jina`, or see the [Jina example](examples/config.local-jina.json). Chat still uses OpenRouter and `OPENROUTER_API_KEY`; embeddings use `embedding_backend: "jina"` at `http://127.0.0.1:8081/v1` with `jina-v5-nano-retrieval-q8`, without an embedding key. Follow the [local Jina installation steps](docs/android.md#optional-local-jina) before starting it on the phone; `init` only writes configuration.

### OpenRouter BYOK

For Gemini BYOK, register your Google key in [OpenRouter BYOK settings](https://openrouter.ai/settings/integrations) and keep an OpenRouter key in `api_key` or `OPENROUTER_API_KEY`. Set `chat_provider_only` to `["google-ai-studio"]` for AI Studio or `["google-vertex"]` for Vertex. This restricts both tool and structured chat requests; embeddings keep their own key and routing. Omit the list or use `[]` for automatic provider selection.

Provider selection alone does not guarantee BYOK-only billing. Disable shared-capacity fallback on the registered BYOK key if required. Data-collection restrictions remain enabled, and OpenRouter key limits must still permit the request. See [OpenRouter's BYOK documentation](https://openrouter.ai/docs/guides/overview/auth/byok).

See [implementation notes](docs/implementation.md) for conversation handling, recovery, and validation limits. Clean-machine installation and phone reboot behavior remain unverified.
