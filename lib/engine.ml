open Types
open Lwt.Infix
type t = {
  config : Config.t; store : Store.t; iris : Iris.t; llm : Llm.t;
  recovery_lock : Lwt_mutex.t; mutable next_send_at : float;
  name_refresh : (string,float) Hashtbl.t;
}
let create config store = {
  config; store; iris=Iris.create config; llm=Llm.create config store;
  recovery_lock=Lwt_mutex.create (); name_refresh=Hashtbl.create 8; next_send_at=Store.last_send_at store +. config.Config.send_interval;
}
let log event code =
  prerr_endline (Json_util.to_string (`Assoc ["event",`String event;"code",`String code]))
let recover t ?through room = Lwt_mutex.with_lock t.recovery_lock (fun () ->
  Recovery.room ~config:t.config ~store:t.store ~iris:t.iris ?through room)

let refresh_names t room =
  let now=Unix.gettimeofday () in
  match Hashtbl.find_opt t.name_refresh room with
  | Some at when now-.at<60. -> Lwt.return_unit
  | _ ->
      Hashtbl.replace t.name_refresh room now;
      Iris.room_names t.iris room >|= function
      | Error error -> log "names_refresh_failed" (Net.error_name error)
      | Ok names -> Store.transaction t.store (fun () ->
          List.iter (fun (user_id,name)->Store.observe_name t.store ~source:t.config.source_id
            ~room ~user_id ~name ~at:now ~current:true) names)

let finish t job ?snapshot ?snapshot_version ?evidence body =
  let sender=job.Store.invocation.message in
  refresh_names t sender.room_id >>= fun () ->
  let name=Store.speaker_name t.store ~source:sender.source ~room:sender.room_id ~user_id:sender.sender_id
    |> Option.value ~default:sender.sender_name in
  let prefix="@" ^ Trigger.normalize name ^ "\n" in
  let body=prefix ^ Utf8.take (max 0 (t.config.max_response_bytes-String.length prefix)) body in
  Store.finish_job ?snapshot t.store job ~body ~dry_run:t.config.dry_run ~snapshot_version ~evidence;
  Lwt.return_unit

let friendly_error = function
  | Llm.Not_configured -> "아직 답변할 준비가 안 됐어요. 잠시 후 다시 불러주세요."
  | Llm.Budget_exceeded -> "오늘 설정된 모델 사용량 한도에 도달했어요. 나중에 다시 불러주세요."
  | Llm.Input_too_large -> "대화가 너무 많아요. 봇을 멘션하고 최근 2시간처럼 범위를 줄여서 불러주세요."
  | _ -> "답변을 완료하지 못했어요. 잠시 후 다시 불러주세요."

let failed t (job:Store.job) error =
  log "job_failed" (Llm.error_name error);
  let now=Unix.gettimeofday () in
  if Llm.retryable error && job.attempts<3 && now+.5.<job.expires_at then
    (Store.fail_job t.store job ~now ~retry:true ~reason:(Llm.error_name error); Lwt.return_unit)
  else finish t job (friendly_error error)

let source_changed_notice t (job:Store.job) =
  log "job_failed" "used_source_changed";
  (* Allow the failure notice to be delivered even when the model's deadline ended. *)
  Store.run t.store "UPDATE jobs SET expires_at=MAX(expires_at,?) WHERE id=?"
    [Store.real(Unix.gettimeofday ()+.60.);Store.integer job.id];
  finish t job "참고한 메시지가 계속 수정되어 답변을 마무리하지 못했어요. 잠시 후 다시 불러주세요."

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

let process_job t (job:Store.job) =
  let request=job.invocation.message in
  if request.source<>t.config.source_id || not (Config.allowed t.config request.room_id) || request.deleted || request.is_bot
     || job.invocation.trigger<>Mention || Trigger.detect ~bot_id:t.config.bot_id request=None then
    (Store.fail_job t.store job ~now:(Unix.gettimeofday ()) ~retry:false ~reason:"scope_changed"; Lwt.return_unit)
  else if job.attempts>3 then
    source_changed_notice t job
  else Lwt.catch (fun () ->
    Lwt_unix.with_timeout (max 0.1 (job.expires_at-.Unix.gettimeofday ())) (fun () ->
      recover t ~through:request.seq request.room_id >>= fun recovery ->
      if recovery=Error Net.Source_changed then failed t job (Llm.Network Net.Source_changed) else
      let since=Unix.gettimeofday () -. float_of_int (t.config.retention_days*86400) in
      reply_context t request since >>= fun anchor ->
      let reference=Store.answer_reference t.store request anchor in
      let range={source=request.source;room_id=request.room_id;lower=At_time since;
        before_seq=request.seq;through_time=request.created_at;retention_start=since;note=None} in
      refresh_names t request.room_id >>= fun () ->
      let history=Store.messages ~max_bytes:t.config.max_history_bytes t.store range
        |> Store.with_speaker_names t.store ~source:request.source ~room:request.room_id in
      let version=Store.room_version t.store ~source:request.source ~room:request.room_id in
      let inherited=Store.reference_messages t.store range reference in
      Conversation.run ~config:t.config ~store:t.store ~llm:t.llm ~name_messages:(speaker_names t)
        ~request:job.invocation ~anchor ~reference ~history ~range ~version >>= function
      | Error error -> failed t job error
      | Ok (answer,evidence_messages) ->
          let body=Summary.render_answer ~max_bytes:t.config.max_response_bytes ~messages:evidence_messages answer in
          let body=if Result.is_ok recovery then body else body ^ "\n(일부 대화 수집이 지연되어 저장된 내용으로 답했어요.)" in
          let anchor_snapshot=match anchor with
            | Some m when m.is_bot -> [{m with text=""}]
            | Some m -> [m] | None -> [] in
          let snapshot=List.sort_uniq (fun (a:message) b->Int64.compare a.seq b.seq)
              (request :: anchor_snapshot @ inherited @ evidence_messages) in
          let evidence=`Assoc ["selected_ids",`List (List.map (fun (m:message)->`String(Int64.to_string m.seq)) evidence_messages);
            "input_ids",`List(List.map (fun (m:message)->`String(Int64.to_string m.seq)) snapshot)] in
          finish t job ~snapshot ~snapshot_version:version ~evidence body))
    (function
      | Lwt.Canceled -> Lwt.fail Lwt.Canceled
      | Store.History_too_large -> failed t job Llm.Input_too_large
      | Store.Stale_snapshot ->
          let now=Unix.gettimeofday () in
          log "job_retry" "used_source_changed";
          if job.attempts<3 && now+.5.<job.expires_at then begin
            Store.fail_job t.store job ~now ~retry:true ~reason:"source_changed";
            Lwt.return_unit
          end else
            source_changed_notice t job
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
  let reconcile () = Lwt_list.iter_s (fun room ->
    Lwt_mutex.with_lock t.recovery_lock (fun () -> Recovery.reconcile ~config:t.config ~store:t.store ~iris:t.iris room)
    >|= function Ok ()->() | Error error->log "reconcile_failed" (Net.error_name error)) t.config.rooms in
  let workers=[supervise "job_worker" jobs 0.2 (); supervise "sender" (fun ()->send_tick t) 0.5 ();
               supervise "recovery" recovery t.config.recovery_interval (); supervise "retention" maintenance 60. ();
               (Lwt_unix.sleep t.config.reconcile_interval >>= supervise "reconcile" reconcile t.config.reconcile_interval)] in
  Lwt.finalize
    (fun () -> Server.run ?on_ready ~stop t.config t.store)
    (fun () -> List.iter Lwt.cancel workers;
      Lwt.join (List.map (fun worker -> Lwt.catch (fun ()->worker) (fun _->Lwt.return_unit)) workers))
