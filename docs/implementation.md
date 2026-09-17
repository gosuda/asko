# Implementation notes

## Runtime

Iris, the OCaml backend, SQLite, and Jina run on the phone. OpenRouter handles classification and summaries. Cohttp/Lwt provides HTTP and asynchronous workers. OCaml resolves room, time, and message boundaries; the model returns intent and cited summaries.

Ingestion commits the message and its queued job in one transaction. Backfill resumes from a saved cursor and never executes historical commands. A serialized outbox checks delivery echoes. Interrupted sends remain uncertain until confirmed, preventing blind duplicate sends. Complete source scans reconcile edits and deletions; late events cannot restore deleted text.

Period summaries process the whole selected range in chunks and refuse requests beyond the configured budget. Topic retrieval combines embeddings, keywords, neighboring messages, and reply links. Valid citation IDs establish source membership, not whether every generated claim follows from the evidence.

`daily_budget_tokens` reserves request UTF-8 bytes plus the output allowance before each OpenRouter call. Failed calls count too. This conservative limit is not a billing total. Retention, request expiry, cooldowns, and retry limits bound stored data and work.

## Validation record

PC and Galaxy SM-F711N (Android 15) runs covered the domain, SQLite, HTTP, summaries, and mock pipeline. Checks included all invocation paths, more than 200 recovered messages, cursor recovery after a failed page, room isolation, embedding reuse, deletion reconciliation, dry-run protection, and delivery confirmation races.

The phone ran native OCaml 5.4.1 binaries built with NDK r29 for Android API 26, with `LD_PRELOAD` and `LD_LIBRARY_PATH` unset. HTTPS to OpenRouter's public model list passed with Mozilla CA verification enabled. The earlier Unix-only HTTP smoke test also covered GET, Korean JSON POST, and 404 responses.

Deployment, repeated deployment, configuration preservation, duplicate process prevention, child restart, and clean shutdown were checked. An empty asko database was backed up to the PC with matching hashes and SQLite integrity intact. Synthetic data tests covered snapshot consistency and refusal to overwrite files. No real KakaoTalk database was copied.

Qwen's JSON mode, configuration-file keys, environment-key precedence, and strict-schema compatibility passed mock tests on PC and phone. The later Jina change received a build check and one real on-phone embedding request, which returned 768 dimensions. The full regression suite was not rerun for the Jina or alias-removal changes.

Iris v0.32 now starts from the original APK in a private mount namespace. The bot ID was read from Iris and saved to both phone and local configuration; the authenticated callback points to asko. SSH root capabilities were restored by removing the launcher's explicit capability drop.

## Remaining checks

Actual KakaoTalk events and delivery, paid OpenRouter calls, Korean summary quality, and phone sleep, reboot, and network transitions need a live trial. The backend boot installer is prepared but has not been installed or tested across a reboot. Setup scripts ran against an existing dependency cache; a clean-machine installation has not been repeated.

Work stays on `lidarbtc/android-backend` with local commits and no remote push. Live send tests require a chosen test room. API keys and conversations stay out of Git.
