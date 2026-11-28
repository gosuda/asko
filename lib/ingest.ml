open Types
type outcome = Ignored of string | Stored of { inserted : bool; job : Store.enqueue_result option }

let invocation ~(config : Config.t) ~store (message : message) =
  Trigger.detect ~bot_id:config.bot_id message
    ~reply_to_bot:(config.reply_trigger && Store.replies_to_bot store message)

let apply ?withdrawn ~config ~store ~now ~live (message : message) =
  if not (Config.allowed config message.room_id) then Ignored "room_not_allowed"
  else if message.created_at > now +. 60. then Ignored "future_timestamp"
  else if message.created_at < now -. float_of_int (config.Config.retention_days * 86400) then Ignored "outside_retention"
  else Store.transaction store (fun () ->
    if message.is_bot && not live && not message.deleted then
      Store.recover_receipt store ~window:config.confirm_timeout message;
    let prior=Store.get_message store ~source:message.source ~seq:message.seq in
    match prior with
    | Some old when old.deleted && not message.deleted -> Ignored "message_deleted"
    | _ ->
      let message = match prior with
        | Some old when not live && message.sender_name=message.sender_id -> {message with sender_name=old.sender_name}
        | _ -> message in
      Option.iter (Store.record_withdrawal store message) withdrawn;
      let message = if not message.deleted && Store.withdrawn store message then {message with deleted=true} else message in
      let invocation = invocation ~config ~store message in
      if not message.is_bot && not message.deleted then Store.observe_name store ~source:message.source ~room:message.room_id ~user_id:message.sender_id
        ~name:message.sender_name ~at:(if live then now else message.created_at) ~current:live;
      let stored_message = if message.is_bot then {message with text=""} else message in
      let inserted = Store.put_message store ~is_command:(invocation <> None) stored_message in
      if not message.deleted then Store.confirm_message store message;
      let job = if live then Option.map (Store.enqueue store ~now ~config) invocation else None in
      Stored {inserted; job})

let event ~config ~store ~now json =
  match Iris_event.decode ~source:config.Config.source_id ~bot_id:config.bot_id json with
  | Error reason -> Error reason
  | Ok (message,withdrawn) -> Ok (apply ?withdrawn ~config ~store ~now ~live:true message)

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
