open Types
type outcome = Ignored of string | Stored of { inserted : bool; job : Store.enqueue_result option }

let apply ~config ~store ~now ~live (message : message) =
  if not (Config.allowed config message.room_id) then Ignored "room_not_allowed"
  else if message.created_at > now +. 60. then Ignored "future_timestamp"
  else if message.created_at < now -. float_of_int (config.Config.retention_days * 86400) then Ignored "outside_retention"
  else
    let message = if live then message else
      match Store.get_message store ~source:message.source ~seq:message.seq with
      | Some prior when message.sender_name=message.sender_id -> {message with sender_name=prior.sender_name}
      | _ -> message in
    let invocation = Trigger.detect ~bot_id:config.bot_id ~aliases:config.aliases message in
    Store.transaction store (fun () ->
      let stored_message = if message.is_bot then {message with text=""} else message in
      let inserted = Store.put_message store ~is_command:(invocation <> None) stored_message in
      Store.confirm_message store message;
      let job = if live then Option.map (Store.enqueue store ~now ~config) invocation else None in
      Stored {inserted; job})

let event ~config ~store ~now json =
  match Iris_event.normalize ~source:config.Config.source_id ~bot_id:config.bot_id json with
  | Error reason -> Error reason
  | Ok message -> Ok (apply ~config ~store ~now ~live:true message)

let json = function
  | Ignored reason -> `Assoc ["accepted", `Bool true; "stored", `Bool false; "reason", `String reason]
  | Stored {inserted; job} ->
      let job_state, job_id = match job with
        | None -> "not_requested", `Null
        | Some (Store.Queued id) -> "queued", `String (Int64.to_string id)
        | Some Store.Duplicate -> "duplicate", `Null
        | Some Store.Stale -> "stale", `Null
        | Some Store.Rate_limited -> "rate_limited", `Null in
      `Assoc ["accepted", `Bool true; "stored", `Bool true; "inserted", `Bool inserted;
              "job_state", `String job_state; "job_id", job_id]
