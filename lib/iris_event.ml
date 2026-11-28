open Types

let embedded name json =
  match Json_util.field name json with
  | None -> `Assoc []
  | Some value ->
      (match Json_util.protect (fun () -> Json_util.json_string value) with
       | Ok (`Assoc _ as value) -> value
       | Ok _ | Error _ -> `Assoc [])

let text_message row = match Json_util.field "type" row with
  | Some (`String "1" | `Int 1) -> true | _ -> false

let reply_id = function
  | None | Some (`Null | `String "" | `String "0" | `Int 0) -> None
  | value -> Json_util.optional Json_util.id value

let positive_id key row =
  match Json_util.field key row with
  | Some value ->
      (match Json_util.protect (fun () -> Json_util.id value |> Int64.of_string_opt) with
       | Ok (Some id) when id > 0L -> Some (Int64.to_string id)
       | _ -> None)
  | None -> None

(* Iris enriches webhook attachments with the thread parent. /query returns the
   underlying columns, including the native thread ID on newer KakaoTalk. *)
let reply_parent row attachment =
  let quoted = reply_id (Json_util.field "src_logId" attachment) in
  if not (text_message row) then quoted else
  match positive_id "thread_id" row, quoted with
  | Some id, _ | None, Some id -> Some id
  | None, None -> positive_id "threadId" (embedded "supplement" row)

(* Older clients can keep the only thread ID in an encrypted supplement.
   For those rows Iris's /chat endpoint provides the same frame as the webhook. *)
let needs_thread_frame row =
  match Json_util.field "supplement" row with
  | Some (`String value) when value <> "" ->
      text_message row && reply_parent row (embedded "attachment" row) = None &&
      Result.is_error (Json_util.protect (fun () -> Yojson.Safe.from_string value))
  | _ -> false

let decode ~source ~bot_id payload = Json_util.protect (fun () ->
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
  if String.length text > 65536 || not (String.is_valid_utf_8 text) then invalid "invalid message text";
  let attachment = embedded "attachment" raw in
  let metadata = embedded "v" raw in
  let native_id = optional id (field "id" raw) in
  let reply_to = reply_parent raw attachment in
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
  let marker = match field "origin" metadata with
    | Some (`String ("SYNCDLMSG" | "SYNCMODMSG")) -> default float 0. (field "deleted_at" raw) > 0.
    | _ -> false in
  let withdrawn = if not marker then None else
    match protect (fun () -> positive_id "logId" (Yojson.Safe.from_string text)) with
    | Ok id -> id | Error _ -> None in
  { source; seq; native_id; room_id; sender_id;
    sender_name=Utf8.take 512 (default string sender_id (field "sender" payload));
    created_at; text; reply_to; mentions;
    is_bot=mine || (bot_id <> "" && sender_id = bot_id);
    deleted=marker || field "deleted" raw = Some (`Bool true) }, withdrawn)

let normalize ~source ~bot_id payload = Result.map fst (decode ~source ~bot_id payload)

let decode_row ~source ~bot_id row = decode ~source ~bot_id (`Assoc ["json", row])

let of_query_row ~source ~bot_id row =
  Result.map fst (decode_row ~source ~bot_id row)

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
