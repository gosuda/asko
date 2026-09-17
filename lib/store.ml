open Types

exception Error of string
exception Stale_snapshot
exception History_too_large
type t = { db : Sqlite3.db }
type job = { id : int64; invocation : invocation; attempts : int; expires_at : float }
type enqueue_result = Queued of int64 | Duplicate | Stale | Rate_limited
type outgoing = {
  id : int64; job_id : int64; source : string; room_id : string;
  body : string; state : string; floor_seq : int64 option; attempted_at : float option;
  snapshot_version : int option;
  evidence : string option;
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
      | 1 | 2 | 3 -> ()
      | _ -> raise (Error "database schema is newer than this program"));
     if count t "PRAGMA user_version" [] = 1 then
       transaction t (fun () -> exec t "ALTER TABLE outbox ADD COLUMN snapshot_version INTEGER; PRAGMA user_version=2");
     if count t "PRAGMA user_version" [] = 2 then
       transaction t (fun () -> exec t "ALTER TABLE outbox ADD COLUMN evidence TEXT; PRAGMA user_version=3");
     exec t "CREATE INDEX IF NOT EXISTS messages_retention ON messages(created_at)";
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
  run t "DELETE FROM embeddings WHERE source=? AND room_id=?" [text source; text room];
  run t {|UPDATE jobs SET state='failed',last_error='source_changed' WHERE id IN
    (SELECT job_id FROM outbox WHERE source=? AND room_id=? AND snapshot_version IS NOT NULL AND state='pending')|}
    [text source; text room];
  run t {|UPDATE outbox SET body='',evidence=NULL,state=CASE WHEN state='pending' THEN 'cancelled' ELSE state END
    WHERE source=? AND room_id=? AND snapshot_version IS NOT NULL|} [text source; text room]

let room_version t ~source ~room =
  count t "SELECT version FROM rooms WHERE source=? AND room_id=?" [text source; text room]

let put_message t ~is_command (message : message) =
  let message=if message.deleted then {message with text=""} else message in
  let old = get_message t ~source:message.source ~seq:message.seq in
  (match old with
   | Some old when old.room_id <> message.room_id || old.sender_id <> message.sender_id
                   || (match old.native_id,message.native_id with Some a,Some b -> a<>b | _ -> false) ->
       raise (Error "source sequence collision; verify source generation")
   | _ -> ());
  let old_command = one t "SELECT is_command FROM messages WHERE source=? AND seq=?"
      [text message.source; integer message.seq] (fun s -> Sqlite3.column_bool s 0) in
  let is_command=is_command || old_command=Some true in
  if (match old with Some old -> old.deleted && not message.deleted | None->false) then false else begin
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
    run t "INSERT INTO rooms VALUES(?,?,0) ON CONFLICT(source,room_id) DO NOTHING"
      [text message.source; text message.room_id];
    if old <> None then begin
      run t "UPDATE rooms SET version=version+1 WHERE source=? AND room_id=?" [text message.source; text message.room_id];
      invalidate_embeddings t ~source:message.source ~room:message.room_id
    end
  end;
  old = None
  end

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

let messages ?(max_bytes=2000000) t (range : range) =
  let lower_sql, lower_arg = match range.lower with
    | At_time at -> "created_at>=?", real at
    | After_message seq -> "seq>?", integer seq
    | From_message seq -> "seq>=?", integer seq in
  let where = {| FROM messages WHERE source=? AND room_id=?
    AND seq<? AND created_at<=? AND created_at>=? AND is_bot=0 AND deleted=0 AND is_command=0
    AND |} ^ lower_sql in
  let values=[text range.source; text range.room_id; integer range.before_seq; real range.through_time;
     real range.retention_start; lower_arg] in
  let size = one t ("SELECT COALESCE(SUM(LENGTH(CAST(text AS BLOB))),0),COUNT(*)" ^ where) values
      (fun stmt -> Sqlite3.column_int64 stmt 0, Sqlite3.column_int stmt 1) |> Option.get in
  if fst size > Int64.of_int max_bytes || snd size > 50000 then raise History_too_large;
  rows t ("SELECT " ^ message_columns ^ where ^ " ORDER BY seq ASC") values message_row

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
  else if count t "SELECT COUNT(*) FROM jobs WHERE state IN ('queued','running','awaiting_send')" [] >= 100
  then Rate_limited
  else begin
    let previous=one t {|SELECT MAX(j.available_at) FROM jobs j JOIN messages m
      ON m.source=j.source AND m.seq=j.request_seq WHERE j.source=? AND m.room_id=?
      AND m.sender_id=? AND j.state NOT IN ('failed','expired')|}
      [text message.source;text message.room_id;text message.sender_id]
      (fun s->optional_float s 0) |> Option.join in
    let available_at=match previous with
      | None->now
      | Some at->max now (min (at+.config.cooldown) (now+.config.request_ttl/.2.)) in
    run t {|INSERT INTO jobs(source,request_seq,trigger,prompt,created_at,available_at,expires_at)
      VALUES(?,?,?,?,?,?,?)|}
      [text message.source; integer message.seq; text (trigger_name invocation.trigger); text invocation.prompt;
       real now; real available_at; real (now +. config.request_ttl)];
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

let finish_job t job ~body ~dry_run ~snapshot_version ~evidence = transaction t (fun () ->
  let message = job.invocation.message in
  (match snapshot_version with
   | Some expected when expected <> room_version t ~source:message.source ~room:message.room_id -> raise Stale_snapshot
   | _ -> ());
  run t "INSERT INTO outbox(job_id,source,room_id,body,state,snapshot_version,evidence) VALUES(?,?,?,?,?,?,?) ON CONFLICT(job_id) DO NOTHING"
    [integer job.id; text message.source; text message.room_id; text body; text (if dry_run then "dry_run" else "pending");
     (match snapshot_version with None->Sqlite3.Data.NULL | Some value->integer (Int64.of_int value));
     opt_text (Option.map Json_util.to_string evidence)];
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
  snapshot_version=(if Sqlite3.column_is_null stmt 8 then None else Some (Sqlite3.column_int stmt 8));
  evidence=optional_text stmt 9;
}
let outgoing_columns = "id,job_id,source,room_id,body,state,floor_seq,attempted_at,snapshot_version,evidence"

let answer_reference t (request:message) (anchor:message option) =
  let result s=Sqlite3.column_text s 0,optional_text s 1 in
  match anchor with
  | Some m when m.is_bot && m.text<>"" && is_before m request ->
      one t {|SELECT o.body,o.evidence FROM outbox o JOIN jobs j ON j.id=o.job_id
        WHERE o.source=? AND o.room_id=? AND o.body=? AND o.state='sent'
        AND o.floor_seq<? AND j.request_seq<? ORDER BY o.floor_seq DESC LIMIT 1|}
        [text request.source;text request.room_id;text m.text;integer m.seq;integer m.seq] result
  | Some _ -> None
  | None when request.reply_to=None ->
      one t {|SELECT o.body,o.evidence FROM outbox o JOIN jobs j ON j.id=o.job_id
        JOIN messages m ON m.source=j.source AND m.seq=j.request_seq
        WHERE o.source=? AND o.room_id=? AND m.sender_id=? AND j.request_seq<?
        AND m.created_at<=? AND o.state='sent' AND o.body<>'' ORDER BY j.request_seq DESC LIMIT 1|}
        [text request.source;text request.room_id;text request.sender_id;integer request.seq;real request.created_at] result
  | None -> None

let reference_messages t range reference =
  match reference with
  | Some (_,Some evidence) ->
      (match Json_util.protect (fun () -> Yojson.Safe.from_string evidence
        |> Json_util.required "selected_ids" |> Json_util.list (fun value ->
          match Int64.of_string_opt (Json_util.id value) with Some id->id | None->Json_util.invalid "invalid source ID")) with
       | Error _ -> []
       | Ok ids -> ids |> List.sort_uniq Int64.compare
           |> List.filter_map (fun seq->get_message t ~source:range.source ~seq)
           |> List.filter (in_range range))
  | _ -> []
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
  run t "UPDATE outbox SET state=?,error=? WHERE id=? AND state NOT IN ('sent','failed','expired','dry_run','cancelled')"
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

let put_embedding t ~source ~room ~key ~model ~content ~at ~version vector =
  if room_version t ~source ~room <> version then raise Stale_snapshot;
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
  List.iter (fun (source, room) ->
    run t "UPDATE rooms SET version=version+1 WHERE source=? AND room_id=?" [text source; text room];
    invalidate_embeddings t ~source ~room) changed;
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

let last_send_at t = one t "SELECT MAX(attempted_at) FROM outbox" [] (fun s -> optional_float s 0) |> Option.join |> Option.value ~default:0.

let mark_missing t ~source ~room ~since ~through seen = transaction t (fun () ->
  let candidates=rows t ("SELECT " ^ message_columns ^ ",is_command FROM messages WHERE source=? AND room_id=? AND created_at>=? AND seq<=? AND deleted=0")
      [text source;text room;real since;integer through] (fun s->message_row s,Sqlite3.column_bool s 12) in
  List.iter (fun ((message:message),is_command) ->
    if not (Hashtbl.mem seen message.seq) then
      ignore (put_message t ~is_command {message with text="";deleted=true})) candidates)

let backup t destination =
  mkdir (Filename.dirname destination);
  let fd=Unix.openfile destination [Unix.O_CREAT;Unix.O_EXCL;Unix.O_WRONLY;Unix.O_CLOEXEC] 0o600 in
  Unix.close fd;
  try run t "VACUUM INTO ?" [text destination]
  with exn -> (try Sys.remove destination with Sys_error _->()); raise exn
