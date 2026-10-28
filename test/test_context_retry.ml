open Asko
open Types
open Lwt.Infix

let check name value=if not value then failwith name else Printf.printf "ok: %s\n%!" name
let message seq text={source="retry:1";room_id="room";seq;native_id=None;
  sender_id="alice";sender_name="Alice";created_at=1000.;text;reply_to=None;
  mentions=[];is_bot=false;deleted=false}
let () =
  let path=Filename.temp_file "asko-retry" ".sqlite" in
  let store=ref(Store.open_ path) in
  Fun.protect ~finally:(fun ()->Store.close !store;
    List.iter(fun suffix->try Sys.remove(path^suffix) with Sys_error _->()) ["";"-wal";"-shm"])
    (fun ()->Lwt_main.run (
      let socket=Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Lwt_unix.bind socket (Unix.ADDR_INET(Unix.inet_addr_loopback,0)) >>= fun () ->
      Lwt_unix.listen socket 8;
      let port=match Lwt_unix.getsockname socket with Unix.ADDR_INET(_,p)->p | _->assert false in
      let stop,wake=Lwt.wait () in
      let mode=ref "repair" and requests=ref 0 and feedback=ref [] and delays=ref [] in
      let valid=`Assoc ["facts",`List [`Assoc ["text",`String "Development discussion";
        "sources",`List [`Int 0]]]] in
      let callback _ _ body=Cohttp_lwt.Body.to_string body >>= fun body->
        incr requests;
        let json=Yojson.Safe.from_string body in
        let turns=Json_util.required "messages" json |> Json_util.list Fun.id in
        let system=Json_util.required "content" (List.hd turns) |> Json_util.string in
        feedback:=system::!feedback;
        let status,answer=match !mode with
          | "auth"->`Unauthorized,valid | "busy"->`Service_unavailable,valid
          | "invalid"->`OK,`Assoc ["facts",`List [];"extra",`Bool true]
          | "repair" when !requests=1->`OK,`Assoc ["facts",`List [];"extra",`Bool true]
          | "repair" when !requests=2->`OK,`Assoc ["facts",`List [`Assoc ["text",`String "x";
              "sources",`List [`Int 99]]]]
          | _->`OK,valid in
        let response=`Assoc ["choices",`List [`Assoc ["finish_reason",`String "stop";
          "message",`Assoc ["role",`String "assistant";"content",`String(Json_util.to_string answer)]]]] in
        Cohttp_lwt_unix.Server.respond_string ~status ~body:(Json_util.to_string response) () in
      let server=Cohttp_lwt_unix.Server.create ~stop ~mode:(`TCP(`Socket socket))
        (Cohttp_lwt_unix.Server.make ~callback ()) in
      let config={Config.default with rooms=["room"];api_key="test";api_key_env="ASKO_RETRY_TEST_KEY";
        openrouter_url=Printf.sprintf "http://127.0.0.1:%d" port;reasoning_enabled=false} in
      Unix.putenv config.api_key_env "";
      let job seq=
        let msg=message seq "summarize" in
        ignore(Store.put_message !store ~is_command:true msg);
        match Store.enqueue !store ~now:1000. ~config {message=msg;trigger=Mention;prompt=msg.text} with
        | Store.Queued id->id | _->assert false in
      let first=job 100L and other=job 101L in
      let batch=[message 1L "original"] in
      ignore(Store.put_message !store ~is_command:false (List.hd batch));
      ignore(Store.put_message !store ~is_command:false (message 2L "other batch"));
      let run ?(config=config) ?(request="summarize") ?(messages=batch) id =
        Context_retry.notes ~sleep:(fun seconds->delays:=seconds::!delays;Lwt.return_unit)
          ~store:!store ~job_id:(Some id) ~llm:(Llm.create config !store) ~request
          ~call:(fun f->if Store.reserve_model_call !store ~job_id:id ~limit:64 then f () else
            Lwt.return(Error(Llm.Limit_exceeded {resource="max_tool_rounds";actual=None;limit=64}))) messages in
      Lwt.finalize (fun () ->
        run first >>= fun repaired->
        check "extra fields and bad source rows are repaired within three attempts"
          (Result.is_ok repaired && !requests=3);
        let systems=List.rev !feedback in
        check "retry explains extra fields then invalid row numbers"
          (Retrieval.contains (List.nth systems 1) "unexpected model field" &&
           Retrieval.contains (List.nth systems 2) "source row outside this batch");
        check "successful notes map rows to the original message IDs"
          (Json_util.required "sources" (List.hd(Result.get_ok repaired))=Llm.strings ["1"]);
        Store.close !store;store:=Store.open_ path;
        run first >>= fun cached->
        check "validated notes survive process restart without another model call"
          (cached=repaired && !requests=3 && Store.job_model_calls !store first=3);
        mode:="valid";
        run other >>= fun _->
        check "another job cannot reuse this job's notes" (!requests=4);
        run ~messages:[message 1L "edited original"] first >>= fun _->
        check "edited original invalidates cached notes" (!requests=5);
        run ~config:{config with model="different-model"} first >>= fun _->
        check "model change invalidates cached notes" (!requests=6);
        run ~request:"different task" first >>= fun _->
        check "request change invalidates cached notes" (!requests=7);
        check "call budget remains consumed across process restart"
          (Store.job_model_calls !store first=6 &&
           not(Store.reserve_model_call !store ~job_id:first ~limit:6));
        mode:="invalid";let failed=job 102L in let before= !requests in
        run failed >>= fun invalid->
        check "persistent invalid output stops at three attempts and skips whole-job retries"
          (!requests=before+3 && match invalid with Error e->not(Llm.retryable e) | _->false);
        run failed >>= fun _->
        check "job retry cannot reset a failed batch's attempt limit" (!requests=before+3);
        mode:="auth";let unauthorized=job 103L in let before= !requests in
        run unauthorized >>= fun auth->
        check "authentication errors stop immediately"
          (!requests=before+1 && auth=Error(Llm.Network(Net.Http_status 401)) && !delays=[]);
        mode:="busy";let unavailable=job 104L in let before= !requests in
        run unavailable >>= fun _->
        check "transient service errors use bounded exponential backoff"
          (!requests=before+3 && match List.rev !delays with
            | [a;b]->a>=1. && a<1.25 && b>=2. && b<2.25 | _->false);
        mode:="valid";
        run ~messages:[message 2L "other batch"] first >>= fun _->
        ignore(Store.put_message !store ~is_command:false (message 1L "edited"));
        check "source edit erases dependent notes but preserves unrelated batches"
          (Store.count !store "SELECT COUNT(*) FROM context_notes WHERE job_id=?" [Store.integer first]=1);
        ignore(Store.reserve_context_notes !store ~job_id:first ~key:"in-flight" ~dependencies:[2L]);
        ignore(Store.put_message !store ~is_command:false {(message 2L "other batch") with deleted=true});
        Store.save_context_notes !store ~job_id:first ~key:"in-flight" ~notes:(Some "[]") ~error:None;
        check "source deletion erases its cached notes"
          (Store.count !store "SELECT COUNT(*) FROM context_notes WHERE job_id=?" [Store.integer first]=0);
        check "late completion cannot recreate notes invalidated while in flight"
          (Store.context_notes !store ~job_id:first ~key:"in-flight"=(0,None,None));
        let expired={(message 3L "expired batch") with created_at=900.} in
        ignore(Store.put_message !store ~is_command:false expired);
        run ~messages:[expired] first >>= fun _->
        ignore(Store.purge !store ~before:950.);
        check "retention erases notes even when their newer request is retained"
          (Store.get_message !store ~source:"retry:1" ~seq:100L<>None &&
           Store.count !store "SELECT COUNT(*) FROM context_notes WHERE job_id=?" [Store.integer first]=0);
        run ~messages:[message 3L "new batch"] first >>= fun _->
        Store.run !store "DELETE FROM jobs WHERE id=?" [Store.integer first];
        check "job deletion also removes its cached notes"
          (Store.count !store "SELECT COUNT(*) FROM context_notes WHERE job_id=?" [Store.integer first]=0);
        Lwt.return_unit)
        (fun ()->Lwt.wakeup_later wake ();server)))
