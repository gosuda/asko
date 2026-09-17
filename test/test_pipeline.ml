open Asko
open Lwt.Infix
let check name value = if not value then failwith name else Printf.printf "ok: %s\n%!" name
let field = Json_util.required
let response json = Cohttp_lwt_unix.Server.respond_string
  ~headers:(Cohttp.Header.init_with "content-type" "application/json") ~status:`OK
  ~body:(Json_util.to_string json) ()

let raw_query db sql bindings =
  let stmt=Sqlite3.prepare db sql in
  Fun.protect ~finally:(fun ()->ignore (Sqlite3.finalize stmt)) (fun () ->
    List.iteri (fun index value -> ignore (Sqlite3.bind_text stmt (index+1) (Json_util.id value))) bindings;
    let rec loop acc = match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
          let row=List.init (Sqlite3.column_count stmt) (fun col ->
            Sqlite3.column_name stmt col,
            if Sqlite3.column_is_null stmt col then `Null else `String (Sqlite3.column_text stmt col)) in
          loop (`Assoc row::acc)
      | Sqlite3.Rc.DONE -> List.rev acc
      | code -> failwith (Sqlite3.Rc.to_string code) in loop [])

let native_id seq = Int64.to_string (Int64.add 9007199254740993L (Int64.of_int seq))
let insert db ~seq ~room ~sender ~at ~text ?reply ?(mentions=[]) () =
  let stmt=Sqlite3.prepare db "INSERT INTO chat_logs VALUES(?,?,?,?,?,?,?,?)" in
  Fun.protect ~finally:(fun ()->ignore (Sqlite3.finalize stmt)) (fun () ->
    let attachment=Json_util.to_string (`Assoc ((match reply with None->[] | Some id->["src_logId",`String id]) @ ["mentions",`List (List.map (fun id->`Assoc ["user_id",`String id]) mentions)])) in
    let mine=if sender="9999" then {|{"isMine":true}|} else {|{"isMine":false}|} in
    ignore (Sqlite3.bind_values stmt [Sqlite3.Data.INT (Int64.of_int seq);Sqlite3.Data.TEXT (native_id seq);
      Sqlite3.Data.TEXT room;Sqlite3.Data.TEXT sender;Sqlite3.Data.INT (Int64.of_float at);
      Sqlite3.Data.TEXT text;Sqlite3.Data.TEXT attachment;Sqlite3.Data.TEXT mine]);
    if Sqlite3.step stmt<>Sqlite3.Rc.DONE then failwith "fixture insert")

let event db seq =
  let row=List.hd (raw_query db "SELECT * FROM chat_logs WHERE _id=?" [`String (string_of_int seq)]) in
  `Assoc ["json",row;"msg",field "message" row;"sender",`String "앨리스"]

let () =
  let path=Filename.temp_file "asko-pipeline" ".sqlite" in
  let store=Store.open_ path in
  let fixture=Sqlite3.db_open ":memory:" in
  ignore (Sqlite3.exec fixture {|CREATE TABLE chat_logs(_id INTEGER PRIMARY KEY,id TEXT,chat_id TEXT,
    user_id TEXT,created_at INTEGER,message TEXT,attachment TEXT,v TEXT)|});
  let now=floor (Unix.gettimeofday ()) in
  for seq=1 to 205 do
    let text=if seq=1 then "MVCC를 지원하는 관계형 데이터베이스를 검토하자"
      else if seq=10 then "/요약 오늘"
      else if seq=200 then "최종 합의: 이번에는 SQLite로 시작하자"
      else "점심 메뉴와 일상 이야기" in
    insert fixture ~seq ~room:"1001" ~sender:"2001" ~at:(now-.600.+.float_of_int seq)
      ~text ?reply:(if seq=200 then Some (native_id 1) else None) ()
  done;
  insert fixture ~seq:206 ~room:"1001" ~sender:"2001" ~at:(now-.30.) ~text:"/요약" ();
  insert fixture ~seq:207 ~room:"1002" ~sender:"2002" ~at:(now-.10.) ~text:"PRIVATE_ROOM_SHOULD_NEVER_LEAK" ();
  let chats=ref 0 and embeddings=ref 0 and deliveries=ref [] and contexts=ref [] in
  let bad_citation=ref false and backend_port=ref None in
  let fail_second_page=ref false in
  let stop,wake_stop=Lwt.wait () and mock_stop,wake_mock=Lwt.wait () in
  let cleanup () =
    Store.close store; ignore (Sqlite3.db_close fixture);
    List.iter (fun p->try Sys.remove p with Sys_error _->()) [path;path^"-wal";path^"-shm"] in
  Fun.protect ~finally:cleanup (fun () -> Lwt_main.run (
    let socket=Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Lwt_unix.bind socket (Unix.ADDR_INET(Unix.inet_addr_loopback,0)) >>= fun () ->
    Lwt_unix.listen socket 16;
    let port=match Lwt_unix.getsockname socket with Unix.ADDR_INET(_,port)->port | _->assert false in
    let base=Printf.sprintf "http://127.0.0.1:%d" port in
    let config={Config.default with source_id="pipeline:1"; port=0; db_path=path;
      iris_url=base;openrouter_url=base^"/api/v1";embedding_url=base^"/api/v1";reasoning_enabled=false;bot_id="9999";rooms=["1001"];
      cooldown=0.;dry_run=false;recovery_interval=1.;send_interval=0.2;confirm_timeout=2.;
      api_key="not-a-real-key";api_key_env="ASKO_PIPELINE_KEY";ingest_token_env="ASKO_PIPELINE_TOKEN";allow_insecure_loopback=true} in
    Unix.putenv config.api_key_env ""; Unix.putenv config.ingest_token_env "test-ingress";
    let callback _ request body =
      Net.read_body ~limit:1048576 body >>= fun raw ->
      let json=if raw="" then `Null else Yojson.Safe.from_string raw in
      match Uri.path (Cohttp.Request.uri request) with
      | "/config" -> response (`Assoc ["bot_id",`String "9999";"message_send_rate",`Int 200])
      | "/query" ->
          let sql=field "query" json |> Json_util.string in
          let bindings=field "bind" json |> Json_util.list Fun.id in
          if !fail_second_page && List.length bindings=5 && List.nth bindings 1=`String "200" then
            Cohttp_lwt_unix.Server.respond_string ~status:`Service_unavailable ~body:"{}" ()
          else response (`Assoc ["data",`List (raw_query fixture sql bindings)])
      | "/reply" ->
          let room=field "room" json |> Json_util.string and text=field "data" json |> Json_util.string in
          check "delivery stays in allowed room" (room="1001");
          deliveries:=text::!deliveries;
          let last=List.hd (raw_query fixture "SELECT MAX(_id) AS id FROM chat_logs" []) |> field "id" |> Json_util.string |> int_of_string in
          insert fixture ~seq:(last+1) ~room ~sender:"9999" ~at:now ~text ();
          let uri=Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/events/iris" (Option.get !backend_port)) in
          (* The bot echo reaches ingestion before /reply returns: exercise the acknowledgement race. *)
          Net.json ~headers:["x-asko-token","test-ingress"] ~body:(event fixture (last+1)) ~timeout:3. `POST uri
          >>= fun echoed -> check "echo callback accepted" (Result.is_ok echoed);
          response (`Assoc ["success",`Bool true])
      | "/api/v1/embeddings" ->
          incr embeddings;
          check "local embeddings never receive the OpenRouter key"
            (Cohttp.Header.get (Cohttp.Request.headers request) "authorization"=None);
          let inputs=field "input" json |> Json_util.list Json_util.string in
          let data=List.mapi (fun index input ->
            let related=Retrieval.contains (String.lowercase_ascii input) "postgres" || Retrieval.contains input "MVCC" in
            `Assoc ["index",`Int index;"embedding",`List (if related then [`Float 1.;`Float 0.] else [`Float 0.;`Float 1.])]) inputs in
          response (`Assoc ["data",`List (List.rev data);"usage",`Assoc ["total_tokens",`Int 10]])
      | "/api/v1/chat/completions" ->
          incr chats;
          check "chat authentication uses configured key"
            (Cohttp.Header.get (Cohttp.Request.headers request) "authorization"=Some "Bearer not-a-real-key");
          check "configured model selected" (field "model" json=`String config.model);
          check "reasoning explicitly disabled in chat requests"
            (field "reasoning" json=`Assoc ["enabled",`Bool false]);
          let payload=field "messages" json |> Json_util.list Fun.id |> List.rev |> List.hd
            |> field "content" |> Json_util.string |> Yojson.Safe.from_string in
          let format=field "response_format" json in
          let name=match field "type" format with
            | `String "json_object" ->
                check "JSON mode does not send unsupported schema parameters" (format=`Assoc ["type",`String "json_object"]);
                let system=field "messages" json |> Json_util.list Fun.id |> List.hd |> field "content" |> Json_util.string in
                check "JSON mode includes the output contract in system instructions"
                  (Retrieval.contains system "\"additionalProperties\":false" && Retrieval.contains system "\"required\"");
                if Json_util.field "request" payload<>None then "asko_intent" else "asko_summary"
            | `String "json_schema" -> field "json_schema" format |> field "name" |> Json_util.string
            | _ -> failwith "unsupported response format" in
          check "other-room contents never reach model" (not (Retrieval.contains (Json_util.to_string payload) "PRIVATE_ROOM_SHOULD_NEVER_LEAK"));
          let answer=if name="asko_intent" then
              if field "has_reply_anchor" payload=`Bool true then begin
                check "reply text reaches the classifier" (field "reply_context" payload<>`Null);
                Yojson.Safe.from_string {|{"action":"summarize","scope":"from_reply","minutes":null,"topic":null,"focus":"overview","question":null}|}
              end else if Retrieval.contains (field "request" payload |> Json_util.string) "2시간" then
                Yojson.Safe.from_string {|{"action":"summarize","scope":"last_minutes","minutes":120,"topic":null,"focus":"overview","question":null}|}
              else Yojson.Safe.from_string
                {|{"action":"summarize","scope":"recent","minutes":null,"topic":"postgres","focus":"conclusions","question":null}|}
            else
              let messages=field "messages" payload |> Json_util.list Fun.id in
              let ids=List.map (fun m->field "id" m |> Json_util.string) messages in
              contexts:=ids::!contexts;
              let cited=if !bad_citation then "999999" else if List.mem "200" ids then "200" else List.hd ids in
              `Assoc ["bullets",`List [`Assoc ["text",`String "이번에는 SQLite로 시작하기로 했어요.";"sources",`List [`String cited]]];
                "conclusion",`String (if field "focus" payload=`String "conclusions" then "agreed" else "not_requested")] in
          response (`Assoc ["choices",`List [`Assoc ["finish_reason",`String "stop";
            "message",`Assoc ["content",`String (Json_util.to_string answer)]]];"usage",`Assoc ["total_tokens",`Int 20]])
      | _ -> Cohttp_lwt_unix.Server.respond_string ~status:`Not_found ~body:"{}" () in
    let mock=Cohttp_lwt_unix.Server.create ~stop:mock_stop ~mode:(`TCP (`Socket socket))
        (Cohttp_lwt_unix.Server.make ~callback ()) in
    let ready, wake_ready=Lwt.wait () in
    let running=ref Lwt.return_unit in
    Lwt.finalize (fun () ->
      let llm=Llm.create config store in
      Llm.embed llm ["postgres";"banana"] >>= fun vectors ->
      check "embedding response indices reordered correctly" (vectors=Ok [[|1.;0.|];[|0.;1.|]]);
      let absent=Llm.create {config with api_key="";api_key_env="ASKO_ABSENT_KEY"} store in
      Unix.putenv "ASKO_ABSENT_KEY" "";
      Llm.embed absent ["x"] >>= fun absent_result ->
      check "local embeddings need no API key" (Result.is_ok absent_result);
      let before= !chats + !embeddings in
      Llm.embed (Llm.create {config with max_input_bytes=1000} store) [String.make 2000 'x'] >>= fun budget ->
      check "budget stops request before network" (budget=Error Llm.Input_too_large && before= !chats + !embeddings);
      let m=Iris_event.of_query_row ~source:config.source_id ~bot_id:config.bot_id
          (List.hd (raw_query fixture "SELECT * FROM chat_logs WHERE _id=200" [])) |> Result.get_ok in
      bad_citation:=true;
      Llm.summarize llm ~intent:(Types.overview Types.Today) ~messages:[m] () >>= fun rejected ->
      bad_citation:=false;
      check "fabricated model evidence rejected over HTTP" (rejected=Error Llm.Bad_response);
      Llm.summarize (Llm.create {config with response_format="json_schema"} store)
        ~intent:(Types.overview Types.Today) ~messages:[m] () >>= fun strict ->
      check "schema-capable models retain strict output support" (Result.is_ok strict);
      let iris=Iris.create config in
      fail_second_page:=true;
      Recovery.room ~config ~store ~iris "1001" >>= fun interrupted ->
      check "failed recovery page never advances the cursor"
        (interrupted=Error (Net.Http_status 503) && Store.cursor store ~source:config.source_id ~room:"1001"=200L);
      fail_second_page:=false;
      Recovery.room ~config ~store ~iris "1001" >>= fun resumed ->
      check "recovery resumes from its last committed page" (Result.is_ok resumed && Store.cursor store ~source:config.source_id ~room:"1001"=206L);
      let range={Types.source=config.source_id;room_id="1001";lower=Types.At_time(now-.3600.);
        before_seq=209L;through_time=now;retention_start=now-.86400.;note=None} in
      let history=Store.messages store range in
      let version=Store.room_version store ~source:config.source_id ~room:"1001" in
      Retrieval.select ~config ~store ~llm ~range ~version ~topic:"postgres" ~focus:Types.Conclusions history >>= fun semantic ->
      check "semantic match works without the literal query keyword"
        (List.exists (fun (m:Types.message)->m.seq=1L) (Result.get_ok semantic).Retrieval.messages
         && not (List.exists (fun (m:Types.message)->Retrieval.lexical "postgres" m.text>0.) history));
      let embedded_before= !embeddings in
      Retrieval.select ~config ~store ~llm ~range ~version ~topic:"postgres" ~focus:Types.Conclusions history >>= fun _ ->
      check "cached document embeddings are reused" (!embeddings=embedded_before+1);
      let dry_store=Store.open_ ":memory:" in
      let dry_message={m with Types.seq=209L;native_id=Some(native_id 209);text="/요약 도움말";created_at=now} in
      ignore(Store.put_message dry_store ~is_command:true dry_message);
      let dry_call={Types.message=dry_message;trigger=Types.Slash;prompt="도움말"} in
      ignore(Store.enqueue dry_store ~now ~config dry_call);
      let dry_job=Option.get(Store.claim_job dry_store ~now) in
      Store.finish_job dry_store dry_job ~body:"must not send" ~dry_run:false ~snapshot_version:None ~evidence:None;
      let delivered_before=List.length !deliveries in
      Engine.send_tick (Engine.create {config with dry_run=true} dry_store) >>= fun () ->
      check "switching to dry-run also blocks previously pending delivery"
        (List.length !deliveries=delivered_before && (List.hd(Store.recent_outbox dry_store)).state="pending");
      Store.close dry_store;
      let engine=Engine.create config store in
      running:=Engine.run ~on_ready:(fun port->backend_port:=Some port;Lwt.wakeup_later wake_ready port) ~stop engine;
      ready >>= fun port ->
      let post seq=Net.json ~headers:["x-asko-token","test-ingress"] ~body:(event fixture seq) ~timeout:3. `POST
          (Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/events/iris" port)) in
      let rec wait_sent target attempts =
        if List.length (List.filter (fun (o:Store.outgoing)->o.state="sent") (Store.recent_outbox store))>=target then Lwt.return_unit
        else if attempts=0 then Lwt.fail_with "pipeline did not finish" else Lwt_unix.sleep 0.05 >>= fun ()->wait_sent target (attempts-1) in
      insert fixture ~seq:210 ~room:"1001" ~sender:"2001" ~at:now ~text:"@요약봇 아까 postgres 얘기 결론 뭐임" ~mentions:["9999"] ();
      post 210 >>= fun accepted -> check "natural invocation accepted" (Result.is_ok accepted);
      wait_sent 1 200 >>= fun () ->
      check "semantic search reaches a later reply correction" (List.mem "1" (List.hd !contexts) && List.mem "200" (List.hd !contexts));
      check "more than one recovery page is ingested" (Store.cursor store ~source:config.source_id ~room:"1001">=210L);
      check "backfilled commands never execute" (List.length (Store.recent_outbox store)=1);
      check "summary sources retained" ((List.hd (Store.recent_outbox store)).evidence<>None);
      check "bot echo is not retained as summary input" ((Option.get (Store.get_message store ~source:config.source_id ~seq:211L)).Types.text="");
      post 210 >>= fun _ -> Lwt_unix.sleep 0.1 >>= fun () ->
      check "duplicate callback after recovery does not create another reply" (List.length !deliveries=1);
      insert fixture ~seq:220 ~room:"1001" ~sender:"2001" ~at:now ~text:"이 얘기 어떻게 됐어?" ~reply:(native_id 200) ~mentions:["9999"] ();
      post 220 >>= fun _ -> wait_sent 2 200 >>= fun () ->
      check "reply summary includes its anchor and excludes older messages" (List.hd (List.hd !contexts)="200");
      insert fixture ~seq:230 ~room:"1001" ~sender:"2001" ~at:now ~text:"최근 2시간 대화 정리해줘" ~mentions:["9999"] ();
      post 230 >>= fun _ -> wait_sent 3 200 >>= fun () ->
      check "natural duration request shares the same pipeline" (List.length !deliveries=3);
      check "all results observed, never blindly resent" (List.for_all (fun (o:Store.outgoing)->o.state="sent") (Store.recent_outbox store));
      ignore(Sqlite3.exec fixture "DELETE FROM chat_logs WHERE _id=201");
      fail_second_page:=true;
      Recovery.reconcile ~config ~store ~iris "1001" >>= fun incomplete ->
      check "incomplete reconciliation cannot delete unseen messages"
        (Result.is_error incomplete && not (Option.get(Store.get_message store ~source:config.source_id ~seq:201L)).Types.deleted);
      fail_second_page:=false;
      Recovery.reconcile ~config ~store ~iris "1001" >>= fun reconciled ->
      check "complete source reconciliation erases missing messages"
        (Result.is_ok reconciled && (Option.get(Store.get_message store ~source:config.source_id ~seq:201L)).Types.deleted);
      check "source deletion invalidates stored summary evidence"
        (List.for_all (fun (o:Store.outgoing)->o.body="" && o.evidence=None) (Store.recent_outbox store));
      Lwt.return_unit)
      (fun () ->
        if Lwt.is_sleeping stop then Lwt.wakeup_later wake_stop ();
        !running >>= fun () ->
        if Lwt.is_sleeping mock_stop then Lwt.wakeup_later wake_mock ();
        mock)))
