# Implementation notes

## Runtime

Iris, the OCaml backend, and SQLite run on the phone. OpenRouter supplies embeddings and handles the agent's tool loop; local Jina is optional. Cohttp/Lwt provides HTTP and asynchronous workers. The model decides what a request needs: its own knowledge, the room's messages, or the web. OCaml enforces room, retention, and invocation boundaries on every lookup.

Ingestion commits the message and its queued job in one transaction. Backfill resumes from a saved cursor and never executes historical commands. A serialized outbox checks delivery echoes. Interrupted sends remain uncertain until confirmed, preventing blind duplicate sends. Complete source scans reconcile edits and deletions; late events cannot restore deleted text. Active work checks the messages it actually read, including reply context, instead of a room-wide version. Nickname and mention metadata updates do not restart work. Embedding dependencies and answer evidence restrict invalidation to affected data; a changed unsent answer is requeued, and exhausted source retries produce a notice.

Each request goes straight into one tool loop; there is no separate planning call. The first turn carries the request, its KST timestamp, the newest room messages (at most 60, within a byte limit), any reply anchor, and the requester's previous exchange. The model resolves periods against the timestamp and calls `read_period` for period summaries, counts, absence claims, and participant-wide analysis. `read_period` reads every stored original in the interval. An interval that fits the request is returned as originals; a larger one is split into bounded batches, processed with up to three concurrent note requests, and returned as source-linked notes. If the remaining call budget cannot cover the batches, the tool says so and the model narrows the interval; pages are never skipped silently.

An implicit previous exchange must belong to the same requester, have been delivered before the current request, and be at most 30 minutes old. Its question, answer, coverage, and the web pages it used are supplied on the first turn, and the model uses them only when the current request continues that exchange. Explicit replies retain their anchor behavior.

`read_messages`, `read_period`, `search_messages`, and `get_message` expose original records within the room and retention period. Search returns relevant excerpts and explicitly describes its incomplete coverage; it does not replace a full-period read. With `cross_room_read: true`, `read_messages` and `search_messages` also accept the ID of another room in `rooms`; any other ID is refused, and `read_period` stays in the requesting room. The default budget is 96 model calls per job, including batch notes, turns, and grounding checks. When two calls remain, or 90 seconds before the request deadline, the loop offers only `respond` and asks for the best answer so far. A turn truncated by the output limit is retried once with half as much output room again. When the accumulated turns exceed three fifths of `max_input_bytes`, older tool results are reduced to a 600-byte excerpt, oldest first, keeping the newest two whole.

`answer_audit` selects when the separate semantic grounding check runs. The default `room_claims` checks an answer that cites room messages or was produced after any room-reading tool call, with up to two correction attempts; answers from general knowledge or the web skip it. `always` checks every answer and `off` none. The check lists the web pages that were looked up so that web facts are not rejected for being absent from the room. It reduces unsupported claims but is not a proof of factual correctness, and web content itself is not verified.

Source IDs remain private verification metadata. User-visible replies have no citation footers or evidence timestamps. Requested event chronology and useful URLs can still appear in the answer. Incomplete source synchronization keeps coverage incomplete even after every stored message is read, and answers must disclose that gap. Coverage counts, selected time bounds, tool names, and completion state are observable without recording message bodies or credentials in service logs.

`web_search` calls Parallel Search (`POST {search_url}/v1/search`, `x-api-key`) with an objective and up to three queries, and returns up to eight URLs with excerpts. It is offered to the model only when a search key is configured. `fetch_url` reads public HTTP(S) links locally first and returns a title, text, final URL, and truncation flag; `next_offset` continues a long page in 20,000-character pages. The local fetcher supports UTF-8 HTML, plain text, and JSON without running JavaScript, and allows 10 seconds, 2 MiB of downloaded content, and five redirects. Every destination's resolved addresses must be public; the connection uses a checked IP directly while retaining the hostname for HTTP and TLS. Loopback, private, link-local, and Tailscale addresses are blocked, including through redirects. When the local fetch fails for a public URL (HTTP error, unsupported content type or encoding, timeout) and a search key exists, the URL is sent to Parallel Extract (`/v1/extract`, full content capped at 100,000 characters) and the result is cached for the request. Invalid and internal addresses are never forwarded. Web content is treated as reference material, never as instructions, and answers that rely on it end with their source URLs. Web calls have no separate daily cap.

`daily_budget_tokens` reserves request UTF-8 bytes plus the output allowance before each OpenRouter call. Failed calls count too. This conservative limit is not a billing total. Retention, request expiry, cooldowns, and retry limits bound stored data and work.

`job_workers` (default 3, 1 to 8) jobs run at the same time. A requester's jobs in one room stay in order: a queued job waits while an earlier job from the same person in the same room is running. The outbox still sends one message at a time.

A native mention always invokes the bot. With `reply_trigger` (default on), so does a KakaoTalk reply whose quoted message is a stored, undeleted bot message in the same room; the reply text is the request and the quoted bot message is its anchor. A reply to another person's message, an empty reply, and a reply quoting a bot message from another room stay ordinary messages. A job re-checks this before it runs, so deleting the quoted bot message cancels it.

Search no longer builds its index on demand. An `indexer` worker passes over each room every 60 seconds, skips rooms without new messages, and embeds finished chunks; the newest chunk is left until it stops growing, and a search embeds whatever is still missing. Missing chunks are embedded in batches of 16 with up to four remote requests at a time (one for the local model). Decoded vectors stay in memory after the first read and follow the same invalidation as their rows: edits, deletions, and retention remove both. The query vector and the missing chunks are requested together. A search returns the 8 best chunks within 48,000 bytes, and one `read_messages` page is at most 64,000 bytes, which keeps later turns small.

The grounding check sends room records before the request and draft, so the check of a corrected draft can reuse the provider's prompt cache. It also returns a category for a rejection (`unsupported_claim`, `coverage_overclaim`, `wrong_request`, `missing_qualification`, `format`, `other`). The `answer_revision` telemetry event records that category without the issue text.

The model may call `send_progress` to post a short interim line during a long task; nothing forces it. A job gets at most two lines of up to 300 bytes, counted in SQLite across retries. A progress line is sent through Iris directly, after the same bot-identity check and send interval as answers, and is not tracked by the outbox: a lost line is not retried and never delays the answer. In dry-run it is logged and not sent. Schema version 7 adds the counter; earlier binaries cannot open the upgraded database.

Reply length follows the request: simple answers can be short, while explanations and timelines can use multiple paragraphs. The default output allowance is 4,000 tokens plus the reasoning budget. Sent replies allow 12,000 UTF-8 bytes, with space reserved for the requester label. Answer validation and follow-up context use this configured limit.

## Validation record

On 2026-11-18, the agent loop passed all 12 native OCaml test executables and the Python regression cases through `make test` on the Linux host, and the Android binary cross-compiled. Mock runs cover a one-call general answer, a period read across KST midnight, multi-batch notes with cache reuse, the conditional grounding check, Parallel search with the Extract fallback, the closing turn at the end of the call budget, the truncation retry, tool-result compaction, a progress line through the full ingest-to-delivery path, reading another enabled room, and per-requester job ordering. One live Parallel Search and one Extract request through the OCaml client on the Linux host returned eight results and a 27 KB page. No request was sent to a paid model, nothing was run on the phone, and answer quality with a live model is untested.

On 2026-10-29, the onboarding changes passed all 12 native OCaml test executables and 45 Python regression cases through `make test`, using a fresh opam dependency root on the existing Linux host. Coverage includes legacy configuration and provider behavior, agreement between generated presets and checked-in examples, non-overwriting initialization, offline and mock-online diagnostics, room discovery without history import, failed deployment preservation, stale PID recovery, and opt-in boot installation. Shell syntax checks passed for all 25 scripts/templates. The existing local configuration passed validation without modification. These checks made no paid model calls, accessed no phone, and do not establish clean-machine installation or Android reboot compatibility.

On 2026-10-29, the dependency refresh was built in a fresh project-local compiler and opam switch using OCaml 5.5.2, opam 2.6.1, Dune 3.24.2 and NDK r30 (Android API 26). All 11 test executables passed on Linux and the phone, with 454 assertions on each. Native and Android HTTPS probes to OpenRouter's public model list returned HTTP 200 with certificate verification enabled. The Android binary uses SQLite 3.54.1, TLS 2.1.4, Mirage Crypto 2.4.1 and X509 1.2.0. These checks use mock conversation/model data and make no paid model calls. The optional llama.cpp v0.8.0 binary also ran on the phone: synthetic query and document requests each returned 768 finite, unit-normalized embedding values. Repeating native setup completed without package changes.

PC and Galaxy SM-F711N (Android 15) runs covered the domain, SQLite, HTTP, summaries, and mock pipeline. Checks included all invocation paths, more than 200 recovered messages, cursor recovery after a failed page, room isolation, embedding reuse, deletion reconciliation, dry-run protection, and delivery confirmation races.

The phone ran native OCaml 5.4.1 binaries built with NDK r29 for Android API 26, with `LD_PRELOAD` and `LD_LIBRARY_PATH` unset. HTTPS to OpenRouter's public model list passed with Mozilla CA verification enabled. The earlier Unix-only HTTP smoke test also covered GET, Korean JSON POST, and 404 responses.

Deployment, repeated deployment, configuration preservation, duplicate process prevention, child restart, and clean shutdown were checked. An empty asko database was backed up to the PC with matching hashes and SQLite integrity intact. Synthetic data tests covered snapshot consistency and refusal to overwrite files. No real KakaoTalk database was copied.

Qwen's JSON mode, configuration-file keys, environment-key precedence, and strict-schema compatibility passed mock tests on PC and phone. The later Jina change received a build check and one real on-phone embedding request, which returned 768 dimensions. The full regression suite was not rerun for the Jina or alias-removal changes.

Iris v0.32 now starts from the original APK in a private mount namespace. The bot ID was read from Iris and saved to both phone and local configuration; the authenticated callback points to asko. SSH root capabilities were restored by removing the launcher's explicit capability drop.

Iris v0.33-gosuda.1 was installed on the phone on 2026-10-31 with `deploy-iris-phone.sh`. After the restart, `doctor --online` passed, Iris resolved the bot ID and answered traced `/query` requests, and the 224 MB `iris.log` written by the old launcher moved to `iris.log.1` on the first rotation. The installer recorded an automatic backup. `/query` failures reported as HTTP 200 with an `error` field are tested only against mock Iris servers: they are retryable and do not advance recovery cursors. The upgrade, same-build, rollback and failed-start paths of `iris-install-root.sh` are tested on a simulated device tree; rollback has not been run on the phone.

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

`max_tool_rounds` is configurable from 1 to 128 and defaults to 96 chat model calls per
job across all attempts and restarts, including batch notes, turns, and grounding checks.
The overall `request_ttl` (1,800 seconds by default)
and daily usage budget still apply. Existing explicit configuration values take
precedence over the new defaults. On Android, edit `~/asko/config.local.json` and
restart the service to apply overrides; deployment preserves this file.

Context-note batches have at most three attempts each. Validation failures are retried
with the local validation reason and the required schema; original source rows are still
checked strictly. Transient network errors use exponential backoff with jitter;
authentication and other permanent errors stop immediately. Exhausted batches do not
restart the whole job. Successful batches are stored in SQLite and reused within the same
job, including after restart or a later-stage failure. Cache keys include the exact batch,
task, model, endpoint, generation settings, and notes contract. Source edits, deletion,
and retention erase dependent entries; deleting a job cascades its entries too.
The call counter and batch attempt counters are persisted before calls, so an interrupted
request consumes its reserved attempt. Replay commands have an independent in-memory
call budget and do not read or write the live job's notes cache. Schema version 6 adds
this state; earlier binaries cannot open the upgraded database.

A failed request sends the room one short Korean sentence with the error code and job
number, for example `(오류 request_deadline_exceeded, 작업 12)`. The server logs the full JSON
diagnostic with `code`, `job_id`, `attempt`, model, timeout settings, and a `retry` flag;
`failure_detail: "json"` sends that JSON to the room as before.
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
