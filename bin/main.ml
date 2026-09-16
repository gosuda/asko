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
        (fun () -> Lwt_main.run (Server.run ~stop config store))))

let () =
  ignore (Unix.umask 0o077);
  Printexc.record_backtrace true;
  let command = if Array.length Sys.argv > 1 then Sys.argv.(1) else "help" in
  let config_path = ref "config.local.json" in
  let rest = if Array.length Sys.argv > 2 then Array.sub Sys.argv 2 (Array.length Sys.argv - 2) else [||] in
  let args = Array.append [|Sys.argv.(0)|] rest in
  (try Arg.parse_argv args ["--config", Arg.Set_string config_path, "Configuration JSON file"]
       (fun _ -> raise (Arg.Bad "unexpected argument")) "asko COMMAND [--config path]"
   with Arg.Bad message -> prerr_endline message; exit 2
      | Arg.Help message -> print_endline message; exit 0);
  try
    match command with
    | "version" | "--version" -> Printf.printf "asko 0.1.0 (OCaml %s)\n" Sys.ocaml_version
    | "serve" -> serve (configuration !config_path)
    | "status" -> let config = configuration !config_path in
        with_store config (fun store -> print_endline (Yojson.Safe.pretty_to_string (Store.stats store)))
    | "check-config" ->
        let c = configuration !config_path in
        print_endline (Yojson.Safe.pretty_to_string (`Assoc [
          "valid", `Bool true; "dry_run", `Bool c.dry_run; "allowed_rooms", `Int (List.length c.rooms);
          "model", `String c.model; "api_key_present", `Bool (Config.api_key c <> None);
          "ingest_token_present", `Bool (Config.ingest_token c <> None)]))
    | "probe-https" ->
        let uri = Uri.of_string "https://openrouter.ai/api/v1/models" in
        (match Lwt_main.run (Net.request ~limit:8388608 ~timeout:30. `GET uri) with
         | Ok (200, body) -> Printf.printf "{\"https\":true,\"status\":200,\"bytes\":%d}\n" (String.length body)
         | Ok (status, _) -> die ("HTTPS probe status " ^ string_of_int status)
         | Error error -> die ("HTTPS probe failed: " ^ Net.error_name error))
    | _ -> print_endline "asko serve | status | check-config | probe-https | version [--config path]"
  with
  | Store.Error error -> die ("database error: " ^ error)
  | Sys_error _ -> die "filesystem operation failed"
  | Unix.Unix_error (error, _, _) -> die (Unix.error_message error)
