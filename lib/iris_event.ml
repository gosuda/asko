open Types

let embedded name json =
  match Json_util.field name json with
  | None -> `Assoc []
  | Some value -> (match Json_util.protect (fun () -> Json_util.json_string value) with Ok value -> value | Error _ -> `Assoc [])

let normalize ~source ~bot_id payload = Json_util.protect (fun () ->
  let open Json_util in
  let raw = required "json" payload in
  let seq_text = required "_id" raw |> id in
  let seq = match Int64.of_string_opt seq_text with Some value when value >= 0L -> value | _ -> invalid "invalid source sequence" in
  let room_id = required "chat_id" raw |> id in
  let sender_id = required "user_id" raw |> id in
  let created_at = required "created_at" raw |> float in
  let created_at = if created_at > 100000000000. then created_at /. 1000. else created_at in
  if created_at < 0. then invalid "invalid timestamp";
  let text = match field "msg" payload with
    | Some (`String text) -> text
    | _ -> default string "" (field "message" raw)
  in
  if String.length text > 65536 then invalid "message too large";
  let attachment = embedded "attachment" raw in
  let metadata = embedded "v" raw in
  let native_id = optional id (field "id" raw) in
  let reply_to =
    match field "src_logId" attachment with
    | None | Some `Null | Some (`String "") | Some (`Int 0) -> None
    | value -> optional id value
  in
  let mentions =
    match field "mentions" attachment with
    | Some (`List values) -> List.filter_map (fun mention ->
        match protect (fun () ->
          match mention with
          | `Assoc _ -> (match field "user_id" mention with Some value -> id value | None -> required "userId" mention |> id)
          | value -> id value) with Ok value -> Some value | Error _ -> None) values
    | _ -> []
  in
  let mine = field "isMine" metadata = Some (`Bool true) in
  { source; seq; native_id; room_id; sender_id;
    sender_name=default string sender_id (field "sender" payload);
    created_at; text; reply_to; mentions;
    is_bot=mine || (bot_id <> "" && sender_id = bot_id);
    deleted=field "deleted" raw = Some (`Bool true) })

let of_query_row ~source ~bot_id row =
  normalize ~source ~bot_id (`Assoc ["json", row])

let to_json (message : message) = `Assoc [
  "source", `String message.source; "seq", `String (Int64.to_string message.seq);
  "native_id", Json_util.option (fun x -> `String x) message.native_id;
  "room_id", `String message.room_id; "sender_id", `String message.sender_id;
  "sender_name", `String message.sender_name; "created_at", `Float message.created_at;
  "text", `String message.text;
  "reply_to", Json_util.option (fun x -> `String x) message.reply_to;
  "mentions", `List (List.map (fun x -> `String x) message.mentions);
  "is_bot", `Bool message.is_bot; "deleted", `Bool message.deleted;
]
