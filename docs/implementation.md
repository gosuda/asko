# Implementation notes

## Runtime

Iris, the OCaml backend, SQLite, and Jina run on the phone. OpenRouter handles a conversational tool loop. Cohttp/Lwt provides HTTP and asynchronous workers. The model chooses how to respond and can read or search messages. OCaml enforces room, retention, and invocation boundaries on every lookup.

Ingestion commits the message and its queued job in one transaction. Backfill resumes from a saved cursor and never executes historical commands. A serialized outbox checks delivery echoes. Interrupted sends remain uncertain until confirmed, preventing blind duplicate sends. Complete source scans reconcile edits and deletions; late events cannot restore deleted text. Active work checks the messages it actually read, including reply context, instead of a room-wide version. Nickname and mention metadata updates do not restart work. Embedding dependencies and answer evidence restrict invalidation to affected data; a changed unsent answer is requeued, and exhausted source retries produce a notice.

Each turn starts with recent messages, reply context, and the previous response. `read_messages`, `search_messages`, and `get_message` expose original records; `respond` returns free-form text with optional source IDs. There is no intent classifier or summary-only rejection. Dates use RFC3339 tool arguments. The loop allows eight model turns within the existing token and time budgets. Valid citation IDs establish source membership, not whether every generated claim follows from the evidence.

`daily_budget_tokens` reserves request UTF-8 bytes plus the output allowance before each OpenRouter call. Failed calls count too. This conservative limit is not a billing total. Retention, request expiry, cooldowns, and retry limits bound stored data and work.

## Validation record

PC and Galaxy SM-F711N (Android 15) runs covered the domain, SQLite, HTTP, summaries, and mock pipeline. Checks included all invocation paths, more than 200 recovered messages, cursor recovery after a failed page, room isolation, embedding reuse, deletion reconciliation, dry-run protection, and delivery confirmation races.

The phone ran native OCaml 5.4.1 binaries built with NDK r29 for Android API 26, with `LD_PRELOAD` and `LD_LIBRARY_PATH` unset. HTTPS to OpenRouter's public model list passed with Mozilla CA verification enabled. The earlier Unix-only HTTP smoke test also covered GET, Korean JSON POST, and 404 responses.

Deployment, repeated deployment, configuration preservation, duplicate process prevention, child restart, and clean shutdown were checked. An empty asko database was backed up to the PC with matching hashes and SQLite integrity intact. Synthetic data tests covered snapshot consistency and refusal to overwrite files. No real KakaoTalk database was copied.

Qwen's JSON mode, configuration-file keys, environment-key precedence, and strict-schema compatibility passed mock tests on PC and phone. The later Jina change received a build check and one real on-phone embedding request, which returned 768 dimensions. The full regression suite was not rerun for the Jina or alias-removal changes.

Iris v0.32 now starts from the original APK in a private mount namespace. The bot ID was read from Iris and saved to both phone and local configuration; the authenticated callback points to asko. SSH root capabilities were restored by removing the launcher's explicit capability drop.

The conversational path passed a mock tool-call run covering source retrieval, a follow-up to a bot reply, room isolation, and original evidence restoration.

Focused checks cover unrelated edits and expiry, nickname updates, in-flight embedding writes, dependent answer requeueing, and a notice after source retries are exhausted.

## Remaining checks

Basic test-room ingestion and live replies have been observed. Broader conversational quality and phone sleep, reboot, and network transitions need further live use. The backend boot installer is prepared but has not been installed or tested across a reboot. Setup scripts ran against an existing dependency cache; a clean-machine installation has not been repeated.

Live send tests use a designated test room. API keys and conversations stay out of Git.
