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

KakaoTalk integration uses [Iris](https://github.com/dolidolih/Iris). See [Android setup](docs/android.md) for installation, configuration, and service commands.

Start with [config.example.json](config.example.json). Enable the rooms you want the bot to use, add your API key, and turn off `dry_run` when ready to send replies. Model calls can still incur charges in dry-run mode. Keep keys in your local configuration, outside Git.

The example uses OpenCode Go with `glm-5.3-flash`. Set `chat_backend` to `opencode_go`, `openrouter_url` (the legacy chat endpoint field) to `https://opencode.ai/zen/go/v1`, and supply your Go key in `api_key` or `OPENCODE_GO_API_KEY`. GLM-5.3 requires `reasoning_enabled: true` and `response_format: "json_object"`; replies are validated locally against the requested schema. Tool turns preserve `reasoning_content` with `thinking.clear_thinking: false`. Requests identify as asko and send a stable session ID per room. See [Go API requirements](https://opencode.ai/docs/go/#where-can-i-use-it) and [GLM API parameters](https://docs.z.ai/api-reference/llm/chat-completion).

The example allows 16,000 output tokens plus 8,192 tokens of reasoning headroom (24,192 total for answers and context notes). Go models share this total between thinking and the final response; `reasoning_max_tokens` adds headroom but does not enforce a separate thinking limit. Context planning and answer auditing use smaller task-specific output budgets with the same reasoning headroom.

Run `./run-phone.sh probe-chat` on the phone, or `./scripts/dev dune exec asko -- probe-chat --config config.local.json` locally, to check the configured model with a small synthetic JSON request. It makes one model call and can consume provider usage; it reads no room history and sends no KakaoTalk reply.

Set `api_key_embed` to your existing embedding provider key. Remote embeddings use `embedding_url` independently of chat; a different remote endpoint requires a separate key. Shared-key fallback is available only when both endpoints match. Local embeddings send no API key.

See [implementation notes](docs/implementation.md) for conversation handling, recovery, and validation limits.

Older configurations default to `chat_backend: "openrouter"`. For Gemini BYOK through OpenRouter, register your Google key in [OpenRouter BYOK settings](https://openrouter.ai/settings/integrations) and keep an OpenRouter key in `api_key`. Set `chat_provider_only` to `["google-ai-studio"]` for AI Studio or `["google-vertex"]` for Vertex. This restricts both tool and structured chat requests to that provider; embeddings keep their own key and routing. Omit the list or set it to `[]` to retain automatic provider selection.

Provider selection alone does not guarantee BYOK-only billing. Disable shared-capacity fallback on the registered BYOK key in OpenRouter if you require it. Data-collection restrictions remain enabled, and OpenRouter key limits still need to permit the request. See [OpenRouter's BYOK documentation](https://openrouter.ai/docs/guides/overview/auth/byok).
