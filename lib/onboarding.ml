open Lwt.Infix

let profile name =
  let common=["source_id",`String "iris:phone:1";"port",`Int 8080;
    "db_path",`String "var/asko.sqlite";"iris_url",`String "http://127.0.0.1:3000";
    "bot_id",`String "";"rooms",`List [];"dry_run",`Bool true;
    "ingest_token_env",`String "ASKO_INGEST_TOKEN"] in
  let router=["chat_backend",`String "openrouter";"chat_url",`String Config.default.openrouter_url;
    "model",`String Config.default.model;"api_key_env",`String "OPENROUTER_API_KEY"] in
  let embedding=["embedding_backend",`String "openrouter";
    "embedding_url",`String Config.default.embedding_url;
    "embedding_model",`String Config.default.embedding_model] in
  match name with
  | "openrouter" -> Ok (`Assoc (common @ router @ embedding))
  | "opencode-go" -> Ok (`Assoc (common @ [
      "chat_backend",`String "opencode_go";"chat_url",`String "https://opencode.ai/zen/go/v1";
      "model",`String "glm-5.3-flash";"api_key_env",`String "OPENCODE_GO_API_KEY";
      "response_format",`String "json_object";"reasoning_enabled",`Bool true;"reasoning_max_tokens",`Int 8192;
      "max_output_tokens",`Int 16000;"api_key_embed_env",`String "ASKO_EMBEDDING_API_KEY"] @ embedding))
  | "local-jina" -> Ok (`Assoc (common @ router @ [
      "embedding_backend",`String "jina";"embedding_url",`String "http://127.0.0.1:8081/v1";
      "embedding_model",`String "jina-v5-nano-retrieval-q8"]))
  | _ -> Error "profile must be openrouter, opencode-go, or local-jina"

let init ~path ~name =
  match profile name with
  | Error error -> Error error
  | Ok json ->
      try
        Store.mkdir (Filename.dirname path);
        let fd=Unix.openfile path [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_EXCL;Unix.O_CLOEXEC] 0o600 in
        let channel=Unix.out_channel_of_descr fd in
        (try output_string channel (Yojson.Safe.pretty_to_string json ^ "\n"); close_out channel; Ok ()
         with exn -> close_out_noerr channel; (try Unix.unlink path with _->()); raise exn)
      with
      | Unix.Unix_error (Unix.EEXIST,_,_) -> Error "configuration already exists; choose another --config path"
      | Unix.Unix_error _ | Sys_error _ -> Error "cannot create configuration file"

let check ?hint name status detail =
  `Assoc (["name",`String name;"status",`String status;"detail",`String detail] @
    match hint with None->[] | Some value->["hint",`String value])

let ready checks = not(List.exists(fun c->
  List.mem (Json_util.field "status" c) [Some(`String "missing");Some(`String "error")]) checks)

let rec writable_parent path =
  if Sys.file_exists path then
    try Sys.is_directory path && (Unix.access path [Unix.W_OK;Unix.X_OK];true) with _->false
  else let parent=Filename.dirname path in parent<>path && writable_parent parent

let offline_checks ~path config =
  let configured present name detail hint = check ~hint name (if present then "ok" else "missing") detail in
  [check "configuration" "ok" "Configuration parsed.";
   configured (config.Config.bot_id<>"" && config.bot_id<>"0") "bot_id"
     (if config.bot_id<>"" && config.bot_id<>"0" then "Bot identity is configured." else "Bot identity is missing.")
     "Use iris-info after the bot account has sent a message; save its nonzero bot_id.";
   configured (config.rooms<>[]) "rooms"
     (Printf.sprintf "%d rooms enabled." (List.length config.rooms))
     "Use rooms to list OpenChat IDs, then explicitly add the chosen IDs as strings to rooms.";
   configured (Config.api_key config<>None) "chat_key"
     (if Config.api_key config<>None then "Chat key is available (not verified)." else "Chat key is missing.")
     "Set the environment variable named by api_key_env, or api_key in the private config.";
   (if Config.local_embeddings config then
      check "embedding_key" "ok" "Local embeddings do not send an API key."
    else configured (Config.api_key_embed config<>None) "embedding_key"
      (if Config.api_key_embed config<>None then "Embedding key is available (not verified)." else "Embedding key is missing.")
      "Set api_key_embed_env or api_key_embed; a different remote endpoint never inherits the chat key.");
   configured (Config.ingest_token config<>None) "ingest_token"
     (if Config.ingest_token config<>None then "Webhook token is available." else "Webhook token is missing.")
     "Phone deployment generates this token. Load it before running configure-iris.";
   (let writable=try
      if Sys.file_exists config.db_path then
        (Unix.stat config.db_path).Unix.st_kind=Unix.S_REG
        && (Unix.access config.db_path [Unix.W_OK]; writable_parent(Filename.dirname config.db_path))
      else writable_parent(Filename.dirname config.db_path)
      with _->false in
    check ~hint:"Check the database directory permissions; doctor never creates or opens the database."
      "storage" (if writable then "ok" else "error")
      (if writable then "Database location is writable." else "Database path must be a writable regular file or a new file in a writable directory."));
   (let private_file=try (Unix.stat path).Unix.st_perm land 0o077=0 with _->false in
    check ~hint:"Use chmod 600 on a config containing credentials." "config_permissions"
      (if private_file then "ok" else "warning")
      (if private_file then "Configuration is private." else "Configuration is readable by other users."));
   check ~hint:"Keep dry_run enabled during setup. Model calls can still consume usage."
     "delivery" (if config.dry_run then "warning" else "ok")
     (if config.dry_run then "Dry-run suppresses replies." else "Live delivery is enabled.")]

let callback_matches config json =
  match Json_util.protect(fun ()->Json_util.required "web_server_endpoint" json |> Json_util.string),
        Config.ingest_token config with
  | Ok endpoint,Some token ->
      let uri=Uri.of_string endpoint in
      Uri.scheme uri=Some "http" && Uri.host uri=Some "127.0.0.1"
      && Uri.port uri=Some config.Config.port && Uri.path uri="/events/iris"
      && Uri.get_query_param uri "token"=Some token
  | _ -> false

let online_checks config =
  let config={config with Config.http_timeout=min 5. config.Config.http_timeout} in
  Iris.configuration(Iris.create config) >>= fun iris ->
  let iris_checks=match iris with
    | Error error -> [check ~hint:"Check Iris installation, its protected local port, and the Termux account."
        "iris" "error" ("Iris unavailable: "^Net.error_name error)]
    | Ok json ->
        let bot=Json_util.protect(fun ()->Json_util.required "bot_id" json |> Json_util.id) in
        let matched=match bot with Ok id->id<>"0" && id<>"" && id=config.bot_id | Error _->false in
        [check "iris" "ok" "Iris configuration endpoint is reachable.";
         check ~hint:"Run iris-info and save the nonzero bot ID; check the bot has sent a message."
           "iris_identity" (if matched then "ok" else "error")
           (if matched then "Iris identity matches." else "Iris identity is missing or does not match.");
         check ~hint:"Run configure-iris with the webhook token loaded."
           "iris_callback" (if callback_matches config json then "ok" else "error")
           (if callback_matches config json then "Authenticated callback matches." else "Authenticated callback is not configured for this backend.")] in
  let health=Uri.of_string(Printf.sprintf "http://127.0.0.1:%d/health" config.port) in
  Net.json ~timeout:5. `GET health >|= fun result ->
  let serving=match result with
    | Ok json -> (match Json_util.protect(fun ()->Json_util.field "ok" json=Some(`Bool true)
        && Json_util.field "dry_run" json=Some(`Bool config.dry_run)
        && Json_util.field "allowed_rooms" json=Some(`Int(List.length config.rooms))
        && Json_util.field "scope_fingerprint" json=Some(`String(Config.scope_fingerprint config))) with
        | Ok value -> value | Error _ -> false)
    | Error _ -> false in
  iris_checks @ [check ~hint:"Start or restart asko with this configuration, then rerun doctor --online."
    "backend" (if serving then "ok" else "error")
    (if serving then "Backend is reachable with matching source, bot identity, allowed rooms, and delivery mode."
     else "Backend is unavailable or its reported configuration differs.")]

let doctor ~path ~online =
  match Config.load ~require_credentials:false path with
  | Error error -> Lwt.return (`Assoc ["ready",`Bool false;"online",`Bool online;
      "checks",`List [check "configuration" "error" error]],false)
  | Ok config ->
      (if online then online_checks config else Lwt.return [check "connectivity" "skipped"
        "Use --online on the backend host to check Iris and asko. No model calls are made."]) >|= fun connectivity ->
      let checks=offline_checks ~path config @ connectivity in
      let ready=ready checks in
      `Assoc ["ready",`Bool ready;"online",`Bool online;"dry_run",`Bool config.dry_run;
        "checks",`List checks],ready
