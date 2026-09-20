open Types
open Lwt.Infix
type t = {
  config : Config.t; store : Store.t; iris : Iris.t; llm : Llm.t;
  recovery_lock : Lwt_mutex.t; mutable next_send_at : float;
  name_refresh : (string,float) Hashtbl.t;
  sync_failures : (string,Yojson.Safe.t) Hashtbl.t;
}
let create config store = {
  config; store; iris=Iris.create config; llm=Llm.create config store;
  recovery_lock=Lwt_mutex.create (); name_refresh=Hashtbl.create 8;sync_failures=Hashtbl.create 8; next_send_at=Store.last_send_at store +. config.Config.send_interval;
}
let log event code =
  prerr_endline (Json_util.to_string (`Assoc ["event",`String event;"code",`String code]))
let sync_key room operation=room ^ ":" ^ operation
let sync_errors t room=List.filter_map (fun operation->Hashtbl.find_opt t.sync_failures (sync_key room operation))
  ["recovery";"reconcile"]
let synchronize t ?through ?job_id ?(on_progress=(fun _->())) ~operation room =
  Telemetry.ensure ~kind:operation ~fields:["room_id",`String room] (fun ()->
  Telemetry.result ~error:Net.error_name ~fields:["operation",`String operation] "iris_sync" (fun ()->
  let progress=Recovery.start operation (Store.cursor t.store ~source:t.config.source_id ~room) in
  let current=ref progress in
  let update p =
    let p={p with Recovery.started_at=progress.started_at} in
    current:=p;on_progress p in
  on_progress progress;
  Telemetry.span "iris_lock_wait" (fun ()->Lwt_mutex.lock t.recovery_lock) >>= fun ()->
  Lwt.finalize (fun () ->
    if operation="reconcile" then Recovery.reconcile ~on_progress:update ~config:t.config ~store:t.store ~iris:t.iris room
    else Recovery.room ~on_progress:update ~config:t.config ~store:t.store ~iris:t.iris ?through room)
    (fun ()->Lwt_mutex.unlock t.recovery_lock;Lwt.return_unit)
  >|= fun result->
  (match result with
   | Ok ()->Hashtbl.remove t.sync_failures (sync_key room operation)
   | Error error->
       let diagnostic=Recovery.diagnostic ~config:t.config ~room ~cause:(Net.error_name error) !current in
       let diagnostic=`Assoc (Json_util.object_ diagnostic @ [
         "origin",`String(if job_id=None then "background" else "request");
         "origin_job_id",Json_util.option (fun id->`String(Int64.to_string id)) job_id]) in
       Hashtbl.replace t.sync_failures (sync_key room operation) diagnostic;
       prerr_endline(Json_util.to_string (`Assoc ["event",`String(operation ^ "_failed");"error",diagnostic])));
  result))
let recover t ?through ?job_id ?on_progress room = synchronize t ?through ?job_id ?on_progress ~operation:"recovery" room
let reconcile t room = synchronize t ~operation:"reconcile" room

let sync_footer (job:Store.job) ~budget errors =
  if errors=[] then "" else
  let envelope errors=`Assoc ["job_id",`String(Int64.to_string job.id);"attempt",`Int job.attempts;
    "request_seq",`String(Int64.to_string job.invocation.message.seq);
    "code",`String "iris_sync_incomplete";"iris",`List errors] in
  let header="\n\n[asko diagnostic]\n" in
  let full=header ^ Json_util.to_string(envelope errors) in
  if String.length full<=budget then full else
    let first=List.hd errors in
    let fields=List.filter_map(fun key->Option.map(fun value->key,value)(Json_util.field key first))
      ["code";"stage";"error_id"] in
    header ^ Json_util.to_string(`Assoc (["job_id",`String(Int64.to_string job.id);
      "details",`String "service.log"]@fields))

let refresh_names t room =
  Telemetry.span "names_refresh" (fun ()->
  let now=Unix.gettimeofday () in
  match Hashtbl.find_opt t.name_refresh room with
  | Some at when now-.at<60. -> Telemetry.emit "names_cache" ["hit",`Bool true];Lwt.return_unit
  | _ ->
      Telemetry.emit "names_cache" ["hit",`Bool false];
      Hashtbl.replace t.name_refresh room now;
      Iris.room_names t.iris room >|= function
      | Error error -> log "names_refresh_failed" (Net.error_name error)
      | Ok names -> Store.transaction t.store (fun () ->
          List.iter (fun (user_id,name)->Store.observe_name t.store ~source:t.config.source_id
            ~room ~user_id ~name ~at:now ~current:true) names))

let finish t job ?snapshot ?snapshot_version ?evidence ?(sync_errors=[]) ?(refresh=true) body =
  Telemetry.span "outbox_enqueue" (fun ()->
  let sender=job.Store.invocation.message in
  let unresolved=List.exists(fun operation->Hashtbl.mem t.sync_failures (sync_key sender.room_id operation))
    ["recovery";"reconcile"] in
  (if refresh && sync_errors=[] && not unresolved then refresh_names t sender.room_id else Lwt.return_unit) >>= fun () ->
  let name=Store.speaker_name t.store ~source:sender.source ~room:sender.room_id ~user_id:sender.sender_id
    |> Option.value ~default:sender.sender_name in
  let prefix="@" ^ Utf8.take (min 128 (t.config.max_response_bytes/8)) (Trigger.normalize name) ^ "\n" in
  let cached=List.filter_map(fun operation->Hashtbl.find_opt t.sync_failures (sync_key sender.room_id operation))
    ["recovery";"reconcile"] in
  let errors=List.sort_uniq (fun a b->compare (Json_util.field "error_id" a) (Json_util.field "error_id" b)) (sync_errors@cached) in
  let budget=t.config.max_response_bytes-String.length prefix in
  let footer=sync_footer job ~budget errors in
  let body=prefix ^ Utf8.take (max 0 (budget-String.length footer)) body ^ footer in
  Store.finish_job ?snapshot t.store job ~body ~dry_run:t.config.dry_run ~snapshot_version ~evidence;
  Telemetry.emit "outbox_ready" ["job_id",`String(Int64.to_string job.id);"answer_bytes",`Int(String.length body)];
  Lwt.return_unit)

let diagnostic t (job:Store.job) error =
  let details=Json_util.object_ (Llm.error_details error) in
  `Assoc (details @ ["job_id",`String (Int64.to_string job.id);
    "attempt",`Int job.attempts; "model",`String t.config.model;
    "http_timeout_seconds",`Float t.config.http_timeout;
    "deadline_at",`String(Context_plan.timestamp job.expires_at);
    "request_ttl_seconds",`Float t.config.request_ttl])

let failed t ?(sync_errors=[]) (job:Store.job) error =
  let details=diagnostic t job error in
  let now=Unix.gettimeofday () in
  let retry=Llm.retryable error && job.attempts<3 && now+.5.<job.expires_at in
  prerr_endline (Json_util.to_string (`Assoc ["event",`String "job_failed";
    "retry",`Bool retry; "error",details]));
  if retry then
    (Store.fail_job t.store job ~now ~retry:true ~reason:(Llm.error_name error); Lwt.return_unit)
  else begin
    (* A deadline failure still needs a deliverable diagnostic. *)
    Store.run t.store "UPDATE jobs SET expires_at=MAX(expires_at,?) WHERE id=?"
      [Store.real(now+.60.);Store.integer job.id];
    finish t job ~sync_errors ~refresh:false ("asko 요청 실패\n" ^ Json_util.to_string details)
  end

let source_changed_notice t job = failed t job Llm.Source_changed

let resolve_anchor t request since =
  match request.reply_to, Store.anchor t.store request with
  | Some native_id, None ->
      Iris.find_anchor t.iris ~room:request.room_id ~native_id ~since >|= (function
        | Error _ -> ()
        | Ok rows -> List.iter (fun row ->
            match Iris_event.of_query_row ~source:t.config.source_id ~bot_id:t.config.bot_id row with
            | Ok message when message.room_id=request.room_id && message.native_id=Some native_id ->
                ignore (Ingest.apply ~config:t.config ~store:t.store ~now:(Unix.gettimeofday ()) ~live:false message)
            | _ -> ()) rows)
  | _ -> Lwt.return_unit

let reply_context t request since =
  resolve_anchor t request since >>= fun () ->
  match Store.anchor t.store request with
  | Some m when m.created_at>=since && m.is_bot && m.text="" ->
      Iris.find_anchor t.iris ~room:request.room_id ~native_id:(Option.get request.reply_to) ~since
      >|= (function
        | Error _ -> Some m
        | Ok rows -> rows |> List.filter_map (fun row ->
            match Iris_event.of_query_row ~source:t.config.source_id ~bot_id:t.config.bot_id row with
            | Ok found when found.native_id=request.reply_to && is_before found request
                && not found.deleted -> Some found | _ -> None) |> function
            | [found] -> Some found | _ -> Some m)
  | Some m when m.created_at>=since -> Lwt.return (Some m)
  | _ -> Lwt.return_none

let speaker_names t messages =
  match messages with
  | [] -> Lwt.return []
  | (m:message)::_ -> refresh_names t m.room_id >|= fun () ->
      Store.with_speaker_names t.store ~source:m.source ~room:m.room_id messages

let process_job_body t (job:Store.job) =
  let active_sync=ref None and request_sync_errors=ref [] in
  let request=job.invocation.message in
  if request.source<>t.config.source_id || not (Config.allowed t.config request.room_id) || request.deleted || request.is_bot
     || job.invocation.trigger<>Mention || Trigger.detect ~bot_id:t.config.bot_id request=None then
    (Store.fail_job t.store job ~now:(Unix.gettimeofday ()) ~retry:false ~reason:"scope_changed"; Lwt.return_unit)
  else if job.attempts>3 then
    source_changed_notice t job
  else Lwt.catch (fun () ->
    Lwt_unix.with_timeout (max 0.1 (job.expires_at-.Unix.gettimeofday ())) (fun () ->
      recover t ~through:request.seq ~job_id:job.id ~on_progress:(fun p->active_sync:=Some p) request.room_id >>= fun recovery ->
      active_sync:=None;
      request_sync_errors:=sync_errors t request.room_id;
      if recovery=Error Net.Source_changed then failed t job (Llm.Network Net.Source_changed) else
      let since=Unix.gettimeofday () -. float_of_int (t.config.retention_days*86400) in
      Telemetry.span "reply_context" (fun ()->reply_context t request since) >>= fun anchor ->
      let reference=Store.answer_reference t.store request anchor in
      let range={source=request.source;room_id=request.room_id;lower=At_time since;
        before_seq=request.seq;through_time=request.created_at;retention_start=since;
        note=(if !request_sync_errors=[] then None else Some "iris_sync_incomplete")} in
      refresh_names t request.room_id >>= fun () ->
      let history=Telemetry.sync "history_load" (fun ()->
        Store.messages ~max_bytes:t.config.max_history_bytes t.store range
        |> Store.with_speaker_names t.store ~source:request.source ~room:request.room_id) in
      Telemetry.emit "history_loaded" ["message_count",`Int(List.length history)];
      let version=Store.room_version t.store ~source:request.source ~room:request.room_id in
      Conversation.run ~config:t.config ~store:t.store ~llm:t.llm ~name_messages:(speaker_names t)
        ~request:job.invocation ~anchor ~reference ~history ~range ~version >>= function
      | Error error -> failed t ~sync_errors:!request_sync_errors job error
      | Ok {Conversation.answer;evidence_messages;input_messages;coverage} ->
          let body=Summary.render_answer ~max_bytes:t.config.max_response_bytes ~messages:evidence_messages answer in
          let anchor_snapshot=match anchor with
            | Some m when m.is_bot -> [{m with text=""}]
            | Some m -> [m] | None -> [] in
          let snapshot=List.sort_uniq (fun (a:message) b->Int64.compare a.seq b.seq)
              (request :: anchor_snapshot @ input_messages @ evidence_messages) in
          let evidence=`Assoc ["selected_ids",`List (List.map (fun (m:message)->`String(Int64.to_string m.seq)) evidence_messages);
            "input_ids",`List(List.map (fun (m:message)->`String(Int64.to_string m.seq)) snapshot);
            "coverage",coverage] in
          finish t job ~sync_errors:!request_sync_errors ~snapshot ~snapshot_version:version ~evidence body))
    (function
      | Lwt.Canceled -> Lwt.fail Lwt.Canceled
      | Store.History_too_large -> failed t job (Llm.Limit_exceeded
          {resource="max_history_bytes";actual=None;limit=t.config.max_history_bytes})
      | Store.Stale_snapshot ->
          let now=Unix.gettimeofday () in
          log "job_retry" "used_source_changed";
          if job.attempts<3 && now+.5.<job.expires_at then begin
            Store.fail_job t.store job ~now ~retry:true ~reason:"source_changed";
            Lwt.return_unit
          end else
            source_changed_notice t job
      | Lwt_unix.Timeout ->
          let errors=match !active_sync with None-> !request_sync_errors | Some p->
            let diagnostic=Recovery.diagnostic ~config:t.config ~room:request.room_id
              ~cause:"request_deadline_exceeded" p in
            prerr_endline(Json_util.to_string (`Assoc ["event",`String "iris_sync_interrupted";
              "job_id",`String(Int64.to_string job.id);"error",diagnostic]));
            diagnostic::!request_sync_errors in
          failed t ~sync_errors:errors job Llm.Request_timeout
      | exn -> failed t job (Llm.Internal_error (Printexc.exn_slot_name exn)))

let process_job t (job:Store.job) =
  let now=Unix.gettimeofday () in
  let queue=Store.one t.store "SELECT created_at,available_at FROM jobs WHERE id=?" [Store.integer job.id]
    (fun s->["queue_ms",Telemetry.ms(now-.Sqlite3.column_double s 1);
      "request_age_ms",Telemetry.ms(now-.Sqlite3.column_double s 0)]) |> Option.value ~default:[] in
  Telemetry.with_trace ~kind:"job" ~fields:(["job_id",`String(Int64.to_string job.id);
    "request_seq",`String(Int64.to_string job.invocation.message.seq);"attempt",`Int job.attempts;
    "room_id",`String job.invocation.message.room_id]@queue) (fun ()->
    Telemetry.span "job" (fun ()->process_job_body t job) >|= fun ()->
    let state=Store.one t.store "SELECT state FROM jobs WHERE id=?" [Store.integer job.id]
      (fun s->Sqlite3.column_text s 0) |> Option.value ~default:"missing" in
    Telemetry.emit "job_outcome" ["state",`String state])

let send_tick t =
  if t.config.dry_run then Lwt.return_unit else
  let now=Unix.gettimeofday () in
  match Store.next_outgoing t.store ~now with
  | None -> Lwt.return_unit
  | Some outgoing when outgoing.state="awaiting_echo" ->
      Telemetry.with_trace ~kind:"delivery" ~fields:["job_id",`String(Int64.to_string outgoing.job_id);
        "outbox_id",`String(Int64.to_string outgoing.id);"room_id",`String outgoing.room_id]
        (fun ()->Telemetry.span "delivery_confirmation" (fun ()->
      let floor=Option.value ~default:0L outgoing.floor_seq in
      let remaining=t.config.confirm_timeout -. (now -. Option.value ~default:now outgoing.attempted_at) in
      let observed = if remaining<=0. then Lwt.return (Error Net.Timeout) else
        Lwt.catch (fun () -> Lwt_unix.with_timeout remaining (fun () ->
          Iris.observed_reply t.iris ~room:outgoing.room_id ~after:floor ~body:outgoing.body))
          (function Lwt_unix.Timeout->Lwt.return (Error Net.Timeout) | exn->Lwt.fail exn) in
      observed >>= (function
        | Ok (Some _) -> Store.outgoing_state t.store outgoing ~state:"sent" (); Lwt.return_unit
        | _ when Unix.gettimeofday () -. Option.value ~default:now outgoing.attempted_at >= t.config.confirm_timeout ->
            Store.outgoing_state t.store outgoing ~state:"uncertain" ~error:"echo_not_confirmed" (); Lwt.return_unit
        | _ -> Lwt.return_unit)))
  | Some _ when now<t.next_send_at -> Lwt.return_unit
  | Some outgoing ->
      Telemetry.with_trace ~kind:"delivery" ~fields:["job_id",`String(Int64.to_string outgoing.job_id);
        "outbox_id",`String(Int64.to_string outgoing.id);"room_id",`String outgoing.room_id]
        (fun ()->Telemetry.span "delivery" (fun ()->
      t.next_send_at <- now +. t.config.send_interval;
      if outgoing.source<>t.config.source_id || not (Config.allowed t.config outgoing.room_id) then
        (Store.outgoing_state t.store outgoing ~state:"failed" ~error:"scope_changed" (); Lwt.return_unit)
      else Iris.configuration t.iris >>= function
      | Error error -> log "delivery_waiting" (Net.error_name error); Lwt.return_unit
      | Ok settings ->
          let identity=Json_util.protect (fun () -> Json_util.required "bot_id" settings |> Json_util.id) in
          if identity<>Ok t.config.bot_id then
            (Store.outgoing_state t.store outgoing ~state:"failed" ~error:"iris_bot_id_mismatch" (); Lwt.return_unit)
          else
            let delay=match Json_util.protect (fun () -> Json_util.required "message_send_rate" settings |> Json_util.float) with
              | Ok rate when rate>=0. -> min 600. (rate /. 1000. +. 0.1)
              | _ -> 1. in
            t.next_send_at <- now +. max t.config.send_interval delay;
            Iris.latest t.iris outgoing.room_id >>= function
            | Error error -> log "delivery_waiting" (Net.error_name error); Lwt.return_unit
            | Ok (floor,_) ->
                if not (Store.begin_send t.store outgoing ~floor_seq:floor ~now:(Unix.gettimeofday ())) then Lwt.return_unit
                else
                  let age=Store.one t.store "SELECT created_at FROM jobs WHERE id=?" [Store.integer outgoing.job_id]
                    (fun s->Telemetry.ms(Unix.gettimeofday ()-.Sqlite3.column_double s 0)) |> Option.value ~default:`Null in
                  Telemetry.emit "delivery_attempt" ["queue_to_send_ms",age];
                  Iris.reply t.iris ~room:outgoing.room_id ~body:outgoing.body >|= function
                  | Ok () -> Store.outgoing_state t.store outgoing ~state:"awaiting_echo" ()
                  | Error error -> Store.outgoing_state t.store outgoing ~state:"uncertain" ~error:(Net.error_name error) ()))

let run ?on_ready ~stop t =
  let rec supervise name step delay () =
    if not (Lwt.is_sleeping stop) then Lwt.return_unit else
    Lwt.catch step (function Lwt.Canceled->Lwt.fail Lwt.Canceled
      | exn -> log name ("internal_error:" ^ Printexc.exn_slot_name exn); Lwt.return_unit)
    >>= fun () -> Lwt_unix.sleep delay >>= supervise name step delay in
  let jobs () = match Store.claim_job t.store ~now:(Unix.gettimeofday ()) with
    | None->Lwt.return_unit | Some job->process_job t job in
  let recovery () = Lwt_list.iter_s (fun room -> recover t room >|= fun _->()) t.config.rooms in
  let maintenance () =
    ignore (Store.purge t.store ~before:(Unix.gettimeofday () -. float_of_int (t.config.retention_days*86400)));
    Lwt.return_unit in
  let reconciliation () = Lwt_list.iter_s (fun room -> reconcile t room >|= fun _->()) t.config.rooms in
  let workers=[supervise "job_worker" jobs 0.2 (); supervise "sender" (fun ()->send_tick t) 0.5 ();
               supervise "recovery" recovery t.config.recovery_interval (); supervise "retention" maintenance 60. ();
               (Lwt_unix.sleep t.config.reconcile_interval >>= supervise "reconcile" reconciliation t.config.reconcile_interval)] in
  Lwt.finalize
    (fun () -> Server.run ?on_ready ~stop t.config t.store)
    (fun () -> List.iter Lwt.cancel workers;
      Lwt.join (List.map (fun worker -> Lwt.catch (fun ()->worker) (fun _->Lwt.return_unit)) workers))
