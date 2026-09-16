open Types
open Lwt.Infix
type t = {
  config : Config.t; store : Store.t; iris : Iris.t; llm : Llm.t;
  recovery_lock : Lwt_mutex.t; mutable next_send_at : float;
}
let create config store = {
  config; store; iris=Iris.create config; llm=Llm.create config store;
  recovery_lock=Lwt_mutex.create (); next_send_at=Store.last_send_at store +. config.Config.send_interval;
}
let log event code =
  prerr_endline (Json_util.to_string (`Assoc ["event",`String event;"code",`String code]))
let recover t ?through room = Lwt_mutex.with_lock t.recovery_lock (fun () ->
  Recovery.room ~config:t.config ~store:t.store ~iris:t.iris ?through room)

let finish t job ?snapshot_version ?evidence body =
  Store.finish_job t.store job ~body ~dry_run:t.config.dry_run ~snapshot_version ~evidence;
  Lwt.return_unit

let friendly_error = function
  | Llm.Not_configured -> "아직 요약 기능을 사용할 준비가 안 됐어요. 잠시 후 다시 불러주세요."
  | Llm.Budget_exceeded -> "오늘 사용할 수 있는 요약량을 모두 썼어요. 나중에 다시 불러주세요."
  | Llm.Input_too_large -> "대화가 너무 많아요. /요약 2시간처럼 범위를 줄여서 불러주세요."
  | _ -> "요약을 완료하지 못했어요. 잠시 후 다시 불러주세요."

let failed t (job:Store.job) error =
  log "job_failed" (Llm.error_name error);
  let now=Unix.gettimeofday () in
  if Llm.retryable error && job.attempts<3 && now+.5.<job.expires_at then
    (Store.fail_job t.store job ~now ~retry:true ~reason:(Llm.error_name error); Lwt.return_unit)
  else finish t job (friendly_error error)

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

let summarize t (job:Store.job) intent =
  let request=job.invocation.message in
  recover t ~through:request.seq request.room_id >>= fun recovery ->
  let since=Unix.gettimeofday () -. float_of_int (t.config.retention_days*86400) in
  resolve_anchor t request since >>= fun () ->
  let previous=Store.previous t.store request and anchor=Store.anchor t.store request in
  match Scope.resolve ~retention_start:since ~previous ~anchor job.invocation intent with
  | Error message -> finish t job message
  | Ok range ->
      let version=Store.room_version t.store ~source:request.source ~room:request.room_id in
      let messages=Store.messages ~max_bytes:t.config.max_history_bytes t.store range in
      let synced=Result.is_ok recovery && Store.cursor t.store ~source:request.source ~room:request.room_id >= request.seq in
      let notes=(match range.note with None->[] | Some note->[note]) @
        (if synced then [] else ["수집 상태를 확인하지 못해 보관된 대화만 정리했어요."]) in
      (match intent.topic with
       | None -> Lwt.return (Ok {Retrieval.messages;note=None})
       | Some topic -> Retrieval.select ~config:t.config ~store:t.store ~llm:t.llm ~range ~version ~topic ~focus:intent.focus messages)
      >>= function
      | Error error -> failed t job error
      | Ok selected when selected.Retrieval.messages=[] ->
          finish t job (if intent.topic=None then "그 범위에는 요약할 대화가 없어요." else "그 범위에서 관련 대화를 찾지 못했어요.")
      | Ok selected ->
          Summary.generate t.llm ~intent selected.messages >>= function
          | Error error -> failed t job error
          | Ok summary ->
              let notes=notes @ (match selected.note with None->[] | Some note->[note]) in
              let body=Summary.render ~max_bytes:t.config.max_response_bytes ~range ~intent
                  ~messages:selected.messages ~notes summary in
              let evidence=`Assoc ["summary",Llm.summary_json summary;
                "before_seq",`String (Int64.to_string range.before_seq);
                "through_time",`Float range.through_time;
                "selected_ids",`List (List.map (fun (m:message)->`String (Int64.to_string m.seq)) selected.messages)] in
              finish t job ~snapshot_version:version ~evidence body

let process_job t (job:Store.job) =
  let request=job.invocation.message in
  if request.source<>t.config.source_id || not (Config.allowed t.config request.room_id) || request.deleted || request.is_bot then
    (Store.fail_job t.store job ~now:(Unix.gettimeofday ()) ~retry:false ~reason:"scope_changed"; Lwt.return_unit)
  else Lwt.catch (fun () ->
    Lwt_unix.with_timeout (max 0.1 (job.expires_at-.Unix.gettimeofday ())) (fun () ->
      match Intent.shortcut job.invocation with
      | Help -> finish t job Summary.help
      | Summarize intent -> summarize t job intent
      | Classify -> Llm.classify t.llm job.invocation >>= function
          | Error error -> failed t job error
          | Ok Llm.Show_help -> finish t job Summary.help
          | Ok Llm.Out_of_scope -> finish t job "이 방의 대화 요약을 도와드려요. @요약봇 오늘 중요한거처럼 불러주세요."
          | Ok (Llm.Need_details question) -> finish t job (question ^ "\n시간이나 주제를 넣어 다시 불러주세요.")
          | Ok (Llm.Ready intent) -> summarize t job intent))
    (function
      | Lwt.Canceled -> Lwt.fail Lwt.Canceled
      | Store.History_too_large -> failed t job Llm.Input_too_large
      | Store.Stale_snapshot ->
          Store.fail_job t.store job ~now:(Unix.gettimeofday ()) ~retry:true ~reason:"source_changed";
          Lwt.return_unit
      | Lwt_unix.Timeout -> failed t job (Llm.Network Net.Timeout)
      | _ -> Store.fail_job t.store job ~now:(Unix.gettimeofday ()) ~retry:true ~reason:"internal_error";
          log "job_failed" "internal_error"; Lwt.return_unit)

let send_tick t =
  if t.config.dry_run then Lwt.return_unit else
  let now=Unix.gettimeofday () in
  match Store.next_outgoing t.store ~now with
  | None -> Lwt.return_unit
  | Some outgoing when outgoing.state="awaiting_echo" ->
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
        | _ -> Lwt.return_unit)
  | Some _ when now<t.next_send_at -> Lwt.return_unit
  | Some outgoing ->
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
                else Iris.reply t.iris ~room:outgoing.room_id ~body:outgoing.body >|= function
                  | Ok () -> Store.outgoing_state t.store outgoing ~state:"awaiting_echo" ()
                  | Error error -> Store.outgoing_state t.store outgoing ~state:"uncertain" ~error:(Net.error_name error) ()

let run ?on_ready ~stop t =
  let rec supervise name step delay () =
    if not (Lwt.is_sleeping stop) then Lwt.return_unit else
    Lwt.catch step (function Lwt.Canceled->Lwt.fail Lwt.Canceled
      | _ -> log name "internal_error"; Lwt.return_unit)
    >>= fun () -> Lwt_unix.sleep delay >>= supervise name step delay in
  let jobs () = match Store.claim_job t.store ~now:(Unix.gettimeofday ()) with
    | None->Lwt.return_unit | Some job->process_job t job in
  let recovery () = Lwt_list.iter_s (fun room -> recover t room >|= function
    | Ok ()->() | Error error->log "recovery_failed" (Net.error_name error)) t.config.rooms in
  let maintenance () =
    ignore (Store.purge t.store ~before:(Unix.gettimeofday () -. float_of_int (t.config.retention_days*86400)));
    Lwt.return_unit in
  let workers=[supervise "job_worker" jobs 0.2 (); supervise "sender" (fun ()->send_tick t) 0.5 ();
               supervise "recovery" recovery t.config.recovery_interval (); supervise "retention" maintenance 60. ()] in
  Lwt.finalize
    (fun () -> Server.run ?on_ready ~stop t.config t.store)
    (fun () -> List.iter Lwt.cancel workers;
      Lwt.join (List.map (fun worker -> Lwt.catch (fun ()->worker) (fun _->Lwt.return_unit)) workers))
