open Lwt.Infix

type error = Timeout | Transport | Http_status of int | Invalid_json | Body_too_large | Source_changed
exception Limit_exceeded
let error_name = function
  | Timeout -> "timeout" | Transport -> "transport_error" | Http_status code -> "http_" ^ string_of_int code
  | Invalid_json -> "invalid_json" | Body_too_large -> "body_too_large"
  | Source_changed -> "source_watermark_regressed"
let retryable = function Timeout | Transport | Http_status 429 -> true
  | Http_status code when code >= 500 -> true | _ -> false

let read_body ~limit body =
  let buffer = Buffer.create 4096 in
  Cohttp_lwt.Body.to_stream body
  |> Lwt_stream.iter_s (fun chunk ->
       if String.length chunk > limit - Buffer.length buffer then Lwt.fail Limit_exceeded
       else (Buffer.add_string buffer chunk; Lwt.return_unit))
  >|= fun () -> Buffer.contents buffer

let endpoint base path =
  let uri = Uri.of_string base in
  let base_path = Uri.path uri in
  let base_path = if String.ends_with ~suffix:"/" base_path then String.sub base_path 0 (String.length base_path - 1) else base_path in
  Uri.with_path uri (base_path ^ path)

let request ?(headers=[]) ?body ?(limit=2097152) ~timeout meth uri =
  let headers = Cohttp.Header.of_list (("user-agent","asko/0.1") :: headers) in
  let body = Option.map Cohttp_lwt.Body.of_string body in
  Lwt.catch
    (fun () -> Lwt_unix.with_timeout timeout (fun () ->
       Cohttp_lwt_unix.Client.call ~headers ?body meth uri >>= fun (response, body) ->
       read_body ~limit body >|= fun text ->
       let status = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
       Ok (status, text)))
    (function
      | Lwt.Canceled -> Lwt.fail Lwt.Canceled
      | Lwt_unix.Timeout -> Lwt.return (Error Timeout)
      | Limit_exceeded -> Lwt.return (Error Body_too_large)
      | _ -> Lwt.return (Error Transport))

let json ?headers ?body ?limit ~timeout meth uri =
  let body = Option.map Json_util.to_string body in
  let headers = ("content-type","application/json") :: Option.value ~default:[] headers in
  request ~headers ?body ?limit ~timeout meth uri >|= function
  | Error error -> Error error
  | Ok (status, _) when status < 200 || status >= 300 -> Error (Http_status status)
  | Ok (_, body) -> (try Ok (Yojson.Safe.from_string body) with Yojson.Json_error _ -> Error Invalid_json)
