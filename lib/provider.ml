(* Wire-format differences belong here. "auto" preserves legacy configurations. *)
type embedding_backend = Openrouter | Openai_compatible | Jina

let embedding_backend config =
  match config.Config.embedding_backend with
  | "jina" -> Jina
  | "openai_compatible" -> Openai_compatible
  | "openrouter" -> Openrouter
  | _ -> if Config.local_embeddings config then Jina else Openrouter

let chat_headers config session =
  if config.Config.chat_backend="opencode_go" then ["x-opencode-session",session] else []

let chat_provider config =
  let fields = ["require_parameters",`Bool true;"data_collection",`String "deny"] in
  `Assoc (fields @ if config.Config.chat_provider_only=[] then [] else
    ["only",`List(List.map(fun x->`String x) config.chat_provider_only);"allow_fallbacks",`Bool false])

let chat_options config reasoning =
  if config.Config.chat_backend="opencode_go" then
    (* Go's GLM endpoint rejects thinking; preserve reasoning_content by turn. *)
    if Config.go_glm config then [] else
      ["thinking",`Assoc ["type",`String (if config.reasoning_enabled then "enabled" else "disabled")]]
  else ["reasoning",reasoning;"provider",chat_provider config]

let embedding_dimensions config =
  if embedding_backend config=Openrouter && config.Config.embedding_model="google/gemini-embedding-001"
  then Some 3072 else None

let embedding_batch_size config = if embedding_backend config=Jina then 1 else 16

(* Keep existing cache IDs for legacy wire formats. A newly selected format at
   the same model/URL must not consume vectors made from differently prefixed text. *)
let embedding_cache_model config =
  let legacy=if Config.local_embeddings config then Jina else Openrouter in
  let backend=embedding_backend config in
  if backend=legacy then config.Config.embedding_model else
    config.embedding_model ^ ":asko-format:" ^
      (match backend with Openrouter->"openrouter" | Openai_compatible->"openai-compatible" | Jina->"jina")

let embedding_body config ~query inputs =
  let backend=embedding_backend config in
  let prefix=if backend=Jina then (if query then "Query: " else "Document: ") else "" in
  let fields=["model",`String config.Config.embedding_model;
    "input",`List(List.map(fun text->`String(prefix^text)) inputs);"encoding_format",`String "float"] in
  let fields=match embedding_dimensions config with
    | Some dimensions -> fields @ ["dimensions",`Int dimensions;
        "input_type",`String(if query then "search_query" else "search_document")]
    | None -> fields in
  `Assoc (fields @ if backend=Openrouter && not(Config.local_embeddings config) then
    ["provider",`Assoc ["data_collection",`String "deny"]] else [])
