open Lwt.Infix

exception Fetch_error of string
let fail reason = raise (Fetch_error reason)

let blocked_v4 = List.map Ipaddr.Prefix.of_string_exn [
  "0.0.0.0/8"; "10.0.0.0/8"; "100.64.0.0/10"; "127.0.0.0/8";
  "169.254.0.0/16"; "172.16.0.0/12"; "192.0.0.0/24"; "192.0.2.0/24";
  "192.168.0.0/16"; "198.18.0.0/15"; "198.51.100.0/24"; "203.0.113.0/24";
  "224.0.0.0/4"; "240.0.0.0/4"]
let global_v6 = Ipaddr.Prefix.of_string_exn "2000::/3"
let blocked_v6 = List.map Ipaddr.Prefix.of_string_exn [
  "2001::/23"; "2001:db8::/32"; "2002::/16"; "3fff::/20"]

let public_ip ip =
  match Ipaddr.to_v4 ip with
  | Some v4 -> not (List.exists (Ipaddr.Prefix.mem (Ipaddr.V4 v4)) blocked_v4)
  | None -> Ipaddr.Prefix.mem ip global_v6 &&
      not (List.exists (Ipaddr.Prefix.mem ip) blocked_v6)

let target url =
  if String.length url > 8192 || String.exists (fun c -> Char.code c <= 32 || c='\\' || Char.code c=127) url
  then fail "invalid_url";
  let uri = Uri.of_string url in
  let scheme = Option.value ~default:"" (Uri.scheme uri) |> String.lowercase_ascii in
  if scheme<>"https" && scheme<>"http" then fail "only_http_and_https_supported";
  if Uri.userinfo uri<>None then fail "url_credentials_not_supported";
  let host = Option.value ~default:"" (Uri.host uri) in
  if host="" || String.contains host '%' then fail "invalid_host";
  let port = Option.value ~default:(if scheme="https" then 443 else 80) (Uri.port uri) in
  if port<1 || port>65535 then fail "invalid_port";
  Uri.with_fragment (Uri.with_scheme uri (Some scheme)) None,host,port

let resolve host port =
  Lwt_unix.getaddrinfo host (string_of_int port) [Unix.AI_SOCKTYPE Unix.SOCK_STREAM]
  >|= List.filter_map (fun info -> match info.Unix.ai_addr with
    | Unix.ADDR_INET (ip,_) -> Some (Ipaddr.of_string_exn (Unix.string_of_inet_addr ip))
    | Unix.ADDR_UNIX _ -> None)

let endpoint uri host port addresses =
  if addresses=[] then fail "dns_lookup_failed";
  if not (List.for_all public_ip addresses) then fail "internal_address_blocked";
  (* Connect to the checked IP directly. Keep the original host for HTTP and TLS;
     never perform a second DNS lookup or use a proxy. *)
  let v4,v6 = List.partition (function Ipaddr.V4 _ -> true | _ -> false) addresses in
  let tcp = `TCP (List.hd (v4 @ v6),port) in
  if Uri.scheme uri=Some "https" then `TLS (host,tcp) else tcp

let request uri endpoint =
  let module Connection = Cohttp_lwt_unix.Connection in
  let connection = Connection.create ~persistent:false endpoint in
  Lwt.finalize (fun () ->
    let headers = Cohttp.Header.of_list ["user-agent","asko/0.1";
      "accept","text/html, text/plain, application/json"; "accept-encoding","identity"] in
    Connection.call connection ~headers `GET uri >>= fun (response,body) ->
    let status = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
    let headers = Cohttp.Response.headers response in
    if status<200 || status>=300 then Lwt.return (status,headers,"") else
    Net.read_body ~limit:2097152 body >|= fun body -> status,headers,body)
    (fun () -> Connection.close connection; Lwt.return_unit)

let entities text =
  let pattern = Str.regexp {|&\(#x[0-9a-fA-F]+\|#[0-9]+\|[a-zA-Z]+\);|} in
  Str.global_substitute pattern (fun input ->
    let original=Str.matched_string input and name=Str.matched_group 1 input in
    match name with
    | "amp" -> "&" | "lt" -> "<" | "gt" -> ">" | "quot" -> "\""
    | "apos" -> "'" | "nbsp" -> " "
    | _ when String.starts_with ~prefix:"#" name ->
        let number = if String.starts_with ~prefix:"#x" name then "0x" ^ String.sub name 2 (String.length name-2)
          else String.sub name 1 (String.length name-1) in
        (match int_of_string_opt number with
         | Some n when Uchar.is_valid n -> let b=Buffer.create 4 in Buffer.add_utf_8_uchar b (Uchar.of_int n); Buffer.contents b
         | _ -> original)
    | _ -> original) text

let clean text =
  text |> entities |> Str.global_replace (Str.regexp "[ \t\r]+") " "
  |> Str.global_replace (Str.regexp " *\n[ \n]*") "\n" |> String.trim

(* A small text extractor: no scripts, subresources, or browser execution. *)
let html_text html =
  let body=Buffer.create 4096 and title=Buffer.create 128 in
  let lower=String.lowercase_ascii html and length=String.length html in
  let hidden=ref [] and in_title=ref false in
  let hidden_tags=["head";"script";"style";"nav";"footer";"noscript";"svg";"template"] in
  let blocks=["p";"div";"br";"li";"tr";"h1";"h2";"h3";"h4";"section";"article"] in
  let rec tag_end i quote =
    if i>=length then length else match quote,html.[i] with
    | None,'>' -> i
    | None,('\''|'"' as c) -> tag_end (i+1) (Some c)
    | Some q,c when q=c -> tag_end (i+1) None
    | _ -> tag_end (i+1) quote in
  let rec scan i =
    if i>=length then () else if html.[i]<>'<' then begin
      if !in_title then Buffer.add_char title html.[i]
      else if !hidden=[] then Buffer.add_char body html.[i];
      scan (i+1)
    end else if i+4<=length && String.sub html i 4="<!--" then
      let next=try Str.search_forward (Str.regexp_string "-->") html (i+4)+3 with Not_found->length in scan next
    else begin
      let stop=tag_end (i+1) None in
      let tag=String.sub lower (i+1) (stop-i-1) |> String.trim in
      let closing=String.starts_with ~prefix:"/" tag in
      let offset=if closing then 1 else 0 in
      let ending=ref offset in
      while !ending<String.length tag && (match tag.[!ending] with 'a'..'z'|'0'..'9'->true|_->false) do incr ending done;
      let name=String.sub tag offset (!ending-offset) in
      if name="title" then in_title:=not closing;
      if List.mem name hidden_tags then begin
        if closing then (match !hidden with h::rest when h=name -> hidden:=rest | _ -> ())
        else if not (String.ends_with ~suffix:"/" tag) then hidden:=name::!hidden
      end;
      if !hidden=[] && List.mem name blocks then Buffer.add_char body '\n';
      let next=min length (stop+1) in
      if not closing && List.mem name ["script";"style"] then
        let next=try Str.search_forward (Str.regexp ("</" ^ name ^ "[ \t\r\n>]") ) lower next with Not_found->length in
        scan next
      else scan next
    end in
  scan 0;
  clean (Buffer.contents title),clean (Buffer.contents body)

let take_chars limit text =
  let rec loop offset count =
    if offset>=String.length text || count=limit then offset else
    loop (offset + Uchar.utf_decode_length (String.get_utf_8_uchar text offset)) (count+1) in
  let stop=loop 0 0 in String.sub text 0 stop,stop<String.length text

let document uri headers body =
  if not (String.is_valid_utf_8 body) then fail "unsupported_text_encoding";
  let encoding=Cohttp.Header.get headers "content-encoding" |> Option.value ~default:"identity" |> String.lowercase_ascii in
  if encoding<>"identity" then fail "unsupported_content_encoding";
  let mime=Cohttp.Header.get headers "content-type" |> Option.value ~default:""
    |> String.split_on_char ';' |> List.hd |> String.trim |> String.lowercase_ascii in
  let title,text=match mime with
    | "text/html" | "application/xhtml+xml" -> html_text body
    | "text/plain" | "application/json" | "text/json" -> "",String.trim body
    | _ -> fail "unsupported_content_type" in
  let text,truncated=take_chars 20000 text in
  `Assoc ["url",`String(Uri.to_string uri);"title",`String(fst(take_chars 300 title));
    "content_type",`String mime;"text",`String text;"truncated",`Bool truncated]

let fetch_with ~resolve ~request url =
  let rec follow left url =
    let uri,host,port=target url in
    resolve host port >>= fun addresses ->
    let endpoint=endpoint uri host port addresses in
    request uri endpoint >>= fun (status,headers,body) ->
    if List.mem status [301;302;303;307;308] then begin
      if left=0 then fail "too_many_redirects";
      let location=match Cohttp.Header.get headers "location" with
        | Some value -> value | None -> fail "redirect_without_location" in
      let next=Uri.resolve "" uri (Uri.of_string location) |> Uri.to_string in
      follow (left-1) next
    end else if status<200 || status>=300 then fail ("http_" ^ string_of_int status)
    else Lwt.return (document uri headers body) in
  Lwt.catch
    (fun () -> Lwt_unix.with_timeout 10. (fun () -> follow 5 url))
    (fun error ->
      match error with Lwt.Canceled -> Lwt.fail Lwt.Canceled | _ ->
      let reason=match error with
        | Fetch_error reason -> reason | Lwt_unix.Timeout -> "timeout"
        | Net.Limit_exceeded -> "body_too_large" | _ -> "fetch_failed" in
      Lwt.return (`Assoc ["error",`String reason]))

let fetch url = fetch_with ~resolve ~request url
