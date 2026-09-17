open Lwt.Infix

let response status json =
  let headers = Cohttp.Header.of_list ["content-type","application/json; charset=utf-8";
                                      "cache-control","no-store"; "connection","close"] in
  Cohttp_lwt_unix.Server.respond_string ~headers ~status ~body:(Json_util.to_string json) ()
let error status code = response status (`Assoc ["error", `String code])

let equal_secret expected supplied =
  let length = String.length expected in
  let diff = ref (length lxor String.length supplied) in
  for index = 0 to length - 1 do
    let byte = if index < String.length supplied then Char.code supplied.[index] else 0 in
    diff := !diff lor (Char.code expected.[index] lxor byte)
  done;
  !diff = 0

let authorized config request =
  match Config.ingest_token config with
  | None -> true
  | Some expected ->
      let supplied = match Cohttp.Header.get (Cohttp.Request.headers request) "x-asko-token" with
        | Some token -> Some token
        | None -> Uri.get_query_param (Cohttp.Request.uri request) "token" in
      match supplied with Some value -> equal_secret expected value | None -> false

let callback config store _connection request body =
  let uri = Cohttp.Request.uri request in
  match Cohttp.Request.meth request, Uri.path uri with
  | `GET, "/health" ->
      response `OK (`Assoc ["ok", `Bool true; "version", `String "0.1.0";
        "runtime", `String (match Sys.backend_type with Native -> "native" | _ -> "bytecode");
        "ocaml_version", `String Sys.ocaml_version; "dry_run", `Bool config.Config.dry_run;
        "allowed_rooms", `Int (List.length config.rooms); "store", Store.stats store])
  | `POST, "/events/iris" when not (authorized config request) -> error `Unauthorized "unauthorized"
  | `POST, "/events/iris" ->
      Lwt.catch (fun () ->
        Lwt_unix.with_timeout 5. (fun () -> Net.read_body ~limit:1048576 body) >>= fun body ->
        match Json_util.protect (fun () -> Yojson.Safe.from_string body) with
        | Error _ -> error `Bad_request "invalid_json"
        | Ok json ->
            (match Ingest.event ~config ~store ~now:(Unix.gettimeofday ()) json with
             | Error _ -> error `Bad_request "invalid_event"
             | Ok result ->
                 let receipt=Ingest.json result in
                 (match Json_util.field "job_state" receipt with
                  | Some (`String state) when state<>"not_requested" ->
                      prerr_endline (Json_util.to_string (`Assoc ["event",`String "invocation";
                        "state",`String state;"job_id",Option.value ~default:`Null (Json_util.field "job_id" receipt)]))
                  | _ -> ());
                 response `Accepted receipt))
        (function
          | Net.Limit_exceeded -> error `Request_entity_too_large "body_too_large"
          | Lwt_unix.Timeout -> error `Request_timeout "body_timeout"
          | Lwt.Canceled -> Lwt.fail Lwt.Canceled
          | _ -> error `Service_unavailable "storage_unavailable")
  | _ -> error `Not_found "not_found"

let run ?(on_ready=(fun _ -> ())) ~stop config store =
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt socket Unix.SO_REUSEADDR true;
  Lwt_unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, config.Config.port)) >>= fun () ->
  Lwt_unix.listen socket 32;
  let port = match Lwt_unix.getsockname socket with Unix.ADDR_INET (_, port) -> port | _ -> config.port in
  on_ready port;
  Printf.printf "{\"event\":\"listening\",\"host\":\"127.0.0.1\",\"port\":%d}\n%!" port;
  let server = Cohttp_lwt_unix.Server.make ~callback:(callback config store)
      ~conn_closed:(fun _ -> ()) () in
  Cohttp_lwt_unix.Server.create ~stop ~timeout:10 ~backlog:32
    ~on_exn:(fun _ -> prerr_endline "{\"event\":\"http_connection_error\"}")
    ~mode:(`TCP (`Socket socket)) server
