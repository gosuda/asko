open Lwt.Infix

type progress = {
  operation : string; stage : string; cursor : int64; through : int64 option;
  page : int; processed : int; started_at : float; stage_started_at : float;
}
let start operation cursor =
  let now=Unix.gettimeofday () in
  {operation;stage="wait_lock";cursor;through=None;page=0;processed=0;started_at=now;stage_started_at=now}
let advance p stage cursor through page processed =
  {p with stage;cursor;through;page;processed;stage_started_at=Unix.gettimeofday ()}

let diagnostic ~config ~room ~cause p =
  let now=Unix.gettimeofday () in
  let id="iris-" ^ String.sub (Digest.to_hex(Digest.string
    (Printf.sprintf "%s:%s:%.6f" p.operation room now))) 0 16 in
  let is_http=List.mem p.stage ["latest";"page"] in
  `Assoc ["error_id",`String id;"component",`String "iris";"room_id",`String room;
    "code",`String(if cause="timeout" then "iris_sync_timeout" else
      if cause="request_deadline_exceeded" then "iris_sync_deadline_exceeded" else "iris_sync_failed");
    "cause",`String cause;"operation",`String p.operation;"stage",`String p.stage;
    "http_status",(if String.starts_with ~prefix:"http_" cause then
      match int_of_string_opt(String.sub cause 5 (String.length cause-5)) with Some n->`Int n | None->`Null else `Null);
    "method",(if is_http then `String "POST" else `Null);
    "endpoint",(if is_http then `String "/query" else `Null);
    "http_timeout_seconds",`Float config.Config.http_timeout;
    "stage_elapsed_ms",`Int(max 0 (int_of_float((now-.p.stage_started_at)*.1000.)));
    "sync_elapsed_ms",`Int(max 0 (int_of_float((now-.p.started_at)*.1000.)));
    "cursor",`String(Int64.to_string p.cursor);
    "through",Json_util.option (fun id->`String(Int64.to_string id)) p.through;
    "page",`Int p.page;"processed_messages",`Int p.processed;
    "observed_at",`String(Context_plan.timestamp now)]

let room ?(on_progress=(fun _->())) ~config ~store ~iris ?through room =
  if not (Config.allowed config room) then Lwt.return (Error (Net.Http_status 403)) else
  let now = Unix.gettimeofday () in
  let since = now -. float_of_int (config.Config.retention_days * 86400) in
  let state=ref(start "recovery" (Store.cursor store ~source:config.source_id ~room)) in
  let report stage cursor upper page processed=
    state:=advance !state stage cursor upper page processed;on_progress !state in
  report "latest" (!state).cursor None 0 0;
  Iris.latest iris room >>= function
  | Error error -> Lwt.return (Error error)
  | Ok (latest, coverage_start) ->
      let upper = match through with None -> latest | Some upper -> min upper latest in
      let initial = Store.cursor store ~source:config.source_id ~room in
      if latest < initial then (report "watermark" initial (Some latest) 0 0;Lwt.return (Error Net.Source_changed)) else
      let rec loop after page processed =
        if after >= upper then Lwt.return (Ok ())
        else begin
        report "page" after (Some upper) page processed;
        Iris.page iris ~room ~after ~through:upper ~since >>= function
          | Error error -> Lwt.return (Error error)
          | Ok [] ->
              Store.save_cursor store ~source:config.source_id ~room ~cursor:upper ~at:now ~coverage_start;
              Lwt.return (Ok ())
          | Ok rows ->
              report "decode_page" after (Some upper) page processed;
              let decoded = List.map (Iris_event.of_query_row ~source:config.source_id ~bot_id:config.bot_id) rows in
              if List.exists Result.is_error decoded then Lwt.return (Error Net.Invalid_json)
              else
                let messages = List.map Result.get_ok decoded in
                report "validate_page" after (Some upper) page processed;
                if List.exists (fun (m:Types.message) -> m.room_id <> room || m.seq <= after || m.seq > upper) messages
                then Lwt.return (Error Net.Invalid_json)
                else begin
                  (* Each message is committed before advancing the verified page cursor.
                     Replayed history never creates jobs; duplicate live callbacks still can. *)
                  List.iter (fun m -> ignore (Ingest.apply ~config ~store ~now ~live:false m)) messages;
                  let next = List.fold_left (fun acc (m:Types.message) -> max acc m.seq) after messages in
                  Store.save_cursor store ~source:config.source_id ~room ~cursor:next ~at:now ~coverage_start;
                  Lwt.pause () >>= fun () -> loop next (page+1) (processed+List.length messages)
                end
        end
      in
      loop initial 1 0 >|= fun result ->
      (match result with
       | Ok () -> Store.save_cursor store ~source:config.source_id ~room ~cursor:upper ~at:now ~coverage_start
       | Error _ -> ());
      result

let reconcile ?(on_progress=(fun _->())) ~config ~store ~iris room =
  if not (Config.allowed config room) then Lwt.return (Error (Net.Http_status 403)) else
  let now=Unix.gettimeofday () in
  let since=now -. float_of_int (config.Config.retention_days*86400) in
  let state=ref(start "reconcile" 0L) in
  let report stage cursor upper page processed=
    state:=advance !state stage cursor upper page processed;on_progress !state in
  report "latest" 0L None 0 0;
  Iris.latest iris room >>= function
  | Error error -> Lwt.return (Error error)
  | Ok (upper,_) when upper < Store.cursor store ~source:config.source_id ~room ->
      report "watermark" (Store.cursor store ~source:config.source_id ~room) (Some upper) 0 0;
      Lwt.return (Error Net.Source_changed)
  | Ok (upper,_) ->
      let seen=Hashtbl.create 1024 in
      let rec scan after page processed =
        if after>=upper then Lwt.return (Ok ()) else
        begin
        report "page" after (Some upper) page processed;
        Iris.page iris ~room ~after ~through:upper ~since >>= function
        | Error error -> Lwt.return (Error error)
        | Ok [] -> Lwt.return (Ok ())
        | Ok rows ->
            report "decode_page" after (Some upper) page processed;
            let decoded=List.map (Iris_event.of_query_row ~source:config.source_id ~bot_id:config.bot_id) rows in
            if List.exists Result.is_error decoded then Lwt.return (Error Net.Invalid_json) else
            let messages=List.map Result.get_ok decoded in
            report "validate_page" after (Some upper) page processed;
            if List.exists (fun (m:Types.message)->m.room_id<>room || m.seq<=after || m.seq>upper) messages then
              Lwt.return (Error Net.Invalid_json)
            else begin
              List.iter (fun (m:Types.message)->
                Hashtbl.replace seen m.seq ();
                ignore (Ingest.apply ~config ~store ~now ~live:false m)) messages;
              let next=List.fold_left (fun seq (m:Types.message)->max seq m.seq) after messages in
              Lwt.pause () >>= fun ()->scan next (page+1) (processed+List.length messages)
            end
        end in
      scan 0L 1 0 >|= fun result ->
      (match result with
       | Ok () -> Store.mark_missing store ~source:config.source_id ~room ~since ~through:upper seen
       | Error _ -> ());
      result
