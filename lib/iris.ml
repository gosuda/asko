open Lwt.Infix
type t = { config : Config.t }
let create config = {config}
let query t sql bindings =
  let body = `Assoc ["query", `String sql; "bind", `List (List.map (fun x -> `String x) bindings)] in
  Net.json ~timeout:t.config.http_timeout ~body `POST (Net.endpoint t.config.iris_url "/query")
  >|= function
  | Error error -> Error error
  | Ok json ->
      (match Json_util.protect (fun () -> Json_util.required "data" json |> Json_util.list Fun.id) with
       | Ok rows -> Ok rows | Error _ -> Error Net.Invalid_json)

let latest t room =
  query t "SELECT MAX(_id) AS max_id, MIN(created_at) AS first_at FROM chat_logs WHERE chat_id = ?" [room]
  >|= function
  | Error error -> Error error
  | Ok [row] ->
      (match Json_util.protect (fun () ->
         let maximum = Json_util.optional Json_util.id (Json_util.field "max_id" row) in
         let maximum = match maximum with None -> 0L | Some value -> Int64.of_string value in
         maximum, Json_util.optional Json_util.float (Json_util.field "first_at" row)) with
       | Ok value -> Ok value | Error _ -> Error Net.Invalid_json)
  | Ok _ -> Error Net.Invalid_json

let page t ~room ~after ~through ~since =
  query t {|SELECT * FROM chat_logs WHERE chat_id = ? AND _id > ? AND _id <= ?
    AND created_at >= ? ORDER BY _id ASC LIMIT ?|}
    [room; Int64.to_string after; Int64.to_string through; Printf.sprintf "%.0f" since; "200"]

let reply t ~room ~body =
  Net.json ~timeout:t.config.http_timeout `POST (Net.endpoint t.config.iris_url "/reply")
    ~body:(`Assoc ["type", `String "text"; "room", `String room; "data", `String body])
  >|= function
  | Error error -> Error error
  | Ok json -> (match Json_util.protect (fun () -> Json_util.required "success" json |> Json_util.bool) with
                | Ok true -> Ok () | _ -> Error Net.Invalid_json)

let observed_reply t ~room ~after ~body =
  query t "SELECT * FROM chat_logs WHERE chat_id = ? AND _id > ? AND user_id = ? ORDER BY _id DESC LIMIT 20"
    [room; Int64.to_string after; t.config.bot_id]
  >|= function
  | Error error -> Error error
  | Ok rows ->
      let messages = List.filter_map (fun row -> match Iris_event.of_query_row
          ~source:t.config.source_id ~bot_id:t.config.bot_id row with Ok message -> Some message | Error _ -> None) rows in
      Ok (List.find_opt (fun (message : Types.message) -> message.is_bot && message.text = body && message.seq > after) messages)

let configuration t = Net.json ~timeout:t.config.http_timeout `GET (Net.endpoint t.config.iris_url "/config")

let room_names t room =
  query t {|SELECT user_id,nickname AS name,enc FROM db2.open_chat_member
    WHERE involved_chat_id = ? OR link_id = (SELECT link_id FROM chat_rooms WHERE id = ? AND link_id<>0)
    ORDER BY CASE WHEN involved_chat_id = ? THEN 0 ELSE 1 END,_id DESC|} [room;room;room]
  >|= function
  | Error error->Error error
  | Ok rows ->
      let seen=Hashtbl.create 64 in
      Ok (List.filter_map (fun row ->
        match Json_util.protect (fun ()->
          let id=Json_util.required "user_id" row |> Json_util.id in
          let name=Json_util.required "name" row |> Json_util.string |> String.trim in
          id,name) with
        | Ok (id,name) when name<>"" && not(Hashtbl.mem seen id) ->
            Hashtbl.add seen id ();Some(id,Utf8.take 512 name)
        | _ -> None) rows)

let find_anchor t ~room ~native_id ~since =
  query t "SELECT * FROM chat_logs WHERE chat_id = ? AND id = ? AND created_at >= ? LIMIT 2"
    [room; native_id; Printf.sprintf "%.0f" since]

let configure_endpoint t endpoint =
  Net.json ~timeout:t.config.http_timeout `POST (Net.endpoint t.config.iris_url "/config/endpoint")
    ~body:(`Assoc ["endpoint",`String endpoint])
