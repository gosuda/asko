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

Set `api_key_embed` to use a separate key for remote embeddings. When omitted or blank, embeddings use the chat API key. Local embeddings send no API key.

See [implementation notes](docs/implementation.md) for conversation handling, recovery, and validation limits.

For Gemini BYOK through OpenRouter, register your Google key in [OpenRouter BYOK settings](https://openrouter.ai/settings/integrations) and keep an OpenRouter key in `api_key`. Set `chat_provider_only` to `["google-ai-studio"]` for AI Studio or `["google-vertex"]` for Vertex. This restricts both tool and structured chat requests to that provider; embeddings keep their own key and routing. Omit the list or set it to `[]` to retain automatic provider selection.

Provider selection alone does not guarantee BYOK-only billing. Disable shared-capacity fallback on the registered BYOK key in OpenRouter if you require it. Data-collection restrictions remain enabled, and OpenRouter key limits still need to permit the request. See [OpenRouter's BYOK documentation](https://openrouter.ai/docs/guides/overview/auth/byok).
