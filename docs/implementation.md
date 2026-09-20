# Implementation notes

## Runtime

Iris, the OCaml backend, and SQLite run on the phone. OpenRouter supplies embeddings and handles the conversational tool loop; local Jina is optional. Cohttp/Lwt provides HTTP and asynchronous workers. The model chooses how to respond and can read or search messages. OCaml enforces room, retention, and invocation boundaries on every lookup.

Ingestion commits the message and its queued job in one transaction. Backfill resumes from a saved cursor and never executes historical commands. A serialized outbox checks delivery echoes. Interrupted sends remain uncertain until confirmed, preventing blind duplicate sends. Complete source scans reconcile edits and deletions; late events cannot restore deleted text. Active work checks the messages it actually read, including reply context, instead of a room-wide version. Nickname and mention metadata updates do not restart work. Embedding dependencies and answer evidence restrict invalidation to affected data; a changed unsent answer is requeued, and exhausted source retries produce a notice.

A context planner separates general conversation, topic lookup, and exhaustive reading without restricting which questions the assistant can answer. Explicit periods are resolved against the request's KST timestamp. Period summaries and participant-wide analysis read every stored original in the selected scope before answering. Large scopes are split into bounded batches, processed with up to three concurrent note requests, and synthesized from source-linked notes; an exhausted budget fails explicitly instead of silently skipping pages.

Ordinary context reserves space for recent messages before adding bounded earlier evidence. An implicit previous exchange must belong to the same requester, have been delivered before the current request, and be at most 30 minutes old. The planner carries its question and answer forward only for a related follow-up. Explicit replies retain their anchor behavior.

`read_messages`, `search_messages`, and `get_message` expose original records within the selected room and scope. Search returns relevant excerpts and explicitly describes its incomplete coverage; it does not replace a full-period read. The default budget is 64 model calls, including planning, batch notes, answer generation, and grounding checks. Structured preparation uses JSON Schema by default and retries a malformed model result once at the affected stage. All final answers, including plain-text model responses, pass a separate semantic grounding check with up to two correction attempts. This reduces unsupported claims but is not a proof of factual correctness.

Source IDs remain private verification metadata. User-visible replies have no citation footers or evidence timestamps. Requested event chronology and useful URLs can still appear in the answer. Incomplete source synchronization keeps coverage incomplete even after every stored message is read, and answers must disclose that gap. Coverage counts, selected time bounds, tool names, and completion state are observable without recording message bodies or credentials in service logs.

`fetch_url` reads public HTTP(S) links and returns a title, text, final URL, and truncation flag. It supports UTF-8 HTML, plain text, and JSON without running JavaScript. Each fetch allows 10 seconds, 2 MiB of downloaded content, 20,000 characters of text, and five redirects. Every destination's resolved addresses must be public; the connection uses a checked IP directly while retaining the hostname for HTTP and TLS. Loopback, private, link-local, and Tailscale addresses are blocked, including through redirects. Web content is treated as reference material, and answers using it should include the source URL.

`daily_budget_tokens` reserves request UTF-8 bytes plus the output allowance before each OpenRouter call. Failed calls count too. This conservative limit is not a billing total. Retention, request expiry, cooldowns, and retry limits bound stored data and work.

Reply length follows the request: simple answers can be short, while explanations and timelines can use multiple paragraphs. The default output allowance is 4,000 tokens plus the reasoning budget. Sent replies allow 12,000 UTF-8 bytes, with space reserved for the requester label. Answer validation and follow-up context use this configured limit.

## Validation record

PC and Galaxy SM-F711N (Android 15) runs covered the domain, SQLite, HTTP, summaries, and mock pipeline. Checks included all invocation paths, more than 200 recovered messages, cursor recovery after a failed page, room isolation, embedding reuse, deletion reconciliation, dry-run protection, and delivery confirmation races.

The phone ran native OCaml 5.4.1 binaries built with NDK r29 for Android API 26, with `LD_PRELOAD` and `LD_LIBRARY_PATH` unset. HTTPS to OpenRouter's public model list passed with Mozilla CA verification enabled. The earlier Unix-only HTTP smoke test also covered GET, Korean JSON POST, and 404 responses.

Deployment, repeated deployment, configuration preservation, duplicate process prevention, child restart, and clean shutdown were checked. An empty asko database was backed up to the PC with matching hashes and SQLite integrity intact. Synthetic data tests covered snapshot consistency and refusal to overwrite files. No real KakaoTalk database was copied.

Qwen's JSON mode, configuration-file keys, environment-key precedence, and strict-schema compatibility passed mock tests on PC and phone. The later Jina change received a build check and one real on-phone embedding request, which returned 768 dimensions. The full regression suite was not rerun for the Jina or alias-removal changes.

Iris v0.32 now starts from the original APK in a private mount namespace. The bot ID was read from Iris and saved to both phone and local configuration; the authenticated callback points to asko. SSH root capabilities were restored by removing the launcher's explicit capability drop.

The conversational path passed a mock tool-call run covering source retrieval, a follow-up to a bot reply, room isolation, and original evidence restoration.

Focused checks cover unrelated edits and expiry, nickname updates, in-flight embedding writes, dependent answer requeueing, and a notice after source retries are exhausted.

Nicknames are tracked per room and user ID. Room profile refreshes update current names while observed old names remain available as aliases. Names are filled in before indexing or model context is built. The agent can look up participants by name and filter history by speaker ID; duplicate names remain separate identities. General questions can be answered from model knowledge without a history search.

## Remaining checks

Basic test-room ingestion and live replies have been observed. Broader conversational quality and phone sleep, reboot, and network transitions need further live use. The backend boot installer is prepared but has not been installed or tested across a reboot. Setup scripts ran against an existing dependency cache; a clean-machine installation has not been repeated.

Live send tests use a designated test room. API keys and conversations stay out of Git.

### Request limits and diagnostics

`max_input_bytes` defaults to 1,000,000 bytes per serialized model request
(including prompts, tools, and accumulated tool results). `max_history_bytes`
defaults to 8,000,000 bytes when loading room history. These are byte limits, not
model token limits; the provider's context limit still applies. Their configuration
ceilings remain 2,000,000 and 16,000,000 bytes respectively.

`max_tool_rounds` is configurable from 1 to 64 and defaults to 64 model calls per
conversation, including context planning, batch notes, and grounding checks. The overall `request_ttl` (300 seconds)
and daily usage budget still apply. Existing explicit configuration values take
precedence over the new defaults. On Android, edit `~/asko/config.local.json` and
restart the service to apply overrides; deployment preserves this file.

Failed requests return a JSON diagnostic with `code`, `job_id`, `attempt`, model,
and timeout settings. The server logs the same diagnostic with a `retry` flag.
Limit failures additionally include `resource`, `actual`, and `limit`; history
loading stops at the cap, so its unknown total is represented by `actual: null`.
Daily-budget `actual` is the existing conservative reservation plus the attempted
request, not an invoice or an exact token count. HTTP failures include their status;
request deadlines and exhausted tool rounds have distinct codes. Internal failures
report the exception class; invalid model output includes its validation stage and
reason. Source-edit races and incomplete recovery also expose
specific codes. Terminal diagnostics receive a 60-second delivery grace period.

Diagnostics deliberately omit credentials, raw request/response bodies, and
exception arguments, which can contain chat text or secrets. Forward the diagnostic
JSON when reporting a failure.

### Iris synchronization diagnostics

A failed history read or edit/deletion reconciliation is retained per room and operation until
that operation succeeds. The next requested reply includes an `[asko diagnostic]` JSON block,
even if a useful partial answer was generated. It contains the request/job ID, error ID,
operation (`recovery` or `reconcile`), stage (`latest`, `page`, `decode_page`, `validate_page`,
`watermark`, or `wait_lock`), endpoint, HTTP status when present, timeout setting, measured
elapsed time, cursor, target sequence, page number, processed count, and observation time.
The same error ID appears in `service.log`. Background errors are attached to requested replies,
not posted as unsolicited periodic messages.

A request deadline while waiting for the synchronization lock is reported as
`iris_sync_deadline_exceeded` with `stage=wait_lock`, not as an HTTP timeout. Long answers
reserve space for complete diagnostics; unusually small reply limits retain a compact error ID
for log lookup. Error delivery does not wait for another Iris nickname lookup. Credentials,
SQL bindings, and message contents are excluded. If Iris cannot send at all, diagnostics remain
in the service log; using Iris for delivery cannot bypass an Iris outage.

### Timing and API usage

The service writes structured JSONL to `telemetry_path` (default
`var/telemetry.jsonl`, relative to the config file). Set it to `""` to disable.
`telemetry_max_bytes` defaults to 10 MiB per file and `telemetry_backups` to 3;
rotation retains the current file plus `.1` through `.3`. Files are mode 0600,
with a shared lock for service, replay and backfill writers. Logging failures do
not cause an answer to be retried. Protect these files as operational metadata:
they contain room IDs, job IDs, request sequence numbers, and provider generation IDs.
They omit chat text, model prompts/answers, tool arguments, SQL bindings and credentials.

Each job attempt has a `trace_id`, `job_id`, `request_seq`, and `attempt`.
`span_start`/`span_end` pair by trace and span ID, with `parent_span_id` for
nested and parallel work. Durations use CLOCK_MONOTONIC; UTC `at` timestamps
allow correlation with service logs. Spans cover Iris lock wait/HTTP requests,
history loading, context planning, full-history notes, chunk building, vector
cache reads/writes, query/document embeddings, ranking, tools, answer generation,
grounding audit and outbox enqueue. `model_request` includes model, request
bytes, provider generation ID, tokens and API-reported cost when available.
Missing usage/cost is null, not zero; failed and cancelled calls may still incur
charges. This is separate from the conservative daily token reservation.

`kind=job` measures one processing attempt, excluding queue wait and delivery.
`queue_ms` measures time since its scheduled availability, while
`request_age_ms` includes elapsed time since creation. `job_outcome.state`
records the persisted job state (the trace itself can complete successfully
while handling a job failure). Delivery has a separate trace sharing `job_id`;
`delivery_attempt.queue_to_send_ms` measures creation to the start of Iris send,
and `delivery_confirmed.since_send_ms` measures until the bot echo is observed.
These wall-clock differences can be affected by system clock changes.
Background recovery/reconciliation, replay and backfill have separate kinds.

Run `python3 scripts/telemetry-report.py path/to/telemetry.jsonl*` for completed
job spans, mean/p50/p95/max duration, errors/cancellations, and API cost subtotals.
Use `--job-id 123` to inspect one job or `--kind all` to include background work,
delivery and offline commands. The report deduplicates overlapping input files,
skips malformed lines, and lists unknown cost counts. Nested and concurrent span
durations overlap: never add the stage means to estimate end-to-end latency.
Only completed spans contribute to aggregates; a killed process can leave an
unmatched start event, so inspect raw logs when investigating a crash.
