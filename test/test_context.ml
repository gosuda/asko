open Asko
open Types
open Lwt.Infix

let check name condition=if not condition then failwith name else Printf.printf "ok: %s\n%!" name
let get=Json_util.required
let at text=match Ptime.of_rfc3339 text with Ok(t,_,_)->Ptime.to_float_s t | _->assert false
let now=at "2026-09-20T00:11:26+09:00"
let message seq created_at text={source="context:1";seq=Int64.of_int seq;native_id=Some(string_of_int seq);
  room_id="room";sender_id="alice";sender_name="앨리스";created_at;text;reply_to=None;
  mentions=[];is_bot=false;deleted=false}
let request prompt={message=message 5000 now prompt;trigger=Mention;prompt}
let range={source="context:1";room_id="room";lower=At_time(now-.604800.);
  retention_start=now-.604800.;through_time=now;before_seq=5000L;note=None}
let old=List.init 300(fun n->message (n+1) (now-.172800.+.float_of_int n) "오래된 포탈 이야기")
let recent=List.init 685(fun n->message (1000+n) (now-.5000.+.float_of_int n) "최신 제육 이야기")
let reference=Some {Store.question=message 4000 (now-.60.) "포탈 요약";body="포탈을 비판했어요";
  evidence=Some(Json_util.to_string (`Assoc ["selected_ids",Llm.strings(List.map(fun (m:message)->Int64.to_string m.seq) old)]))}
let plan={Context_plan.mode=Conversation;start=None;stop=None;speaker_id=None;query=None;followup=false}

let () =
  let initial=Context_window.initial ~bytes:40000 ~recent:(old@recent) ~inherited:old in
  check "old 300-message evidence cannot displace the latest 60"
    (List.for_all(fun (m:message)->List.exists(fun (x:message)->x.seq=m.seq) initial)
       (List.rev recent |> Retrieval.take 60));
  let scoped=Context_plan.enforce_window ~request:(request "최근 90분 대화 요약") ~reference plan in
  let _,messages=Context_plan.select scoped range (old@recent) in
  check "90-minute request crosses KST midnight and selects all 685 originals"
    (scoped.mode=Read_all && scoped.start=Some(now-.5400.) && List.length messages=685);
  let week=Context_plan.enforce_window ~request:(request "이번 한 주 대화 참여자별 요약") ~reference plan in
  check "week means Monday midnight, not a top-k search"
    (week.mode=Read_all && week.start=Some(at "2026-09-14T00:00:00+09:00"));
  let afternoon=Context_plan.enforce_window
    ~request:{(request "오늘 오후 대화 요약") with message=message 5000 (at "2026-09-20T16:00:00+09:00") "오늘 오후 대화 요약"}
    ~reference plan in
  check "an afternoon request does not expand to the entire day"
    (afternoon.start=Some(at "2026-09-20T12:00:00+09:00"));
  check "new creative subject stays independent"
    ((Context_plan.enforce_window ~request:(request "제육 비판") ~reference plan).mode=Conversation);
  let long=String.concat "" (List.init 1200(fun _->"긴한글🦊")) in
  let split=Context_window.batches ~bytes:4000 [message 1 now long] |> Result.get_ok in
  check "bounded context batches preserve every byte of a long message"
    (String.concat "" (List.concat_map (List.map(fun (m:message)->m.text)) split)=long);
  let prefix=Retrieval.chunks (List.filter(fun (m:message)->m.seq<128L) old) in
  let extended=Retrieval.chunks old in
  check "new messages do not shift closed embedding windows"
    (List.for_all(fun chunk->List.exists(fun other->Retrieval.cache_key chunk=Retrieval.cache_key other) extended) prefix);
  check "JSON mode tolerates an outer Markdown fence without accepting trailing junk"
    (Json_util.model_json "```json\n{\"answer\":\"ok\"}\n```"=`Assoc ["answer",`String "ok"]
     && Result.is_error(Json_util.protect(fun ()->Json_util.model_json "{\"answer\":\"ok\"} garbage")));
  let refs=Store.open_ ":memory:" in
  Fun.protect ~finally:(fun ()->Store.close refs) (fun ()->
    let config={Config.default with rooms=["room"]} in
    let question=message 100 (now-.60.) "이전 질문의 실제 주제" in
    ignore(Store.put_message refs ~is_command:true question);
    ignore(Store.enqueue refs ~now:(now-.60.) ~config {message=question;trigger=Mention;prompt=question.text});
    let job=Store.claim_job refs ~now:(now-.60.) |> Option.get in
    Store.finish_job refs job ~body:"이전 답변" ~dry_run:false ~snapshot_version:None ~evidence:None;
    Store.run refs "UPDATE outbox SET state='sent',floor_seq=100,attempted_at=?" [Store.real(now-.50.)];
    let current=message 200 now "더 자세하게" in
    let ref_=Store.answer_reference refs current None |> Option.get in
    check "follow-up includes the earlier question and answer as a pair"
      (ref_.question.text=question.text && ref_.body="이전 답변");
    check "old unrelated same-user answer is not implicitly restored"
      (Store.answer_reference refs {current with created_at=now+.1800.} None=None);
    check "same nickname does not restore another participant's answer"
      (Store.answer_reference refs {current with sender_id="bob"} None=None);
    Store.run refs "UPDATE outbox SET attempted_at=?" [Store.real(now+.1.)];
    check "answer delivered after the question is not inherited"
      (Store.answer_reference refs current None=None));
  let store=Store.open_ ":memory:" in
  Fun.protect ~finally:(fun ()->Store.close store) (fun () -> Lwt_main.run (
    let socket=Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Lwt_unix.bind socket (Unix.ADDR_INET(Unix.inet_addr_loopback,0)) >>= fun () ->
    Lwt_unix.listen socket 8;
    let port=match Lwt_unix.getsockname socket with Unix.ADDR_INET(_,port)->port | _->assert false in
    let stop,wake=Lwt.wait () in
    let audit_calls=ref 0 and answer_calls=ref 0 and collected=ref [] and do_digest=ref false in
    let testing_anchor=ref false and testing_gap=ref false and notes_attempts=ref 0 in
    let callback _ _ body = Cohttp_lwt.Body.to_string body >>= fun body ->
      let json=Yojson.Safe.from_string body in
      let turns=get "messages" json |> Json_util.list Fun.id in
      let system=get "content" (List.hd turns) |> Json_util.string in
      let stage=match Json_util.protect(fun ()->get "response_format" json |> get "json_schema"
        |> get "name" |> Json_util.string) with Ok name->name | Error _->"" in
      let payload=get "content" (List.nth turns 1) |> Json_util.string |> Yojson.Safe.from_string in
      let structured answer=`Assoc ["choices",`List [`Assoc ["finish_reason",`String "stop";
        "message",`Assoc ["role",`String "assistant";"content",`String(Json_util.to_string answer)]]]] in
      let response =
        if (stage="asko_context_plan" || Retrieval.contains system "(asko_context_plan)") then structured (`Assoc [
          "mode",`String(if !do_digest then "read_all" else "conversation");
          "start",`Null;"end",`Null;"speaker_id",`Null;"query",`Null;"followup",`Bool false])
        else if (stage="asko_context_notes" || Retrieval.contains system "(asko_context_notes)") then begin
          incr notes_attempts;
          if !notes_attempts=2 then
            `Assoc ["choices",`List [`Assoc ["finish_reason",`String "stop";
              "message",`Assoc ["role",`String "assistant";"content",`String "invalid JSON"]]]]
          else begin
          let messages=get "messages" payload |> Json_util.list Fun.id in
          let ids=List.map(fun m->get "id" m |> Json_util.string) messages in
          collected:=ids@ !collected;
          structured (`Assoc ["facts",`List [`Assoc ["text",`String "이 구간에는 개발 대화가 있었습니다.";
            "sources",`List [`Int 0;`Int(List.length ids-1)]]]])
          end
        end else if (stage="asko_answer_audit" || Retrieval.contains system "(asko_answer_audit)") then begin
          incr audit_calls;
          let answer=get "answer" payload |> Json_util.string in
          let ok=answer<>"대화 내용이 없습니다" in
          structured (`Assoc ["supported",`Bool ok;"issues",`String(if ok then "" else "685 messages exist. Read their actual contents and correct the false absence claim.")])
        end else begin
          incr answer_calls;
          check "new request cannot inherit the unrelated prior answer" (get "previous_exchange" payload=`Null);
          if not !testing_anchor && not !testing_gap then check "complete coverage is established before the first answer"
            (get "complete" (get "coverage" payload)=`Bool true);
          if !testing_gap then check "incomplete synchronization cannot be labelled complete"
            (get "complete" (get "coverage" payload)=`Bool false && get "source_complete" (get "coverage" payload)=`Bool false);
          if !testing_anchor then
            check "an older explicit reply anchor reaches generation and grounding"
              (List.exists (fun m->get "id" m=`String "1") (get "messages" payload |> Json_util.list Fun.id));
          if not !do_digest && not !testing_anchor then begin
            let supplied=get "messages" payload |> Json_util.list Fun.id in
            check "all requested 685 messages are supplied, not the oldest 100"
              (List.length supplied=685 && List.for_all(fun m->int_of_string(Json_util.string(get "id" m))>=1000) supplied)
          end;
          (* Exercise both the free-text bypass and a correction through respond. *)
          if !answer_calls=1 && not !do_digest && not !testing_anchor then
            `Assoc ["choices",`List [`Assoc ["finish_reason",`String "stop";
              "message",`Assoc ["role",`String "assistant";"content",`String "대화 내용이 없습니다"]]]]
          else
            `Assoc ["choices",`List [`Assoc ["finish_reason",`String "tool_calls";
              "message",`Assoc ["role",`String "assistant";"content",`Null;"tool_calls",`List [
                `Assoc ["id",`String "answer";"type",`String "function";"function",`Assoc [
                  "name",`String "respond";"arguments",`String(Json_util.to_string (`Assoc [
                    "answer",`String(if !testing_anchor then "이 메시지는 포탈 이야기입니다." else "요청한 구간의 개발 대화를 모두 확인했어요.");
                    "sources",(if !testing_anchor then Llm.strings ["1"] else `List [])]))]]]]]]]
        end in
      Cohttp_lwt_unix.Server.respond_string ~status:`OK ~body:(Json_util.to_string response) () in
    let server=Cohttp_lwt_unix.Server.create ~stop ~mode:(`TCP(`Socket socket))
      (Cohttp_lwt_unix.Server.make ~callback ()) in
    let config={Config.default with openrouter_url=Printf.sprintf "http://127.0.0.1:%d" port;
      api_key="test";api_key_env="ASKO_CONTEXT_TEST_KEY";reasoning_enabled=false;max_tool_rounds=32} in
    Unix.putenv config.api_key_env "";
    let run ?(anchor=None) config request history=
      List.iter(fun m->ignore(Store.put_message store ~is_command:false m)) history;
      Conversation.run ~config ~store ~llm:(Llm.create config store) ~name_messages:Lwt.return
        ~request ~anchor ~reference ~history ~range:(if !testing_gap then {range with note=Some "timeout"} else range) ~version:0 in
    Lwt.finalize (fun () ->
      run config (request "최근 90분 대화 요약") (old@recent) >>= fun result ->
      let result=Result.get_ok result in
      check "uncited free text is still audited and corrected"
        (!audit_calls=2 && result.answer.answer_text<>"대화 내용이 없습니다");
      check "the reply has no evidence timestamp footer"
        (Summary.render_answer ~max_bytes:12000 ~messages:result.evidence_messages result.answer=result.answer.answer_text);
      testing_gap:=true;
      run config (request "최근 90분 대화 요약") (old@recent) >>= fun partial ->
      check "source gap remains visible after reading all stored originals"
        (get "complete" (Result.get_ok partial).coverage=`Bool false);
      testing_gap:=false; testing_anchor:=true;
      run ~anchor:(Some(List.hd old)) config (request "이 메시지 설명해줘") (old@recent) >>= fun anchored ->
      check "reply to an old original can use that original as evidence"
        (List.mem 1L (Result.get_ok anchored).answer.answer_sources);
      testing_anchor:=false; do_digest:=true; collected:=[];
      let many=List.init 240(fun n->message (2000+n) (now-.500.+.float_of_int n) (String.make 240 'x')) in
      run {config with max_input_bytes=22000} (request "전체 대화 요약") many >>= fun digested ->
      let result=Result.get_ok digested in
      check "multi-batch summary reads every original including the final page"
        (List.length result.evidence_messages=240 && List.length !collected=240 && List.for_all(fun (m:message)->List.mem(Int64.to_string m.seq) !collected) many);
      Lwt.return_unit)
      (fun ()->Lwt.wakeup_later wake ();server)))
