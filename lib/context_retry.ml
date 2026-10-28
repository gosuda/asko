open Lwt.Infix

(* Cache and attempts belong to one job. Exact batch inputs and the output contract
   determine reuse, so edits, retention, model changes and prompt changes miss it. *)
let notes ?(sleep=Lwt_unix.sleep) ~store ~job_id ~llm ~request ~call messages =
  let key=Context_window.notes_key ~config:llm.Llm.config ~request messages in
  let attempts,cached,last_error=match job_id with
    | None->0,None,None | Some job_id->Store.context_notes store ~job_id ~key in
  let save notes error=match job_id with None->() | Some job_id->
    Store.save_context_notes store ~job_id ~key ~notes ~error in
  let exhausted reason=Llm.Bad_response {stage="context_notes";
    reason="batch retry limit reached: " ^ Option.value ~default:"invalid response" reason} in
  let rec run attempts feedback =
    if attempts>=3 then Lwt.return(Error(exhausted feedback)) else
    let reserved=match job_id with None->true | Some job_id->Store.reserve_context_notes store ~job_id ~key
      ~dependencies:(List.map(fun (m:Types.message)->m.seq) messages) in
    if not reserved then Lwt.return(Error(exhausted feedback)) else
    call (fun ()->Context_window.notes ?feedback ~llm ~request messages) >>= function
    | Ok facts -> save (Some(Json_util.to_string (`List facts))) None;Lwt.return(Ok facts)
    | Error error ->
        let reason=match error with Llm.Bad_response {reason;_}->reason | _->Llm.error_name error in
        save None (Some reason);
        if not (Llm.retryable error || match error with Llm.Bad_response _->true | _->false)
        then Lwt.return(Error error)
        else if attempts+1>=3 then Lwt.return(Error(exhausted(Some reason)))
        else begin
          Telemetry.emit "context_batch_retry" ["batch_attempt",`Int(attempts+2);"batch_key",`String key;
            "error",Llm.error_details error];
          (match error with
           | Llm.Network _->sleep (float_of_int(1 lsl attempts) +. Random.float 0.25)
           | _->Lwt.return_unit) >>= fun () ->
          run (attempts+1) (match error with Llm.Bad_response _->Some reason | _->feedback)
        end in
  match cached with
  | Some notes ->
      Telemetry.emit "context_batch_cache" ["hit",`Bool true;"batch_key",`String key];
      Lwt.return(Ok(Json_util.list Fun.id (Yojson.Safe.from_string notes)))
  | None -> run attempts last_error
