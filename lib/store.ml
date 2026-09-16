open Types

exception Error of string
type t = { db : Sqlite3.db }
type job = { id : int64; invocation : invocation; attempts : int; expires_at : float }
type enqueue_result = Queued of int64 | Duplicate | Stale | Rate_limited
type outgoing = {
  id : int64; job_id : int64; source : string; room_id : string;
  body : string; state : string; floor_seq : int64 option; attempted_at : float option;
}

let text x = Sqlite3.Data.TEXT x
let integer x = Sqlite3.Data.INT x
let real x = Sqlite3.Data.FLOAT x
let boolean x = integer (if x then 1L else 0L)
let opt_text = function None -> Sqlite3.Data.NULL | Some x -> text x
let check rc = match rc with Sqlite3.Rc.OK | Sqlite3.Rc.DONE -> ()
  | _ -> raise (Error (Sqlite3.Rc.to_string rc))
let exec t sql = check (Sqlite3.exec t.db sql)
let statement t sql values f =
  let stmt = Sqlite3.prepare t.db sql in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    check (Sqlite3.bind_values stmt values); f stmt)
let run t sql values = statement t sql values (fun stmt -> check (Sqlite3.step stmt))
let rows t sql values decode = statement t sql values (fun stmt ->
  let rec loop acc = match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> loop (decode stmt :: acc)
    | Sqlite3.Rc.DONE -> List.rev acc
    | rc -> check rc; assert false
  in loop [])
let one t sql values decode = match rows t sql values decode with [] -> None | value :: _ -> Some value
let count t sql values = one t sql values (fun stmt -> Sqlite3.column_int stmt 0) |> Option.value ~default:0
let transaction t f =
  exec t "BEGIN IMMEDIATE";
  match f () with
  | value -> exec t "COMMIT"; value
  | exception exn -> (try exec t "ROLLBACK" with _ -> ()); raise exn

let rec mkdir path =
  if path <> "." && not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)

let schema = {|
CREATE TABLE messages (
 source TEXT NOT NULL, seq INTEGER NOT NULL, native_id TEXT, room_id TEXT NOT NULL,
 sender_id TEXT NOT NULL, sender_name TEXT NOT NULL, created_at REAL NOT NULL,
 text TEXT NOT NULL, reply_to TEXT, mentions TEXT NOT NULL,
 is_bot INTEGER NOT NULL, deleted INTEGER NOT NULL, is_command INTEGER NOT NULL,
 PRIMARY KEY(source, seq)
);
CREATE INDEX messages_range ON messages(source, room_id, seq, created_at);
CREATE INDEX messages_sender ON messages(source, room_id, sender_id, seq);
CREATE INDEX messages_native ON messages(source, room_id, native_id);
CREATE TABLE rooms (
 source TEXT NOT NULL, room_id TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(source, room_id)
);
CREATE TABLE recovery (
 source TEXT NOT NULL, room_id TEXT NOT NULL, cursor INTEGER NOT NULL DEFAULT 0,
 complete_at REAL, coverage_start REAL, PRIMARY KEY(source, room_id)
);
CREATE TABLE jobs (
 id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, request_seq INTEGER NOT NULL,
 trigger TEXT NOT NULL, prompt TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'queued',
 attempts INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, available_at REAL NOT NULL,
 expires_at REAL NOT NULL, last_error TEXT,
 UNIQUE(source, request_seq),
 FOREIGN KEY(source, request_seq) REFERENCES messages(source, seq) ON DELETE CASCADE
);
CREATE INDEX jobs_pending ON jobs(state, available_at, id);
CREATE TABLE outbox (
 id INTEGER PRIMARY KEY AUTOINCREMENT, job_id INTEGER NOT NULL UNIQUE,
 source TEXT NOT NULL, room_id TEXT NOT NULL, body TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending', floor_seq INTEGER, attempted_at REAL, error TEXT,
 FOREIGN KEY(job_id) REFERENCES jobs(id) ON DELETE CASCADE
);
CREATE TABLE embeddings (
 source TEXT NOT NULL, room_id TEXT NOT NULL, cache_key TEXT NOT NULL, model TEXT NOT NULL,
 content TEXT NOT NULL, vector TEXT NOT NULL, created_at REAL NOT NULL,
 PRIMARY KEY(source, room_id, cache_key, model)
);
CREATE TABLE usage (day INTEGER PRIMARY KEY, tokens INTEGER NOT NULL DEFAULT 0);
PRAGMA user_version=1;
|}

let open_ path =
  mkdir (Filename.dirname path);
  let t = {db=Sqlite3.db_open path} in
  (try
     Sqlite3.busy_timeout t.db 1000;
     exec t "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL";
     (match count t "PRAGMA user_version" [] with
      | 0 -> transaction t (fun () -> exec t schema)
      | 1 -> ()
      | _ -> raise (Error "database schema is newer than this program"));
     t
   with exn -> ignore (Sqlite3.db_close t.db); raise exn)
let close t = ignore (Sqlite3.db_close t.db)
let optional_text stmt col = if Sqlite3.column_is_null stmt col then None else Some (Sqlite3.column_text stmt col)
let optional_int64 stmt col = if Sqlite3.column_is_null stmt col then None else Some (Sqlite3.column_int64 stmt col)
let optional_float stmt col = if Sqlite3.column_is_null stmt col then None else Some (Sqlite3.column_double stmt col)
let message_columns = "source,seq,native_id,room_id,sender_id,sender_name,created_at,text,reply_to,mentions,is_bot,deleted"
let message_row stmt : message = {
  source=Sqlite3.column_text stmt 0; seq=Sqlite3.column_int64 stmt 1;
  native_id=optional_text stmt 2; room_id=Sqlite3.column_text stmt 3;
  sender_id=Sqlite3.column_text stmt 4; sender_name=Sqlite3.column_text stmt 5;
  created_at=Sqlite3.column_double stmt 6; text=Sqlite3.column_text stmt 7;
  reply_to=optional_text stmt 8;
  mentions=Json_util.list Json_util.string (Yojson.Safe.from_string (Sqlite3.column_text stmt 9));
  is_bot=Sqlite3.column_bool stmt 10; deleted=Sqlite3.column_bool stmt 11;
}
let get_message t ~source ~seq =
  one t ("SELECT " ^ message_columns ^ " FROM messages WHERE source=? AND seq=?")
    [text source; integer seq] message_row

let invalidate_embeddings t ~source ~room =
  run t "DELETE FROM embeddings WHERE source=? AND room_id=?" [text source; text room]

let put_message t ~is_command (message : message) =
  let old = get_message t ~source:message.source ~seq:message.seq in
  (match old with
   | Some old when old.room_id <> message.room_id || old.sender_id <> message.sender_id ->
       raise (Error "source sequence collision; verify source generation")
   | _ -> ());
  let old_command = one t "SELECT is_command FROM messages WHERE source=? AND seq=?"
      [text message.source; integer message.seq] (fun s -> Sqlite3.column_bool s 0) in
  if old <> Some message || old_command <> Some is_command then begin
    run t {|INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(source,seq) DO UPDATE SET native_id=excluded.native_id,
      sender_name=excluded.sender_name,created_at=excluded.created_at,text=excluded.text,
      reply_to=excluded.reply_to,mentions=excluded.mentions,is_bot=excluded.is_bot,
      deleted=excluded.deleted,is_command=excluded.is_command|}
      [text message.source; integer message.seq; opt_text message.native_id; text message.room_id;
       text message.sender_id; text message.sender_name; real message.created_at; text message.text;
       opt_text message.reply_to; text (Json_util.to_string (`List (List.map (fun x -> `String x) message.mentions)));
       boolean message.is_bot; boolean message.deleted; boolean is_command];
    run t "INSERT INTO rooms VALUES(?,?,1) ON CONFLICT(source,room_id) DO UPDATE SET version=version+1"
      [text message.source; text message.room_id];
    if old <> None then invalidate_embeddings t ~source:message.source ~room:message.room_id
  end;
  old = None

let previous t (request : message) =
  one t ("SELECT " ^ message_columns ^ {| FROM messages WHERE source=? AND room_id=?
    AND sender_id=? AND seq<? AND created_at<=? AND is_bot=0 AND deleted=0 AND is_command=0
    ORDER BY seq DESC LIMIT 1|})
    [text request.source; text request.room_id; text request.sender_id; integer request.seq; real request.created_at]
    message_row

let anchor t (request : message) = match request.reply_to with
  | None -> None
  | Some native_id ->
      (match rows t ("SELECT " ^ message_columns ^ {| FROM messages WHERE source=? AND room_id=?
        AND native_id=? AND seq<? AND created_at<=? AND deleted=0 ORDER BY seq DESC LIMIT 2|})
        [text request.source; text request.room_id; text native_id; integer request.seq; real request.created_at] message_row with
       | [message] -> Some message
       | _ -> None)

let messages t (range : range) =
  let lower_sql, lower_arg = match range.lower with
    | At_time at -> "created_at>=?", real at
    | After_message seq -> "seq>?", integer seq
    | From_message seq -> "seq>=?", integer seq in
  rows t ("SELECT " ^ message_columns ^ {| FROM messages WHERE source=? AND room_id=?
    AND seq<? AND created_at<=? AND created_at>=? AND is_bot=0 AND deleted=0 AND is_command=0
    AND |} ^ lower_sql ^ " ORDER BY seq ASC")
    [text range.source; text range.room_id; integer range.before_seq; real range.through_time;
     real range.retention_start; lower_arg] message_row

let cursor t ~source ~room =
  one t "SELECT cursor FROM recovery WHERE source=? AND room_id=?" [text source; text room]
    (fun s -> Sqlite3.column_int64 s 0) |> Option.value ~default:0L
let save_cursor t ~source ~room ~cursor ~at ~coverage_start =
  run t {|INSERT INTO recovery VALUES(?,?,?,?,?) ON CONFLICT(source,room_id) DO UPDATE SET
    cursor=MAX(recovery.cursor,excluded.cursor),complete_at=excluded.complete_at,
    coverage_start=COALESCE(recovery.coverage_start,excluded.coverage_start)|}
    [text source; text room; integer cursor; real at;
     (match coverage_start with None -> Sqlite3.Data.NULL | Some at -> real at)]
let coverage_start t ~source ~room =
  one t "SELECT MIN(created_at) FROM messages WHERE source=? AND room_id=?"
    [text source; text room] (fun s -> optional_float s 0) |> Option.join

let enqueue t ~now ~(config : Config.t) (invocation : invocation) =
  let message = invocation.message in
  if count t "SELECT COUNT(*) FROM jobs WHERE source=? AND request_seq=?" [text message.source; integer message.seq] > 0
  then Duplicate
  else if message.created_at < now -. config.request_ttl || message.created_at > now +. 60. then Stale
  else if count t {|SELECT COUNT(*) FROM jobs j JOIN messages m ON m.source=j.source AND m.seq=j.request_seq
    WHERE j.source=? AND m.room_id=? AND m.sender_id=? AND j.created_at>?
    AND j.state NOT IN ('failed','expired')|}
      [text message.source; text message.room_id; text message.sender_id; real (now -. config.cooldown)] > 0
    || count t "SELECT COUNT(*) FROM jobs WHERE state IN ('queued','running','awaiting_send')" [] >= 100
  then Rate_limited
  else begin
    run t {|INSERT INTO jobs(source,request_seq,trigger,prompt,created_at,available_at,expires_at)
      VALUES(?,?,?,?,?,?,?)|}
      [text message.source; integer message.seq; text (trigger_name invocation.trigger); text invocation.prompt;
       real now; real now; real (now +. config.request_ttl)];
    Queued (Sqlite3.last_insert_rowid t.db)
  end

let claim_job t ~now = transaction t (fun () ->
  run t "UPDATE jobs SET state='expired' WHERE state='queued' AND expires_at<=?" [real now];
  match one t {|SELECT id,source,request_seq,trigger,prompt,attempts,expires_at FROM jobs
    WHERE state='queued' AND available_at<=? ORDER BY id LIMIT 1|} [real now]
    (fun s -> (Sqlite3.column_int64 s 0, Sqlite3.column_text s 1, Sqlite3.column_int64 s 2,
               Sqlite3.column_text s 3, Sqlite3.column_text s 4, Sqlite3.column_int s 5, Sqlite3.column_double s 6)) with
  | None -> None
  | Some (id, source, seq, trigger, prompt, attempts, expires_at) ->
      let message = Option.get (get_message t ~source ~seq) in
      let trigger = match trigger with "mention" -> Mention | "reply" -> Reply | _ -> Slash in
      run t "UPDATE jobs SET state='running',attempts=attempts+1 WHERE id=?" [integer id];
      Some {id; invocation={message; trigger; prompt}; attempts=attempts+1; expires_at})

let recover_jobs t ~now = transaction t (fun () ->
  run t "UPDATE jobs SET state='queued',available_at=? WHERE state='running' AND attempts<3 AND expires_at>?" [real now; real now];
  exec t "UPDATE jobs SET state='failed',last_error='restart_retry_limit' WHERE state='running'";
  exec t "UPDATE outbox SET state='uncertain',error='process_restarted_during_send' WHERE state='sending'";
  exec t "UPDATE jobs SET state='uncertain' WHERE id IN (SELECT job_id FROM outbox WHERE state='uncertain')")

let finish_job t job ~body ~dry_run = transaction t (fun () ->
  let message = job.invocation.message in
  run t "INSERT INTO outbox(job_id,source,room_id,body,state) VALUES(?,?,?,?,?) ON CONFLICT(job_id) DO NOTHING"
    [integer job.id; text message.source; text message.room_id; text body; text (if dry_run then "dry_run" else "pending")];
  run t "UPDATE jobs SET state=? WHERE id=?" [text (if dry_run then "completed" else "awaiting_send"); integer job.id])

let fail_job t job ~now ~retry ~reason =
  let retry = retry && job.attempts < 3 && now +. 5. < job.expires_at in
  run t "UPDATE jobs SET state=?,available_at=?,last_error=? WHERE id=?"
    [text (if retry then "queued" else "failed"); real (now +. float_of_int (job.attempts * 3)); text reason; integer job.id]

let outgoing_row stmt = {
  id=Sqlite3.column_int64 stmt 0; job_id=Sqlite3.column_int64 stmt 1;
  source=Sqlite3.column_text stmt 2; room_id=Sqlite3.column_text stmt 3;
  body=Sqlite3.column_text stmt 4; state=Sqlite3.column_text stmt 5;
  floor_seq=optional_int64 stmt 6; attempted_at=optional_float stmt 7;
}
let outgoing_columns = "id,job_id,source,room_id,body,state,floor_seq,attempted_at"
let next_outgoing t ~now =
  run t {|UPDATE outbox SET state='expired' WHERE state='pending'
    AND job_id IN (SELECT id FROM jobs WHERE expires_at<=?)|} [real now];
  exec t "UPDATE jobs SET state='expired' WHERE id IN (SELECT job_id FROM outbox WHERE state='expired')";
  one t ("SELECT " ^ outgoing_columns ^ " FROM outbox WHERE state IN ('pending','awaiting_echo') ORDER BY id LIMIT 1") [] outgoing_row

let begin_send t outgoing ~floor_seq ~now =
  run t "UPDATE outbox SET state='sending',floor_seq=?,attempted_at=? WHERE id=? AND state='pending'"
    [integer floor_seq; real now; integer outgoing.id];
  Sqlite3.changes t.db = 1

let outgoing_state t outgoing ~state ?error () = transaction t (fun () ->
  run t "UPDATE outbox SET state=?,error=? WHERE id=? AND state NOT IN ('sent','failed','expired','dry_run')"
    [text state; opt_text error; integer outgoing.id];
  let changed = Sqlite3.changes t.db > 0 in
  let job_state = match state with
    | "sent" -> "completed"
    | "uncertain" -> "uncertain"
    | "failed" -> "failed"
    | _ -> "awaiting_send" in
  if changed then run t "UPDATE jobs SET state=?,last_error=? WHERE id=?"
      [text job_state; opt_text error; integer outgoing.job_id])

let confirm_message t (message : message) =
  if message.is_bot then
    match rows t ("SELECT " ^ outgoing_columns ^ {| FROM outbox WHERE source=? AND room_id=?
      AND body=? AND state IN ('sending','awaiting_echo','uncertain') AND floor_seq<?|})
      [text message.source; text message.room_id; text message.text; integer message.seq] outgoing_row with
    | [outgoing] ->
        (* Called from ingestion's transaction; do not open a nested transaction. *)
        run t "UPDATE outbox SET state='sent',error=NULL WHERE id=?" [integer outgoing.id];
        run t "UPDATE jobs SET state='completed',last_error=NULL WHERE id=?" [integer outgoing.job_id]
    | _ -> ()

let get_embedding t ~source ~room ~key ~model ~content =
  match one t "SELECT content,vector FROM embeddings WHERE source=? AND room_id=? AND cache_key=? AND model=?"
    [text source; text room; text key; text model]
    (fun s -> Sqlite3.column_text s 0, Sqlite3.column_text s 1) with
  | Some (stored, vector) when stored = content ->
      (match Json_util.protect (fun () -> Json_util.list Json_util.float (Yojson.Safe.from_string vector)) with
       | Ok values -> Some (Array.of_list values)
       | Error _ -> None)
  | _ -> None

let put_embedding t ~source ~room ~key ~model ~content ~at vector =
  if Array.length vector = 0 || not (Array.for_all Float.is_finite vector) then raise (Error "invalid embedding");
  let data = `List (Array.to_list (Array.map (fun value -> `Float value) vector)) in
  run t {|INSERT INTO embeddings VALUES(?,?,?,?,?,?,?) ON CONFLICT(source,room_id,cache_key,model)
    DO UPDATE SET content=excluded.content,vector=excluded.vector,created_at=excluded.created_at|}
    [text source; text room; text key; text model; text content; text (Json_util.to_string data); real at]

let token_day at = Int64.of_float (floor (at /. 86400.))
let record_tokens t ~at tokens =
  if tokens < 0 then raise (Error "negative token usage");
  run t "INSERT INTO usage VALUES(?,?) ON CONFLICT(day) DO UPDATE SET tokens=tokens+excluded.tokens"
    [integer (token_day at); integer (Int64.of_int tokens)]
let tokens_today t ~at = count t "SELECT tokens FROM usage WHERE day=?" [integer (token_day at)]

let purge t ~before = transaction t (fun () ->
  let changed = rows t "SELECT DISTINCT source,room_id FROM messages WHERE created_at<?" [real before]
      (fun s -> Sqlite3.column_text s 0, Sqlite3.column_text s 1) in
  List.iter (fun (source, room) -> invalidate_embeddings t ~source ~room) changed;
  run t "DELETE FROM messages WHERE created_at<?" [real before];
  run t "DELETE FROM embeddings WHERE created_at<?" [real before];
  List.length changed)

let stats t = `Assoc [
  "messages", `Int (count t "SELECT COUNT(*) FROM messages" []);
  "queued_jobs", `Int (count t "SELECT COUNT(*) FROM jobs WHERE state='queued'" []);
  "running_jobs", `Int (count t "SELECT COUNT(*) FROM jobs WHERE state='running'" []);
  "pending_outbox", `Int (count t "SELECT COUNT(*) FROM outbox WHERE state IN ('pending','sending','awaiting_echo')" []);
  "uncertain_outbox", `Int (count t "SELECT COUNT(*) FROM outbox WHERE state='uncertain'" []);
]

let recent_outbox t = rows t ("SELECT " ^ outgoing_columns ^ " FROM outbox ORDER BY id DESC LIMIT 20") [] outgoing_row
