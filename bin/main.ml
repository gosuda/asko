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
  let embedding_model = ref "" in
  let job_id = ref 0 in
  let rest = if Array.length Sys.argv > 2 then Array.sub Sys.argv 2 (Array.length Sys.argv - 2) else [||] in
  let args = Array.append [|Sys.argv.(0)|] rest in
  (try Arg.parse_argv args ["--config", Arg.Set_string config_path, "Configuration JSON file";
                          "--output", Arg.Set_string output_path, "New backup database path";
                          "--embedding-model", Arg.Set_string embedding_model, "Embedding model override for this command";
                          "--job-id", Arg.Set_int job_id, "Historical job for replay (never sends)"]
       (fun _ -> raise (Arg.Bad "unexpected argument")) "asko COMMAND [--config path]"
   with Arg.Bad message -> prerr_endline message; exit 2
      | Arg.Help message -> print_endline message; exit 0);
  let get_config () =
    let config=configuration !config_path in
    if !embedding_model="" then config else {config with embedding_model= !embedding_model} in
  try
    match command with
    | "version" | "--version" -> Printf.printf "asko 0.1.0 (OCaml %s)\n" Sys.ocaml_version
    | "serve" -> serve (get_config ())
    | "status" -> let config = get_config () in
        with_store config (fun store -> print_endline (Yojson.Safe.pretty_to_string (Store.stats store)))
    | "diagnose-jobs" ->
        let config=get_config () in
        with_store config (fun store ->
          let now=Unix.gettimeofday () in
          let rows=Store.rows store {|SELECT j.id,j.state,j.created_at,j.available_at,j.expires_at,
            j.last_error,o.state,o.error FROM jobs j LEFT JOIN outbox o ON o.job_id=j.id
            ORDER BY j.id DESC LIMIT 12|} [] (fun s ->
            let optional i=Json_util.option (fun x->`String x) (Store.optional_text s i) in
            `Assoc ["job_id",`String(Int64.to_string(Sqlite3.column_int64 s 0));
              "state",`String(Sqlite3.column_text s 1);
              "age_seconds",`Int(int_of_float(now-.Sqlite3.column_double s 2));
              "ready_in_seconds",`Int(int_of_float(Sqlite3.column_double s 3-.now));
              "expires_in_seconds",`Int(int_of_float(Sqlite3.column_double s 4-.now));
              "job_error",optional 5;"delivery_state",optional 6;"delivery_error",optional 7]) in
          print_endline(Json_util.to_string (`List rows)))
    | "sync-names" ->
        let config=get_config () in
        with_store config (fun store -> Lwt_main.run (
          let open Lwt.Infix in
          Lwt_list.iter_s (fun room -> Iris.room_names (Iris.create config) room >|= function
            | Error error -> die ("Nickname sync failed: " ^ Net.error_name error)
            | Ok names ->
                Store.transaction store (fun () -> List.iter (fun (user_id,name) ->
                  Store.observe_name store ~source:config.source_id ~room ~user_id ~name
                    ~at:(Unix.gettimeofday ()) ~current:true) names);
                print_endline(Json_util.to_string (`Assoc ["room_id",`String room;"profiles",`Int(List.length names)]))
            ) config.rooms))
    | "outbox" -> let config = get_config () in
        with_store config (fun store ->
          Store.recent_outbox store |> List.map (fun (item:Store.outgoing) -> `Assoc [
            "id",`String (Int64.to_string item.id);"job_id",`String (Int64.to_string item.job_id);
            "room_id",`String item.room_id;"state",`String item.state;"body",`String item.body;
            "evidence",(match item.evidence with None->`Null | Some value->Yojson.Safe.from_string value)])
          |> fun rows -> print_endline (Yojson.Safe.pretty_to_string (`List rows)))
    | "backfill-embeddings" ->
        let config=get_config () in
        with_store config (fun store -> Lwt_main.run (
          let open Lwt.Infix in
          Lwt_list.iter_s (fun room ->
            let now=Unix.gettimeofday () in
            let upper=Store.one store "SELECT MAX(seq) FROM messages WHERE source=? AND room_id=?"
              [Store.text config.source_id;Store.text room]
              (fun s->if Sqlite3.column_is_null s 0 then 0L else Sqlite3.column_int64 s 0)
              |> Option.value ~default:0L in
            let since=now-.float_of_int(config.retention_days*86400) in
            let range={Types.source=config.source_id;room_id=room;lower=Types.At_time since;
              before_seq=Int64.succ upper;through_time=now;retention_start=since;note=None} in
            let messages=Store.messages ~max_bytes:config.max_history_bytes store range
              |> Store.with_speaker_names store ~source:config.source_id ~room in
            let version=Store.room_version store ~source:config.source_id ~room in
            let progress done_ total=print_endline(Json_util.to_string (`Assoc [
              "event",`String "embedding_backfill";"room",`String room;"model",`String config.embedding_model;
              "messages",`Int(List.length messages);"through_seq",`String(Int64.to_string upper);
              "completed_chunks",`Int done_;"total_chunks",`Int total])) in
            Retrieval.index ~progress ~config ~store ~llm:(Llm.create config store) ~range ~version messages
            >|= function Ok _->() | Error error->die(Json_util.to_string(Llm.error_details error))
          ) config.rooms))
    | "replay-job" ->
        if !job_id<=0 then die "replay-job requires --job-id; it never queues or sends a reply";
        let config=get_config () in
        with_store config (fun store ->
          let source,seq,prompt=match Store.one store "SELECT source,request_seq,prompt FROM jobs WHERE id=?"
            [Store.integer(Int64.of_int !job_id)]
            (fun s->Sqlite3.column_text s 0,Sqlite3.column_int64 s 1,Sqlite3.column_text s 2) with
            | None->die "job unavailable" | Some value->value in
          let message=Store.get_message store ~source ~seq |> Option.get in
          if source<>config.source_id || not(Config.allowed config message.room_id) then die "room not allowed";
          let request={Types.message;trigger=Types.Mention;prompt} in
          let since=Unix.gettimeofday ()-.float_of_int(config.retention_days*86400) in
          let range={Types.source;room_id=message.room_id;lower=Types.At_time since;
            before_seq=seq;through_time=message.created_at;retention_start=since;note=None} in
          let history=Store.messages ~max_bytes:config.max_history_bytes store range
            |> Store.with_speaker_names store ~source ~room:message.room_id in
          let engine=Engine.create config store in
          Lwt_main.run (let open Lwt.Infix in
            Engine.reply_context engine message since >>= fun anchor->
            let reference=Store.answer_reference store message anchor in
            Conversation.run ~config ~store ~llm:(Llm.create config store) ~name_messages:Lwt.return
              ~request ~anchor ~reference ~history ~range
              ~version:(Store.room_version store ~source ~room:message.room_id) >|= function
            | Error error->die(Json_util.to_string(Llm.error_details error))
            | Ok result->print_endline(Json_util.to_string (`Assoc ["sent",`Bool false;
                "job_id",`Int !job_id;"coverage",result.Conversation.coverage;
                "answer",`String(Summary.render_answer ~max_bytes:config.max_response_bytes
                  ~messages:result.evidence_messages result.answer)]))))
    | "backup" ->
        if !output_path="" then die "backup requires --output (existing files are never overwritten)";
        let config=get_config () in
        if not (Sys.file_exists config.db_path) then die "database does not exist; start ingestion before backing up";
        with_store config (fun store -> Store.backup store !output_path; print_endline "backup completed")
    | "iris-info" ->
        let config=get_config () in
        (match Lwt_main.run (Iris.configuration (Iris.create config)) with
         | Error error -> die ("Iris configuration unavailable: " ^ Net.error_name error)
         | Ok json ->
             let bot=match Json_util.protect (fun ()->Json_util.required "bot_id" json |> Json_util.id) with
               | Ok id->`String id | Error _->`Null in
             print_endline (Json_util.to_string (`Assoc ["bot_id",bot;
               "message_send_rate",Option.value ~default:`Null (Json_util.field "message_send_rate" json)])))
    | "configure-iris" ->
        let config=get_config () in
        let token=match Config.ingest_token config with Some value->value | None->die "set the ingest token before configuring Iris" in
        let endpoint=Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/events/iris" config.port)
          |> fun uri -> Uri.add_query_param' uri ("token",token) |> Uri.to_string in
        (match Lwt_main.run (Iris.configure_endpoint (Iris.create config) endpoint) with
         | Ok json when Json_util.field "success" json=Some (`Bool true) -> print_endline "Iris endpoint configured (token redacted)"
         | Ok _ -> die "Iris rejected endpoint configuration"
         | Error error -> die ("Iris configuration failed: " ^ Net.error_name error))
    | "embedding-mode" ->
        let c=get_config () in
        print_endline (if Config.local_embeddings c then "local" else "remote")
    | "diagnose-recovery" ->
        let config=get_config () in
        with_store config (fun store -> Lwt_main.run (
          let open Lwt.Infix in
          Lwt_list.iter_s (fun room ->
            let cursor=Store.cursor store ~source:config.source_id ~room in
            let report fields=print_endline (Json_util.to_string (`Assoc (
              ["room_id",`String room;"cursor",`String(Int64.to_string cursor)] @ fields))) in
            let iris=Iris.create config in
            Iris.latest iris room >>= function
            | Error error -> report ["stage",`String "latest";"error",`String(Net.error_name error)]; Lwt.return_unit
            | Ok (latest,_) ->
                Iris.page iris ~room ~after:cursor ~through:latest
                  ~since:(Unix.gettimeofday () -. float_of_int(config.retention_days*86400))
                >|= function
                | Error error -> report ["stage",`String "page";"error",`String(Net.error_name error)]
                | Ok rows ->
                    let kind = function `Assoc _->"object" | `List _->"array" | `Null->"null" | `String _->"string" | _->"scalar" in
                    let bad=List.filter_map (fun row ->
                      match Iris_event.of_query_row ~source:config.source_id ~bot_id:config.bot_id row with
                      | Ok _ -> None
                      | Error reason ->
                          let embedded field=try kind(Iris_event.embedded field row) with _->"invalid" in
                          let id=match Json_util.protect (fun ()->Json_util.required "_id" row |> Json_util.id) with Ok id->id | Error _->"missing" in
                          let bytes=match Json_util.field "message" row with Some (`String text)->String.length text | _->0 in
                          Some (`Assoc ["id",`String id;"reason",`String reason;"message_bytes",`Int bytes;
                            "attachment_type",`String(embedded "attachment");"metadata_type",`String(embedded "v")])) rows in
                    report ["latest",`String(Int64.to_string latest);"rows",`Int(List.length rows);"invalid_rows",`List bad]
          ) config.rooms))
    | "check-config" ->
        let c = get_config () in
        print_endline (Yojson.Safe.pretty_to_string (`Assoc [
          "valid", `Bool true; "dry_run", `Bool c.dry_run; "allowed_rooms", `Int (List.length c.rooms);
          "model", `String c.model; "reasoning_enabled", `Bool c.reasoning_enabled;
          "embedding_model", `String c.embedding_model; "embedding_url", `String c.embedding_url;
          "response_format", `String c.response_format; "api_key_present", `Bool (Config.api_key c <> None);
          "ingest_token_present", `Bool (Config.ingest_token c <> None)]))
    | "probe-https" ->
        let uri = Uri.of_string "https://openrouter.ai/api/v1/models" in
        (match Lwt_main.run (Net.request ~limit:8388608 ~timeout:30. `GET uri) with
         | Ok (200, body) -> Printf.printf "{\"https\":true,\"status\":200,\"bytes\":%d}\n" (String.length body)
         | Ok (status, _) -> die ("HTTPS probe status " ^ string_of_int status)
         | Error error -> die ("HTTPS probe failed: " ^ Net.error_name error))
    | _ -> print_endline "asko serve | status | outbox | check-config | iris-info | configure-iris | sync-names | diagnose-recovery | diagnose-jobs | backfill-embeddings | replay-job --job-id ID | backup --output path | probe-https | version [--config path]"
  with
  | Store.Error error -> die ("database error: " ^ error)
  | Sys_error _ -> die "filesystem operation failed"
  | Unix.Unix_error (error, _, _) -> die (Unix.error_message error)
