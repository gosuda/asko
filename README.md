# asko

An experimental OCaml assistant for KakaoTalk OpenChat conversations through [Iris](https://github.com/dolidolih/Iris). It responds only when its account is mentioned in KakaoTalk. Requests use natural language; reply to a message while mentioning the bot to provide context.

The backend, SQLite database, and Jina embedding server run on a rooted Android ARM64 phone. DeepSeek V4.1 Flash reads the context and responds through OpenRouter. It can request more conversation through local tools. Build the native binaries on Linux; the phone needs no OCaml compiler or Linux container.

## Use

Consecutive requests are queued with no default cooldown.

Select the bot account in KakaoTalk's mention picker. Typing its name as plain text does not invoke it.

```text
@요약봇 잠깐 못봤는데 뭐 있었음
@요약봇 오늘 중요한거
@요약봇 아까 postgres 얘기 결론 뭐임
[메시지에 답장하면서] @요약봇 이 얘기 결론 어떻게 됐어?
@요약봇 최근 2시간 대화 정리해줘
```

The model receives recent conversation, the replied message, and its earlier answer. It decides whether to answer directly, read a period of history, or search for more context. Follow-ups to a bot answer can recover its original sources and speaker names. Requests are not classified into a fixed menu.

Time expressions are interpreted relative to the request time in Asia/Seoul. Tools enforce the current room, retention window, and message boundary. A response can be a summary, an explanation, or an ordinary conversational reply. The backend validates cited source IDs and retains the existing resource budgets.

## Build

```sh
make setup
make test
make setup-android
make test-android SSH_TARGET=asko-phone
make deploy SSH_TARGET=asko-phone
```

The setup scripts use a project-local `.cache/` on Linux x86_64. For a regular opam environment, install OCaml 5.4.1 and the GMP and SQLite development libraries, then run `opam install . --deps-only --locked` and `dune build`.

```sh
cp config.example.json config.local.json
./scripts/dev dune exec asko -- check-config --config config.local.json
./scripts/dev dune exec asko -- serve --config config.local.json
```

Install Jina before starting the phone backend. See [Android setup](docs/android.md) for deployment and service commands.

## Configure

Edit `config.local.json`, or `~/asko/config.local.json` on the phone. Deployment preserves the phone's configuration; it does not upload your PC's copy.

| Setting | Purpose |
| --- | --- |
| `api_key` | Your OpenRouter key. A nonempty `OPENROUTER_API_KEY` environment variable takes priority. |
| `ingest_token_env` | The environment-variable name containing the Iris webhook token, normally `ASKO_INGEST_TOKEN`. Deployment creates the token; the launcher loads it. |
| `bot_id` | The bot account ID returned by `iris-info`. `scripts/sync-iris-id.sh` can fill it in. |
| `rooms` | Room IDs the bot may store, search, and answer in. Starts empty. |
| `dry_run` | Blocks KakaoTalk replies. Model calls can still incur charges when a key is configured. |

Keep the file private with `chmod 600 config.local.json`. Git ignores it, and `check-config` prints only whether a key is present.

[DeepSeek V4.1 Flash](https://openrouter.ai/deepseek/deepseek-v4.1-flash) uses tool calling for history lookup and replies. `reasoning_enabled=true` adds a 2,048-token [reasoning budget](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens) to the response allowance.

Jina v5 Nano retrieval Q8 runs at `http://127.0.0.1:8081/v1`. It needs no API key. Queries use `Query: ` and conversation chunks use `Document: `.

See [implementation notes](docs/implementation.md) for recovery behavior and validation limits. The end-user interface is KakaoTalk; operators use configuration files and the CLI.
