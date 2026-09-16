type t = {
  source_id : string;
  port : int;
  db_path : string;
  iris_url : string;
  bot_id : string;
  aliases : string list;
  rooms : string list;
  dry_run : bool;
  retention_days : int;
  recovery_interval : float;
  request_ttl : float;
  cooldown : float;
  http_timeout : float;
  send_interval : float;
  confirm_timeout : float;
  max_input_bytes : int;
  max_history_bytes : int;
  max_response_bytes : int;
  max_output_tokens : int;
  daily_budget_tokens : int;
  openrouter_url : string;
  model : string;
  embedding_model : string;
  api_key_env : string;
  ingest_token_env : string;
  allow_insecure_loopback : bool;
}

let default = {
  source_id="iris:phone:1"; port=8080; db_path="var/asko.sqlite";
  iris_url="http://127.0.0.1:3000"; bot_id=""; aliases=["요약봇"]; rooms=[];
  dry_run=true; retention_days=7; recovery_interval=30.; request_ttl=300.;
  cooldown=20.; http_timeout=45.; send_interval=1.; confirm_timeout=15.;
  max_input_bytes=240000; max_history_bytes=2000000; max_response_bytes=7000; max_output_tokens=1800; daily_budget_tokens=500000;
  openrouter_url="https://openrouter.ai/api/v1";
  model="google/gemini-3.1-flash-lite";
  embedding_model="openai/text-embedding-3-small";
  api_key_env="OPENROUTER_API_KEY"; ingest_token_env="ASKO_INGEST_TOKEN";
  allow_insecure_loopback=false;
}

let of_json json = Json_util.protect (fun () ->
  let d = default in
  let open Json_util in
  let s name value = default string value (field name json) in
  let i name value = default int value (field name json) in
  let f name value = default float value (field name json) in
  let b name value = default bool value (field name json) in
  let strings name value = default (list string) value (field name json) in
  let c = {
    source_id=s "source_id" d.source_id; port=i "port" d.port;
    db_path=s "db_path" d.db_path; iris_url=s "iris_url" d.iris_url;
    bot_id=s "bot_id" d.bot_id; aliases=strings "aliases" d.aliases;
    rooms=strings "rooms" d.rooms; dry_run=b "dry_run" d.dry_run;
    retention_days=i "retention_days" d.retention_days;
    recovery_interval=f "recovery_interval" d.recovery_interval;
    request_ttl=f "request_ttl" d.request_ttl; cooldown=f "cooldown" d.cooldown;
    http_timeout=f "http_timeout" d.http_timeout;
    send_interval=f "send_interval" d.send_interval;
    confirm_timeout=f "confirm_timeout" d.confirm_timeout;
    max_input_bytes=i "max_input_bytes" d.max_input_bytes;
    max_history_bytes=i "max_history_bytes" d.max_history_bytes;
    max_response_bytes=i "max_response_bytes" d.max_response_bytes;
    max_output_tokens=i "max_output_tokens" d.max_output_tokens;
    daily_budget_tokens=i "daily_budget_tokens" d.daily_budget_tokens;
    openrouter_url=s "openrouter_url" d.openrouter_url;
    model=s "model" d.model; embedding_model=s "embedding_model" d.embedding_model;
    api_key_env=s "api_key_env" d.api_key_env;
    ingest_token_env=s "ingest_token_env" d.ingest_token_env;
    allow_insecure_loopback=b "allow_insecure_loopback" d.allow_insecure_loopback;
  } in
  if c.port < 1024 || c.port > 65535 then invalid "port must be 1024..65535";
  if c.source_id = "" || c.db_path = "" then invalid "source_id and db_path are required";
  if c.retention_days < 1 || c.retention_days > 90 then invalid "retention_days must be 1..90";
  if c.request_ttl <= 0. || c.http_timeout <= 0. || c.recovery_interval < 1.
     || c.send_interval < 0.2 || c.cooldown < 0. || c.confirm_timeout <= 0.
  then invalid "invalid timing configuration";
  if c.max_input_bytes < 1000 || c.max_input_bytes > 2000000
     || c.max_history_bytes < c.max_input_bytes || c.max_history_bytes > 16000000
     || c.max_output_tokens < 100 || c.max_output_tokens > 16000
     || c.max_response_bytes < 300 || c.max_response_bytes > 16000 || c.daily_budget_tokens < 1000
  then invalid "invalid model budget";
  let valid_url ~https value =
    let uri = Uri.of_string value in
    let host = Uri.host uri in
    let loopback = List.mem host [Some "127.0.0.1"; Some "localhost"; Some "::1"] in
    let scheme = Uri.scheme uri in
    if host = None || Uri.userinfo uri <> None || Uri.query uri <> [] || Uri.fragment uri <> None
       || not (scheme = Some "https" || (scheme = Some "http" && (not https || (loopback && c.allow_insecure_loopback))))
    then invalid "invalid API URL (HTTPS required for OpenRouter)"
  in
  valid_url ~https:false c.iris_url;
  valid_url ~https:true c.openrouter_url;
  if not c.dry_run && (c.bot_id = "" || c.bot_id = "0") then invalid "bot_id is required before live delivery";
  c)

let load path =
  try of_json (Yojson.Safe.from_file path) with
  | Sys_error _ -> Error "cannot read configuration file"
  | Yojson.Json_error _ -> Error "invalid configuration JSON"
let allowed config room = List.mem room config.rooms
let env_value name = match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None
let api_key config = env_value config.api_key_env
let ingest_token config = env_value config.ingest_token_env
