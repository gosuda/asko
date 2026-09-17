open Asko

let die message = prerr_endline message; exit 1
let configuration path = match Config.load path with Ok value -> value | Error message -> die message
let with_store config f =
  let store = Store.open_ config.Config.db_path in
  Fun.protect ~finally:(fun () -> Store.close store) (fun () -> f store)

let serve config =
  Store.mkdir (Filename.dirname config.Config.db_path);
  let lock = Unix.openfile (config.db_path ^ ".lock") [Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close lock) (fun () ->
    (try Unix.lockf lock Unix.F_TLOCK 0 with Unix.Unix_error _ -> die "another asko process owns this database");
    with_store config (fun store ->
      Store.recover_jobs store ~now:(Unix.gettimeofday ());
      let stop, stop_resolver = Lwt.wait () in
      let halt _ = if Lwt.is_sleeping stop then Lwt.wakeup_later stop_resolver () in
      let signals = List.map (fun signal -> Lwt_unix.on_signal signal halt) [Sys.sigint; Sys.sigterm] in
      Fun.protect ~finally:(fun () -> List.iter Lwt_unix.disable_signal_handler signals)
        (fun () -> Lwt_main.run (Engine.run ~stop (Engine.create config store)))))

let () =
  ignore (Unix.umask 0o077);
  Printexc.record_backtrace true;
  let command = if Array.length Sys.argv > 1 then Sys.argv.(1) else "help" in
  let config_path = ref "config.local.json" in
  let output_path = ref "" in
  let rest = if Array.length Sys.argv > 2 then Array.sub Sys.argv 2 (Array.length Sys.argv - 2) else [||] in
  let args = Array.append [|Sys.argv.(0)|] rest in
  (try Arg.parse_argv args ["--config", Arg.Set_string config_path, "Configuration JSON file";
                          "--output", Arg.Set_string output_path, "New backup database path"]
       (fun _ -> raise (Arg.Bad "unexpected argument")) "asko COMMAND [--config path]"
   with Arg.Bad message -> prerr_endline message; exit 2
      | Arg.Help message -> print_endline message; exit 0);
  try
    match command with
    | "version" | "--version" -> Printf.printf "asko 0.1.0 (OCaml %s)\n" Sys.ocaml_version
    | "serve" -> serve (configuration !config_path)
    | "status" -> let config = configuration !config_path in
        with_store config (fun store -> print_endline (Yojson.Safe.pretty_to_string (Store.stats store)))
    | "outbox" -> let config = configuration !config_path in
        with_store config (fun store ->
          Store.recent_outbox store |> List.map (fun (item:Store.outgoing) -> `Assoc [
            "id",`String (Int64.to_string item.id);"job_id",`String (Int64.to_string item.job_id);
            "room_id",`String item.room_id;"state",`String item.state;"body",`String item.body;
            "evidence",(match item.evidence with None->`Null | Some value->Yojson.Safe.from_string value)])
          |> fun rows -> print_endline (Yojson.Safe.pretty_to_string (`List rows)))
    | "backup" ->
        if !output_path="" then die "backup requires --output (existing files are never overwritten)";
        let config=configuration !config_path in
        if not (Sys.file_exists config.db_path) then die "database does not exist; start ingestion before backing up";
        with_store config (fun store -> Store.backup store !output_path; print_endline "backup completed")
    | "iris-info" ->
        let config=configuration !config_path in
        (match Lwt_main.run (Iris.configuration (Iris.create config)) with
         | Error error -> die ("Iris configuration unavailable: " ^ Net.error_name error)
         | Ok json ->
             let bot=match Json_util.protect (fun ()->Json_util.required "bot_id" json |> Json_util.id) with
               | Ok id->`String id | Error _->`Null in
             print_endline (Json_util.to_string (`Assoc ["bot_id",bot;
               "message_send_rate",Option.value ~default:`Null (Json_util.field "message_send_rate" json)])))
    | "configure-iris" ->
        let config=configuration !config_path in
        let token=match Config.ingest_token config with Some value->value | None->die "set the ingest token before configuring Iris" in
        let endpoint=Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/events/iris" config.port)
          |> fun uri -> Uri.add_query_param' uri ("token",token) |> Uri.to_string in
        (match Lwt_main.run (Iris.configure_endpoint (Iris.create config) endpoint) with
         | Ok json when Json_util.field "success" json=Some (`Bool true) -> print_endline "Iris endpoint configured (token redacted)"
         | Ok _ -> die "Iris rejected endpoint configuration"
         | Error error -> die ("Iris configuration failed: " ^ Net.error_name error))
    | "check-config" ->
        let c = configuration !config_path in
        print_endline (Yojson.Safe.pretty_to_string (`Assoc [
          "valid", `Bool true; "dry_run", `Bool c.dry_run; "allowed_rooms", `Int (List.length c.rooms);
          "model", `String c.model; "reasoning_enabled", `Bool c.reasoning_enabled;
          "response_format", `String c.response_format; "api_key_present", `Bool (Config.api_key c <> None);
          "ingest_token_present", `Bool (Config.ingest_token c <> None)]))
    | "probe-https" ->
        let uri = Uri.of_string "https://openrouter.ai/api/v1/models" in
        (match Lwt_main.run (Net.request ~limit:8388608 ~timeout:30. `GET uri) with
         | Ok (200, body) -> Printf.printf "{\"https\":true,\"status\":200,\"bytes\":%d}\n" (String.length body)
         | Ok (status, _) -> die ("HTTPS probe status " ^ string_of_int status)
         | Error error -> die ("HTTPS probe failed: " ^ Net.error_name error))
    | _ -> print_endline "asko serve | status | outbox | check-config | iris-info | configure-iris | backup --output path | probe-https | version [--config path]"
  with
  | Store.Error error -> die ("database error: " ^ error)
  | Sys_error _ -> die "filesystem operation failed"
  | Unix.Unix_error (error, _, _) -> die (Unix.error_message error)
