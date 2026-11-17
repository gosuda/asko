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

let tool_call name args = `Assoc ["choices",`List [`Assoc ["finish_reason",`String "tool_calls";
  "message",`Assoc ["role",`String "assistant";"content",`Null;"tool_calls",`List [
    `Assoc ["id",`String "call";"type",`String "function";"function",`Assoc [
      "name",`String name;"arguments",`String(Json_util.to_string args)]]]]]]]
let say ?(finish="stop") text = `Assoc ["choices",`List [`Assoc ["finish_reason",`String finish;
  "message",`Assoc ["role",`String "assistant";"content",`String text]]]]
let respond ?(sources=[]) answer =
  tool_call "respond" (`Assoc ["answer",`String answer;"sources",Llm.strings sources])
let content turn=get "content" turn |> Json_util.string |> Yojson.Safe.from_string
let initial turns=content (List.nth turns 1)
let last turns=content (List.hd(List.rev turns))
let tool_names json=get "tools" json |> Json_util.list (fun t->get "function" t |> get "name" |> Json_util.string)
let ids json=get "messages" json |> Json_util.list (fun m->get "id" m |> Json_util.string)
let all_null=`Assoc ["start",`Null;"end",`Null;"speaker_id",`Null]

let () =
  let initial_context=Context_window.initial ~bytes:40000 ~recent:(old@recent) ~inherited:old in
  check "old 300-message evidence cannot displace the latest 60"
    (List.for_all(fun (m:message)->List.exists(fun (x:message)->x.seq=m.seq) initial_context)
       (List.rev recent |> Retrieval.take 60));
  let tool n=`Assoc ["role",`String "tool";"tool_call_id",`String(string_of_int n);
    "content",`String(Json_util.to_string (`Assoc ["text",`String(String.make 4000 (Char.chr(48+n)))]))] in
  let long_turns=[`Assoc ["role",`String "system";"content",`String "s"];
    `Assoc ["role",`String "user";"content",`String(String.make 3000 'u')];tool 1;tool 2;tool 3;tool 4] in
  let compacted=Conversation.compact ~budget:14000 long_turns in
  let text n=get "content" (List.nth compacted n) |> Json_util.string in
  check "a long loop drops the oldest tool results first and keeps the request and the newest two"
    (Retrieval.contains (text 2) "elided" && Retrieval.contains (text 3) "elided"
     && get "content" (List.nth compacted 4)=get "content" (tool 3) && List.nth compacted 1=List.nth long_turns 1
     && String.length(Json_util.to_string (`List compacted))<=14000);
  check "a short loop is left untouched" (Conversation.compact ~budget:100000 long_turns=long_turns);
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
    let audit_calls=ref 0 and answer_calls=ref 0 and collected=ref [] and notes_attempts=ref 0 in
    let search_requests=ref [] and extract_requests=ref [] and audited_web=ref [] in
    let script=ref (fun (_:int) (_:Yojson.Safe.t) (_:Yojson.Safe.t list)->say "unset") and step=ref 0 in
    let play f=step:=0;script:=f in
    let callback _ request body = Cohttp_lwt.Body.to_string body >>= fun body ->
      let json=Yojson.Safe.from_string body in
      let structured answer=say (Json_util.to_string answer) in
      let response = match Uri.path (Cohttp.Request.uri request) with
        | "/v1/search" ->
            search_requests:=(Cohttp.Header.get (Cohttp.Request.headers request) "x-api-key",json)::!search_requests;
            `Assoc ["search_id",`String "s1";"results",`List [`Assoc ["url",`String "https://ocaml.example/releases";
              "title",`String "OCaml releases";"publish_date",`Null;"excerpts",`List [`String "OCaml 5.5.2 is the latest release."]]]]
        | "/v1/extract" ->
            extract_requests:=json::!extract_requests;
            `Assoc ["extract_id",`String "e1";"results",`List [`Assoc ["url",`String "https://ocaml.example/releases";
              "title",`String "OCaml releases";"excerpts",`List [];"full_content",`String "# Releases\nOCaml 5.5.2 was released."]];
              "errors",`List []]
        | _ ->
          let turns=get "messages" json |> Json_util.list Fun.id in
          let stage=match Json_util.protect(fun ()->get "response_format" json |> get "json_schema"
            |> get "name" |> Json_util.string) with Ok name->name | Error _->"" in
          if stage="asko_context_notes" then begin
            incr notes_attempts;
            if !notes_attempts=2 then say "invalid JSON" else begin
              let batch=ids (content (List.nth turns 1)) in
              collected:=batch@ !collected;
              structured (`Assoc ["facts",`List [`Assoc ["text",`String "이 구간에는 개발 대화가 있었습니다.";
                "sources",`List [`Int 0;`Int(List.length batch-1)]]]])
            end
          end else if stage="asko_answer_audit" then begin
            incr audit_calls;
            let payload=content (List.nth turns 1) in
            audited_web:=get "web_sources" payload |> Json_util.list Json_util.string;
            let ok=get "answer" payload<>`String "대화 내용이 없습니다" in
            structured (`Assoc ["supported",`Bool ok;"issues",`String(if ok then "" else
              "685 messages exist. Read their actual contents and correct the false absence claim.")])
          end else begin
            incr answer_calls;
            let n= !step in incr step; !script n json turns
          end in
      Cohttp_lwt_unix.Server.respond_string ~status:`OK ~body:(Json_util.to_string response) () in
    let server=Cohttp_lwt_unix.Server.create ~stop ~mode:(`TCP(`Socket socket))
      (Cohttp_lwt_unix.Server.make ~callback ()) in
    let base=Printf.sprintf "http://127.0.0.1:%d" port in
    let config={Config.default with openrouter_url=base;search_url=base;
      api_key="test";api_key_env="ASKO_CONTEXT_TEST_KEY";search_api_key_env="ASKO_CONTEXT_SEARCH_KEY";
      reasoning_enabled=false;max_tool_rounds=32} in
    Unix.putenv config.api_key_env "";Unix.putenv config.search_api_key_env "";
    let run ?(anchor=None) ?(job_id=None) ?(reference=None) ?(note=None) ?notify ?rooms ?fetch config request history=
      List.iter(fun m->ignore(Store.put_message store ~is_command:false m)) history;
      Conversation.run ?notify ?rooms ?fetch ~job_id ~config ~store ~llm:(Llm.create config store) ~name_messages:Lwt.return
        ~request ~anchor ~reference ~history ~range:{range with note} ~version:0 () in
    Lwt.finalize (fun () ->
      play (fun _ json turns ->
        let names=tool_names json and supplied=ids (initial turns) in
        check "web search is offered only when a search key is configured"
          (not(List.mem "web_search" names) && List.mem "fetch_url" names && List.mem "read_period" names);
        check "the first model call is the agent turn, with only the newest messages"
          (List.length turns=2 && List.length supplied=60 && List.for_all(fun id->int_of_string id>=1000) supplied
           && get "previous_exchange" (initial turns)=`Null);
        say "프랑스의 수도는 파리예요.");
      run config (request "프랑스 수도 어디야") (old@recent) >>= fun plain ->
      check "a general question needs one model call: no planning, notes or grounding check"
        (Result.is_ok plain && !answer_calls=1 && !audit_calls=0 && !notes_attempts=0);
      play (fun n _ turns -> match n with
        | 0 -> tool_call "read_period" (`Assoc ["start",`String(Context_plan.timestamp (now-.5400.));
            "end",`Null;"speaker_id",`Null])
        | 1 ->
            check "a 90-minute period crossing KST midnight returns all 685 originals"
              (List.length(ids (last turns))=685 && get "exhaustive" (last turns)=`Bool true
               && List.for_all(fun id->int_of_string id>=1000) (ids (last turns)));
            say "대화 내용이 없습니다"
        | _ -> respond "요청한 구간의 개발 대화를 모두 확인했어요.");
      run config (request "최근 90분 대화 요약") (old@recent) >>= fun result ->
      let result=Result.get_ok result in
      check "uncited free text about the room is still audited and corrected"
        (!audit_calls=2 && result.answer.answer_text<>"대화 내용이 없습니다");
      check "coverage records the interval that was read completely"
        (match get "exhaustive_reads" result.coverage with
         | `List [read]->get "message_count" read=`Int 685 | _->false);
      check "the reply has no evidence timestamp footer"
        (Summary.render_answer ~max_bytes:12000 ~messages:result.evidence_messages result.answer=result.answer.answer_text);
      play (fun n _ _ -> if n=0 then tool_call "read_period" all_null else respond "저장된 기록 기준으로 정리했어요.");
      run ~note:(Some "timeout") config (request "최근 90분 대화 요약") (old@recent) >>= fun partial ->
      let coverage=(Result.get_ok partial).coverage in
      check "source gap remains visible after reading all stored originals"
        (get "complete" coverage=`Bool false && get "source_complete" coverage=`Bool false
         && get "read_count" coverage=get "available_count" coverage);
      let audits= !audit_calls in
      play (fun _ _ turns ->
        check "an older explicit reply anchor reaches generation" (List.mem "1" (ids (initial turns)));
        respond ~sources:["1"] "이 메시지는 포탈 이야기입니다.");
      run ~anchor:(Some(List.hd old)) config (request "이 메시지 설명해줘") (old@recent) >>= fun anchored ->
      check "reply to an old original can use that original as audited evidence"
        (List.mem 1L (Result.get_ok anchored).answer.answer_sources && !audit_calls=audits+1);
      let followup=Some {Store.question=message 4000 (now-.60.) "OCaml 최신 버전";body="5.5.2예요";
        evidence=Some(Json_util.to_string (`Assoc ["selected_ids",`List [];
          "web",`List [`Assoc ["url",`String "https://ocaml.example/releases";"title",`String "OCaml releases"]]]))} in
      play (fun _ _ turns ->
        check "a follow-up sees the earlier question, answer and the web pages it used"
          (Retrieval.contains (Json_util.to_string (get "previous_exchange" (initial turns))) "https://ocaml.example/releases"
           && get "previous_answer" (initial turns)=`String "5.5.2예요");
        say "그 페이지 기준으로는 5.5.2가 최신이에요.");
      run ~reference:followup config (request "그 링크 더 자세히") recent >>= fun continued ->
      check "follow-up answered" (Result.is_ok continued);
      (* Web lookups: search, then a page the local fetcher cannot read. *)
      let web_config={config with search_api_key="pkey"} in
      let audits= !audit_calls in
      play (fun n json turns -> match n with
        | 0 ->
            check "web search is offered with a search key" (List.mem "web_search" (tool_names json));
            tool_call "web_search" (`Assoc ["objective",`String "OCaml 최신 버전";"queries",Llm.strings ["OCaml latest release"]])
        | 1 ->
            check "search results reach the agent"
              (Retrieval.contains (Json_util.to_string (last turns)) "https://ocaml.example/releases");
            tool_call "fetch_url" (`Assoc ["url",`String "https://ocaml.example/releases";"offset",`Null])
        | _ ->
            check "a page the local fetcher cannot read falls back to Parallel Extract"
              (get "via" (last turns)=`String "parallel" && Retrieval.contains (Json_util.string(get "text" (last turns))) "5.5.2");
            respond "OCaml 최신 버전은 5.5.2예요.\nhttps://ocaml.example/releases");
      run ~fetch:(fun ?offset:_ _->Lwt.return (`Assoc ["error",`String "http_403"])) web_config
        (request "OCaml 최신 버전 뭐야") recent >>= fun searched ->
      let searched=Result.get_ok searched in
      let key,search_body=List.hd !search_requests in
      check "the Parallel request carries the key, objective and v1 settings"
        (key=Some "pkey" && get "objective" search_body=`String "OCaml 최신 버전"
         && get "search_queries" search_body=Llm.strings ["OCaml latest release"]
         && Json_util.field "max_results" (get "advanced_settings" search_body)<>None
         && Json_util.field "full_content" (get "advanced_settings" (List.hd !extract_requests))<>None);
      check "a web answer skips the room grounding check and records its pages"
        (!audit_calls=audits && List.mem_assoc "https://ocaml.example/releases" searched.web_sources
         && List.length !extract_requests=1);
      play (fun n _ _ -> match n with
        | 0 -> tool_call "fetch_url" (`Assoc ["url",`String "http://192.168.0.1/admin";"offset",`Null])
        | _ -> respond "그 주소는 읽을 수 없어요.");
      run web_config (request "이 주소 읽어줘") recent >>= fun blocked ->
      check "internal addresses are never forwarded to the extract service"
        (Result.is_ok blocked && List.length !extract_requests=1);
      (* Budget, progress and truncation behaviour of the loop. *)
      play (fun _ json turns ->
        if tool_names json=["respond"] then begin
          check "the closing turn explains that the budget is used up"
            (Json_util.field "notice" (last turns)<>None);
          respond "지금까지 확인한 내용만 말씀드려요."
        end else tool_call "find_participants" (`Assoc ["query",`String ""]));
      run {config with max_tool_rounds=4} (request "계속 찾아봐") recent >>= fun closed ->
      check "the last calls are kept for an answer instead of a failure"
        ((Result.get_ok closed).answer.answer_text="지금까지 확인한 내용만 말씀드려요.");
      let lines=ref [] in
      play (fun n _ turns -> match n with
        | 0 -> tool_call "send_progress" (`Assoc ["text",`String "자료 찾아보는 중이에요"])
        | _ -> check "the agent learns whether its progress line was posted" (get "sent" (last turns)=`Bool true);
            say "다 찾았어요.");
      run ~notify:(fun text->lines:=text::!lines;Lwt.return true) config (request "오래 걸리는 조사") recent >>= fun noted ->
      check "a progress line is posted only when the agent asks for one"
        (Result.is_ok noted && !lines=["자료 찾아보는 중이에요"]);
      play (fun n json _ -> match n with
        | 0 -> check "normal output budget" (get "max_tokens" json=`Int 4000);say ~finish:"length" "잘린 답"
        | _ -> check "a truncated turn is retried with more output room" (get "max_tokens" json=`Int 6000);
            say "완성된 답");
      run config (request "긴 답") recent >>= fun retried ->
      check "the retried turn's answer is used" ((Result.get_ok retried).answer.answer_text="완성된 답");
      (* Reading another enabled room. *)
      let elsewhere={(message 4500 (now-.100.) "다른 방 배포 이야기") with room_id="room2"} in
      ignore(Store.put_message store ~is_command:false elsewhere);
      let read room=tool_call "read_messages" (`Assoc ["start",`Null;"end",`Null;"after_id",`Null;
        "speaker_id",`Null;"room_id",`String room]) in
      play (fun n json turns -> match n with
        | 0 ->
            check "other readable rooms are listed for the agent"
              (Retrieval.contains (Json_util.to_string (get "other_rooms" (initial turns))) "room2"
               && Retrieval.contains (Json_util.to_string (get "tools" json)) "room_id");
            read "room2"
        | 1 ->
            check "an enabled room can be read by ID" (get "room_id" (last turns)=`String "room2" && ids (last turns)=["4500"]);
            read "secret"
        | _ ->
            check "a room outside the enabled list is refused" (get "error" (last turns)=`String "Room unavailable");
            respond ~sources:["4500"] "다른 방에서는 배포 이야기를 했어요.");
      run ~rooms:["room2",Some "다른방"] config (request "다른 방에서 무슨 얘기 했어") recent >>= fun crossed ->
      check "evidence from the other room is kept with the answer"
        (List.exists(fun (m:message)->m.seq=4500L && m.room_id="room2") (Result.get_ok crossed).evidence_messages);
      play (fun _ json _ ->
        check "without other rooms the tools take no room_id"
          (not(Retrieval.contains (Json_util.to_string (get "tools" json)) "room_id"));
        say "네");
      run config (request "안녕") recent >>= fun _ ->
      (* A period too large for one request is read in batches of notes. *)
      collected:=[];
      let many=List.init 240(fun n->message (2000+n) (now-.500.+.float_of_int n) (String.make 240 'x')) in
      let digest_request=request "전체 대화 요약" in
      ignore(Store.put_message store ~is_command:true digest_request.message);
      let digest_config={config with rooms=["room"];max_input_bytes=40000} in
      let job_id=match Store.enqueue store ~now ~config:digest_config digest_request with
        | Store.Queued id->id | _->assert false in
      let digest n _ turns = match n with
        | 0 -> tool_call "read_period" all_null
        | _ ->
            check "a large period comes back as notes covering every message"
              (Json_util.field "notes" (last turns)<>None && get "read_count" (last turns)=`Int 240);
            respond "요청한 구간의 개발 대화를 모두 확인했어요." in
      play digest;
      run ~job_id:(Some job_id) digest_config digest_request many >>= fun digested ->
      let result=Result.get_ok digested in
      check "multi-batch summary reads every original including the final page"
        (List.length result.evidence_messages=240 && List.length !collected=240
         && List.for_all(fun (m:message)->List.mem(Int64.to_string m.seq) !collected) many);
      let attempts= !notes_attempts and calls=Store.job_model_calls store job_id in
      play digest;
      run ~job_id:(Some job_id) digest_config digest_request many >>= fun reused->
      check "whole-job retry reuses all successful batches and counts only new calls"
        (Result.is_ok reused && !notes_attempts=attempts && Store.job_model_calls store job_id=calls+3);
      play digest;
      run ~job_id:(Some job_id) {digest_config with max_tool_rounds=calls+3} digest_request many >>= fun capped->
      check "whole-job retry cannot reset the conversation call budget"
        (match capped with Error(Llm.Limit_exceeded {resource="max_tool_rounds";_})->true | _->false);
      Lwt.return_unit)
      (fun ()->Lwt.wakeup_later wake ();server)))
