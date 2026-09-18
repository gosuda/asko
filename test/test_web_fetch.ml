open Asko
open Lwt.Infix
let check name value = if not value then failwith name else Printf.printf "ok: %s\n%!" name
let ip = Ipaddr.of_string_exn
let error name json = Json_util.field "error" json=Some (`String name)
let headers mime = Cohttp.Header.of_list ["content-type",mime]

let () =
  List.iter (fun address -> check ("blocked " ^ address) (not(Web_fetch.public_ip (ip address))))
    ["127.0.0.1";"10.0.0.1";"172.16.0.1";"192.168.1.1";"100.107.148.12";
     "169.254.169.254";"0.0.0.0";"224.0.0.1";"::";"::1";"fe80::1";"fd7a:115c:a1e0::1";
     "::ffff:127.0.0.1";"::ffff:100.64.0.1";"64:ff9b::7f00:1";"2002:7f00:1::";"ff0e::1"];
  List.iter (fun address -> check ("allowed " ^ address) (Web_fetch.public_ip (ip address)))
    ["8.8.8.8";"1.1.1.1";"2606:4700:4700::1111"];
  let title,text=Web_fetch.html_text {|<head><title>문서 &amp; 제목</title><script>if (x < 1) x="secret";</script></head><nav>menu</nav><main><h1>Hello</h1><p title="a > b">한국어 &#x1F600; &lt;3</p><!-- hidden --></main>|} in
  check "HTML extracts title and readable text" (title="문서 & 제목" && text="Hello\n한국어 😀 <3");
  let text,truncated=Web_fetch.take_chars 2 "한국어" in
  check "truncation preserves Korean characters" (text="한국" && truncated);
  Lwt_main.run (
    let calls=ref 0 and resolutions=ref 0 in
    let resolve _ _ = incr resolutions; Lwt.return [ip "8.8.8.8"] in
    let request uri endpoint =
      incr calls;
      check "checked IP pinned and TLS hostname retained"
        (endpoint=`TLS ("public.example",`TCP (ip "8.8.8.8",443)));
      if Uri.path uri="/redirect" then
        Lwt.return (302,Cohttp.Header.of_list ["location","http://internal.example/"],"")
      else Lwt.return (200,headers "text/html; charset=utf-8","<title>T</title><p>본문</p>") in
    Web_fetch.fetch_with ~resolve ~request "https://public.example/article" >>= fun result ->
    check "public fetch returns page" (Json_util.field "text" result=Some (`String "본문") && !resolutions=1);
    let resolve host port = if host="internal.example" then Lwt.return [ip "127.0.0.1"] else resolve host port in
    Web_fetch.fetch_with ~resolve ~request "https://public.example/redirect" >>= fun result ->
    check "redirect into private network blocked before connection" (error "internal_address_blocked" result && !calls=2);
    let mixed _ _ = Lwt.return [ip "8.8.8.8";ip "::1"] in
    Web_fetch.fetch_with ~resolve:mixed ~request "https://public.example/" >>= fun result ->
    check "mixed public and private DNS answers blocked" (error "internal_address_blocked" result && !calls=2);
    Web_fetch.fetch_with ~resolve ~request "file:///etc/passwd" >>= fun result ->
    check "non-web schemes rejected" (error "only_http_and_https_supported" result && !calls=2);
    let redirects=ref 0 in
    let redirect _ _ = incr redirects; Lwt.return (302,Cohttp.Header.of_list ["location","/loop"],"") in
    Web_fetch.fetch_with ~resolve ~request:redirect "https://public.example/" >>= fun result ->
    check "redirect loop bounded" (error "too_many_redirects" result && !redirects=6);
    let binary _ _ = Lwt.return (200,headers "application/pdf","binary") in
    Web_fetch.fetch_with ~resolve ~request:binary "https://public.example/" >>= fun result ->
    check "unsupported content returns tool error" (error "unsupported_content_type" result);
    Web_fetch.fetch "http://127.0.0.1:3000/" >>= fun result ->
    check "real resolver blocks loopback without connecting" (error "internal_address_blocked" result);
    Web_fetch.fetch "http://[::1]:3000/" >>= fun result ->
    check "real resolver blocks IPv6 loopback" (error "internal_address_blocked" result);
    Lwt.return_unit);
  match Sys.getenv_opt "ASKO_WEB_FETCH_SMOKE_URL" with
  | None -> ()
  | Some url ->
      let result=Lwt_main.run (Web_fetch.fetch url) in
      (match Json_util.field "error" result with Some error -> print_endline (Json_util.to_string error) | None -> ());
      let text=Json_util.optional Json_util.string (Json_util.field "text" result) |> Option.value ~default:"" in
      check "live public page fetched through pinned connection" (String.length text>0)
