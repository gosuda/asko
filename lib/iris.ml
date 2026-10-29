open Lwt.Infix
type t = { config : Config.t }
let create config = {config}
let query t ?(operation="query") sql bindings =
  Telemetry.result ~error:Net.error_name ~fields:["operation",`String operation;
    "endpoint",`String "/query";"timeout_seconds",`Float t.config.http_timeout] "iris_http" (fun ()->
  let body = `Assoc ["query", `String sql; "bind", `List (List.map (fun x -> `String x) bindings)] in
  Net.json ~timeout:t.config.http_timeout ~body `POST (Net.endpoint t.config.iris_url "/query")
  >|= function
  | Error error -> Error error
  | Ok json ->
      (match Json_util.protect (fun () -> Json_util.required "data" json |> Json_util.list Fun.id) with
       | Ok rows -> Ok rows | Error _ -> Error Net.Invalid_json))

let latest t room =
  query t ~operation:"latest" "SELECT MAX(_id) AS max_id, MIN(created_at) AS first_at FROM chat_logs WHERE chat_id = ?" [room]
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
  query t ~operation:"history_page" {|SELECT * FROM chat_logs WHERE chat_id = ? AND _id > ? AND _id <= ?
    AND created_at >= ? ORDER BY _id ASC LIMIT ?|}
    [room; Int64.to_string after; Int64.to_string through; Printf.sprintf "%.0f" since; "200"]

let reply t ~room ~body =
  Telemetry.result ~error:Net.error_name ~fields:["operation",`String "reply";"endpoint",`String "/reply"] "iris_http" (fun ()->
  Net.json ~timeout:t.config.http_timeout `POST (Net.endpoint t.config.iris_url "/reply")
    ~body:(`Assoc ["type", `String "text"; "room", `String room; "data", `String body])
  >|= function
  | Error error -> Error error
  | Ok json -> (match Json_util.protect (fun () -> Json_util.required "success" json |> Json_util.bool) with
                | Ok true -> Ok () | _ -> Error Net.Invalid_json))

let observed_reply t ~room ~after ~body =
  query t ~operation:"delivery_echo" "SELECT * FROM chat_logs WHERE chat_id = ? AND _id > ? AND user_id = ? ORDER BY _id DESC LIMIT 20"
    [room; Int64.to_string after; t.config.bot_id]
  >|= function
  | Error error -> Error error
  | Ok rows ->
      let messages = List.filter_map (fun row -> match Iris_event.of_query_row
          ~source:t.config.source_id ~bot_id:t.config.bot_id row with Ok message -> Some message | Error _ -> None) rows in
      Ok (List.find_opt (fun (message : Types.message) -> message.is_bot && message.text = body && message.seq > after) messages)

let configuration t = Telemetry.result ~error:Net.error_name
  ~fields:["operation",`String "configuration";"endpoint",`String "/config"] "iris_http" (fun ()->
  Net.json ~timeout:t.config.http_timeout `GET (Net.endpoint t.config.iris_url "/config"))

(* Explicit setup command only: room metadata, never message bodies or membership. *)
let rooms t =
  query t ~operation:"list_rooms" {|SELECT r.id AS room_id, r.private_meta, l.name AS name
    FROM chat_rooms r LEFT JOIN db2.open_link l ON l.id = r.link_id
    WHERE r.link_id IS NOT NULL AND r.link_id <> 0 ORDER BY r.id|} []
  >|= function
  | Error error -> Error error
  | Ok rows ->
      (match Json_util.protect(fun ()->List.map(fun row->
        let id=Json_util.required "room_id" row |> Json_util.id in
        let custom=match Json_util.field "private_meta" row with
          | None | Some `Null -> None
          | Some value -> (match Json_util.protect(fun ()->
              Json_util.json_string value |> Json_util.field "name" |> Json_util.optional Json_util.string) with
              | Ok name -> name | Error _ -> None) in
        let name=match custom with
          | Some name when String.trim name<>"" -> Some name
          | _ -> Json_util.optional Json_util.string (Json_util.field "name" row) in
        id,Option.map (Utf8.take 512) name) rows) with
       | Ok rooms -> Ok rooms | Error _ -> Error Net.Invalid_json)

let room_names t room =
  query t ~operation:"room_names" {|SELECT user_id,nickname AS name,enc FROM db2.open_chat_member
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
  query t ~operation:"reply_anchor" "SELECT * FROM chat_logs WHERE chat_id = ? AND id = ? AND created_at >= ? LIMIT 2"
    [room; native_id; Printf.sprintf "%.0f" since]

let configure_endpoint t endpoint =
  Net.json ~timeout:t.config.http_timeout `POST (Net.endpoint t.config.iris_url "/config/endpoint")
    ~body:(`Assoc ["endpoint",`String endpoint])
