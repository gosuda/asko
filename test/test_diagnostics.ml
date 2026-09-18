open Asko
open Types
open Lwt.Infix
let check name ok = if not ok then failwith name else Printf.printf "ok: %s\n%!" name
let field = Json_util.required
let () =
  let defaults=Config.of_json (`Assoc []) |> Result.get_ok in
  check "larger defaults" (defaults.max_input_bytes=1000000 && defaults.max_history_bytes=8000000 && defaults.max_tool_rounds=16);
  List.iter (fun n -> check "invalid round cap rejected"
    (Result.is_error (Config.of_json (`Assoc ["max_tool_rounds",`Int n])))) [0;65];
  check "explicit lower limits preserved" (match Config.of_json (`Assoc ["max_input_bytes",`Int 240000;
    "max_history_bytes",`Int 2000000;"max_tool_rounds",`Int 8]) with
    | Ok c->c.max_input_bytes=240000 && c.max_history_bytes=2000000 && c.max_tool_rounds=8 | _->false);
  let store=Store.open_ ":memory:" in
  Fun.protect ~finally:(fun ()->Store.close store) (fun () -> Lwt_main.run (
    let now=Unix.gettimeofday () in
    let config={Config.default with rooms=["room"];bot_id="bot";dry_run=false;
      api_key="SECRET_KEY";api_key_env="ASKO_DIAGNOSTIC_TEST_KEY"} in
    Unix.putenv config.api_key_env "";
    let engine=Engine.create config store in
    Hashtbl.replace engine.name_refresh "room" now;
    let message={source=config.source_id;seq=1L;native_id=Some "1";room_id="room";
      sender_id="alice";sender_name="Alice";created_at=now;text="PRIVATE_CHAT";
      reply_to=None;mentions=["bot"];is_bot=false;deleted=false} in
    ignore(Store.put_message store ~is_command:true message);
    ignore(Store.enqueue store ~now ~config {message;trigger=Mention;prompt=message.text});
    let job=Option.get(Store.claim_job store ~now) in
    let error=Llm.Limit_exceeded {resource="max_input_bytes";actual=Some 1000001;limit=1000000} in
    let details=Engine.diagnostic engine job error in
    check "diagnostic preserves measurements" (field "actual" details=`Int 1000001 && field "limit" details=`Int 1000000);
    let text=Json_util.to_string details in
    check "diagnostic excludes credentials and chat" (not (Retrieval.contains text "SECRET_KEY") && not (Retrieval.contains text "PRIVATE_CHAT"));
    check "HTTP status exposed" (field "http_status" (Llm.error_details (Llm.Network (Net.Http_status 429)))=`Int 429);
    check "retry classification preserved" (Llm.retryable (Llm.Network (Net.Http_status 429)) &&
      Llm.retryable (Llm.Network (Net.Http_status 503)) && not (Llm.retryable error));
    check "deadline differs from HTTP timeout" (Llm.error_name Llm.Request_timeout <> Llm.error_name (Llm.Network Net.Timeout));
    check "history and round caps are distinct" (Llm.error_name (Llm.Limit_exceeded {resource="max_history_bytes";actual=None;limit=8000000}) <>
      Llm.error_name (Llm.Limit_exceeded {resource="max_tool_rounds";actual=Some 16;limit=16}));
    Llm.turn (Llm.create {config with max_input_bytes=1000} store)
      ~messages:[`Assoc ["role",`String "user";"content",`String (String.make 2000 'x')]] ~tools:[] >>= fun result ->
    check "oversized chat stopped before network" (match result with
      | Error (Llm.Limit_exceeded {resource="max_input_bytes";actual=Some n;limit=1000})->n>2000 | _->false);
    Llm.turn (Llm.create {config with daily_budget_tokens=1} store) ~messages:[] ~tools:[] >>= fun result ->
    check "daily budget includes attempted reservation" (match result with
      | Error (Llm.Limit_exceeded {resource="daily_budget_tokens";actual=Some n;limit=1})->n>1 | _->false);
    check "rejected requests do not reserve usage" (Store.tokens_today store ~at:now=0);
    Engine.failed engine job (Llm.Network Net.Timeout) >>= fun () ->
    check "retryable failures do not send premature notices" (Store.recent_outbox store=[]);
    Store.run store "UPDATE jobs SET expires_at=? WHERE id=?" [Store.real (now-.1.);Store.integer job.id];
    Engine.failed engine {job with expires_at=now-.1.} Llm.Request_timeout >>= fun () ->
    let outgoing=Option.get(Store.next_outgoing store ~now:(Unix.gettimeofday ())) in
    check "deadline diagnostic remains deliverable" (outgoing.state="pending" && Retrieval.contains outgoing.body "request_deadline_exceeded");
    check "user sees correlatable job ID" (Retrieval.contains outgoing.body "job_id");
    Lwt.return_unit))
