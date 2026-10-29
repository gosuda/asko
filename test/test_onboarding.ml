open Asko

let check name value = if not value then failwith name
let parse fields = Config.of_json (`Assoc fields) |> Result.get_ok
let input body = Json_util.required "input" body

let () =
  let legacy=parse [] in
  check "legacy defaults remain unchanged"
    (legacy=Config.default && legacy.max_output_tokens=4000 && legacy.reasoning_max_tokens=2048
     && legacy.chat_backend="openrouter" && legacy.embedding_backend="auto");
  check "equal room counts cannot hide a changed allowed scope"
    (Config.scope_fingerprint {legacy with rooms=["A"]}<>Config.scope_fingerprint {legacy with rooms=["B"]});
  check "scope identity ignores ordering and credentials"
    (Config.scope_fingerprint {legacy with rooms=["A";"B"]}=
     Config.scope_fingerprint {legacy with rooms=["B";"A"];api_key="private"});
  let alias=parse ["chat_url",`String "https://example.org/v1";
    "embedding_url",`String "https://example.org/v1"] in
  check "new chat URL resolves to existing runtime field" (alias.openrouter_url="https://example.org/v1");
  check "conflicting chat endpoints rejected" (Result.is_error(Config.of_json (`Assoc [
    "chat_url",`String "https://one.example/v1";"openrouter_url",`String "https://two.example/v1"])));
  List.iter(fun profile->check (profile^" profile parses without credentials")
    (Result.is_ok(Config.of_json (Onboarding.profile profile |> Result.get_ok))))
    ["openrouter";"opencode-go";"local-jina"];
  let key_env="ASKO_TEST_EMBEDDING_KEY" in
  Unix.putenv key_env "";
  let separate=parse ["chat_url",`String "https://chat.example/v1";
    "api_key",`String "chat-secret";"api_key_embed_env",`String key_env] in
  check "empty embedding environment never inherits unrelated chat key" (Config.api_key_embed separate=None);
  Unix.putenv key_env "embed-secret";
  check "separate embedding environment resolved" (Config.api_key_embed separate=Some "embed-secret");
  check "embedding env overrides inline only when opted in"
    (Config.api_key_embed {separate with api_key_embed="inline"}=Some "embed-secret");
  check "legacy inline key precedence unchanged"
    (Config.api_key_embed {separate with api_key_embed_env="";api_key_embed="inline"}=Some "inline");
  Unix.putenv key_env "";
  check "same endpoint with explicit missing embed env does not silently use chat key"
    (Config.api_key_embed {separate with embedding_url=separate.openrouter_url}=None);
  check "legacy shared key preserved"
    (Config.api_key_embed {separate with embedding_url=separate.openrouter_url;api_key_embed_env=""}=Some "chat-secret");
  let original=Provider.embedding_body legacy ~query:true ["hello"] in
  check "legacy remote embedding payload preserved"
    (original=`Assoc ["model",`String legacy.embedding_model;"input",`List [`String "hello"];
      "encoding_format",`String "float";"dimensions",`Int 3072;"input_type",`String "search_query";
      "provider",`Assoc ["data_collection",`String "deny"]]);
  let local={legacy with embedding_url="http://127.0.0.1:8081/v1"} in
  check "legacy local Jina query prefix preserved"
    (input(Provider.embedding_body local ~query:true ["hello"])=`List [`String "Query: hello"]);
  check "legacy local batches preserved" (Provider.embedding_batch_size local=1);
  check "legacy cache identity preserved"
    (Provider.embedding_cache_model local=local.embedding_model && Provider.embedding_cache_model legacy=legacy.embedding_model);
  let generic={local with embedding_backend="openai_compatible"} in
  let body=Provider.embedding_body generic ~query:true ["hello"] in
  check "new wire format cannot reuse Jina document vectors"
    (Provider.embedding_cache_model generic<>Provider.embedding_cache_model local);
  check "generic local server receives neither Jina prefix nor router fields"
    (input body=`List [`String "hello"] && Json_util.field "provider" body=None
     && Json_util.field "input_type" body=None && Provider.embedding_dimensions generic=None);
  check "generic remote server receives no router fields"
    (Json_util.field "provider" (Provider.embedding_body {generic with embedding_url="https://embed.example/v1"}
      ~query:false ["hello"])=None);
  check "unknown embedding provider rejected"
    (Result.is_error(Config.of_json (`Assoc ["embedding_backend",`String "typo"])));
  check "doctor can inspect missing separate key without relaxing runtime parsing"
    (let json=`Assoc ["chat_url",`String "https://chat.example/v1"] in
     Result.is_error(Config.of_json json) && Result.is_ok(Config.of_json ~require_credentials:false json));
  check "callback check never requires printing token"
    (Unix.putenv "ASKO_TEST_WEBHOOK" "synthetic-token";
     let config={legacy with ingest_token_env="ASKO_TEST_WEBHOOK"} in
     let valid=`Assoc ["web_server_endpoint",`String "http://127.0.0.1:8080/events/iris?token=synthetic-token"] in
     Onboarding.callback_matches config valid &&
       not(Onboarding.callback_matches config (`Assoc ["web_server_endpoint",`String "http://127.0.0.1:8080/events/iris?token=wrong"])));
  print_endline "onboarding/provider compatibility checks passed"
