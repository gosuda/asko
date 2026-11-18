open Lwt.Infix

(* Parallel Search and Extract (v1). Search finds pages; Extract reads pages the
   local fetcher cannot (JavaScript rendering, PDFs, blocked user agents). *)

let text key json = match Json_util.field key json with Some(`String value)->value | _->""
let strings key json = match Json_util.field key json with
  | Some(`List values)->List.filter_map(function `String value->Some value | _->None) values | _->[]
let items key json = match Json_util.field key json with Some(`List values)->values | _->[]
let clip bytes value = if String.is_valid_utf_8 value then Utf8.take bytes value else ""

let post config ~operation path body =
  match Config.search_key config with
  | None -> Lwt.return (Error "web_search_not_configured")
  | Some key ->
      Telemetry.result ~error:Net.error_name ~fields:["operation",`String operation] "web_api" (fun ()->
        Net.json ~headers:["x-api-key",key] ~body ~timeout:(min 60. config.Config.http_timeout) `POST
          (Net.endpoint config.search_url path))
      >|= Result.map_error (fun error->"web_api_" ^ Net.error_name error)

let search config ~objective ~queries =
  let body=`Assoc ["objective",`String objective;
    "search_queries",`List(List.map(fun query->`String query) queries);
    "mode",`String "basic";
    "advanced_settings",`Assoc ["max_results",`Int 8;
      "excerpt_settings",`Assoc ["max_chars_per_result",`Int 2000]]] in
  post config ~operation:"search" "/v1/search" body >|= function
  | Error reason -> Error reason
  | Ok json -> Ok (items "results" json |> Retrieval.take 8 |> List.filter_map (fun item ->
      match text "url" item with
      | "" -> None
      | url -> Some (url,clip 300 (text "title" item),text "publish_date" item,
          List.map (clip 6000) (strings "excerpts" item))))

(* Returns the page title and Markdown text. *)
let extract config ~url ~objective =
  let body=`Assoc ["urls",`List [`String url];"objective",`String objective;
    "advanced_settings",`Assoc ["full_content",`Assoc ["max_chars_per_result",`Int 100000]]] in
  post config ~operation:"extract" "/v1/extract" body >|= function
  | Error reason -> Error reason
  | Ok json -> (match items "results" json with
      | item::_ ->
          let content=match text "full_content" item with
            | "" -> String.concat "\n\n" (strings "excerpts" item) | value -> value in
          if String.trim content="" || not(String.is_valid_utf_8 content) then Error "web_extract_empty"
          else Ok (text "title" item,content)
      | [] -> Error "web_extract_failed")
