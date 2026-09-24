open Asko
open Lwt.Infix
let check name value = if not value then failwith name
let () =
  check "remote plaintext embeddings rejected"
    (Result.is_error (Config.of_json (`Assoc ["embedding_url",`String "http://example.org/v1";"api_key_embed",`String "key"])));
  check "separate remote endpoint requires key"
    (Result.is_error (Config.of_json (`Assoc ["embedding_url",`String "https://example.org/v1"])));
  check "separate remote endpoint accepts own key"
    (Result.is_ok (Config.of_json (`Assoc ["embedding_url",`String "https://example.org/v1";"api_key_embed",`String "key"])));
  check "invalid backend rejected"
    (Result.is_error (Config.of_json (`Assoc ["chat_backend",`String "typo"])));
  let store=Store.open_ ":memory:" in
  Fun.protect ~finally:(fun ()->Store.close store) (fun ()->Lwt_main.run (
    let socket=Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Lwt_unix.bind socket (Unix.ADDR_INET(Unix.inet_addr_loopback,0)) >>= fun ()->
    Lwt_unix.listen socket 8;
    let port=match Lwt_unix.getsockname socket with Unix.ADDR_INET(_,p)->p | _->assert false in
    let base=Printf.sprintf "http://127.0.0.1:%d" port in
    let config={Config.default with chat_backend="opencode_go";openrouter_url=base^"/go";
      embedding_url=base^"/embed";api_key="go-key";api_key_embed="embed-key";
      api_key_env="ASKO_GO_TEST_KEY";reasoning_enabled=false;response_format="json_object"} in
    Unix.putenv config.api_key_env "";
    let llm=Llm.for_conversation (Llm.create config store) "room-1" in
    check "separate rooms use separate sessions"
      (llm.session<>(Llm.for_conversation llm "room-2").session);
    check "session stable" (llm.session=(Llm.for_conversation llm "room-1").session);
    check "never leak Go key to separate embedding endpoint"
      (Config.api_key_embed {config with api_key_embed=""}=None);
    let seen=ref [] in
    let callback _ request body =
      Cohttp_lwt.Body.to_string body >>= fun body->
      let json=Yojson.Safe.from_string body in
      let headers=Cohttp.Request.headers request in
      let path=Uri.path (Cohttp.Request.uri request) in
      seen:=path::!seen;
      if path="/go/chat/completions" then begin
        check "chat key" (Cohttp.Header.get headers "authorization"=Some "Bearer go-key");
        check "session header" (Cohttp.Header.get headers "x-opencode-session"=Some llm.session);
        check "Go excludes router fields" (Json_util.field "provider" json=None && Json_util.field "reasoning" json=None);
        check "MiMo thinking flag" (Json_util.field "thinking" json=Some (`Assoc ["type",`String "disabled"]))
      end else begin
        check "embedding endpoint" (path="/embed/embeddings");
        check "embedding key" (Cohttp.Header.get headers "authorization"=Some "Bearer embed-key");
        check "no chat session on embeddings" (Cohttp.Header.get headers "x-opencode-session"=None)
      end;
      Cohttp_lwt_unix.Server.respond_string ~status:`OK
        ~body:{|{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"{\"ok\":true}"}}]}|} () in
    let stop,wake=Lwt.wait () in
    let server=Cohttp_lwt_unix.Server.create ~stop ~mode:(`TCP (`Socket socket))
      (Cohttp_lwt_unix.Server.make ~callback ()) in
    Lwt.finalize (fun ()->
      Llm.turn llm ~messages:[] ~tools:[] >>= fun turn->
      check "tool turn works" (Result.is_ok turn);
      Llm.chat llm ~name:"probe" ~schema:(`Assoc []) ~system:"Return JSON" ~user:(`Assoc []) ~max_tokens:64 >>= fun chat->
      check "structured reply works" (chat=Ok (`Assoc ["ok",`Bool true]));
      Llm.call llm ~output_tokens:0 ~path:"/embeddings" (`Assoc ["model",`String "embed"]) >>= fun embed->
      check "embedding route works" (Result.is_ok embed);
      check "all paths tested" (List.length !seen=3);
      Lwt.return_unit)
      (fun ()->Lwt.wakeup_later wake ();server)))
