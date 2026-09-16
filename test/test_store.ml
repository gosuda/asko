open Asko
open Types

let check name predicate = if not predicate then failwith name else Printf.printf "ok: %s\n" name
let message ?(room_id="a") ?(sender_id="alice") ?reply_to seq text = {
  source="fixture:1"; seq; native_id=Some ("native-" ^ Int64.to_string seq);
  room_id; sender_id; sender_name=sender_id; created_at=10000. +. Int64.to_float seq;
  text; reply_to; mentions=[]; is_bot=false; deleted=false;
}
let payload = {|{"msg":"여기부터 요약","sender":"앨리스","json":{"_id":"101","id":"9007199254740993","chat_id":"a","user_id":"alice","created_at":"10101","attachment":"{\"src_logId\":9007199254740992,\"mentions\":[{\"user_id\":\"bot\"}]}","v":"{\"isMine\":false}"}}|}
let () =
  let event = Iris_event.normalize ~source:"fixture:1" ~bot_id:"bot" (Yojson.Safe.from_string payload) |> Result.get_ok in
  check "large native IDs preserve integer precision" (event.native_id=Some "9007199254740993" && event.reply_to=Some "9007199254740992");
  check "mention metadata parsed" (event.mentions=["bot"]);
  check "malformed source ID rejected" (Result.is_error (Iris_event.normalize ~source:"x" ~bot_id:"bot" (`Assoc ["json", `Assoc []])));
  check "duplicate JSON fields rejected" (Result.is_error (Config.of_json (`Assoc ["port",`Int 8000; "port",`Int 9000])));
  check "remote plaintext LLM endpoint rejected" (Result.is_error (Config.of_json (`Assoc ["openrouter_url", `String "http://example.com/api"])));
  check "live delivery needs bot ID" (Result.is_error (Config.of_json (`Assoc ["dry_run", `Bool false])));
  let path = Filename.temp_file "asko-test" ".sqlite" in
  let backup=path^".backup" in
  let cleanup () = List.iter (fun p -> try Sys.remove p with Sys_error _ -> ())
    [path;path^"-wal";path^"-shm";backup;backup^"-wal";backup^"-shm"] in
  Fun.protect ~finally:cleanup (fun () ->
    let db = Store.open_ path in
    let prior = message 10L "postgres를 써볼까" in
    let other = message ~room_id:"b" 11L "다른 방의 비밀" in
    let current = message 20L "/요약" in
    let later = message 21L "나중 대화" in
    let config = {Config.default with cooldown=0.; rooms=["a"]} in
    let call = {message=current; trigger=Slash; prompt=""} in
    check "first insert" (Store.put_message db ~is_command:false prior);
    check "duplicate message idempotent" (not (Store.put_message db ~is_command:false prior));
    check "native ID reuse cannot overwrite a source generation"
      (try ignore (Store.put_message db ~is_command:false {prior with native_id=Some "different-native"}); false with Store.Error _->true);
    ignore (Store.put_message db ~is_command:false other);
    ignore (Store.put_message db ~is_command:true current);
    ignore (Store.put_message db ~is_command:false later);
    check "current command never becomes previous activity" ((Option.get (Store.previous db current)).seq=10L);
    let range = Scope.resolve ~retention_start:0. ~previous:(Store.previous db current) ~anchor:None call (overview Today) |> Result.get_ok in
    let history = Store.messages db range in
    check "room, command and upper boundary enforced in SQL" (List.map (fun (m:message) -> m.seq) history=[10L]);
    let created = Store.enqueue db ~now:10020. ~config call in
    check "live event queues even after backfill inserted message" (match created with Store.Queued _ -> true | _ -> false);
    check "duplicate event cannot enqueue another job" (Store.enqueue db ~now:10020. ~config call=Store.Duplicate);
    let job = Option.get (Store.claim_job db ~now:10020.) in
    check "claimed once" (Store.claim_job db ~now:10020.=None);
    Store.close db;
    let db = Store.open_ path in
    Store.recover_jobs db ~now:10021.;
    let recovered = Option.get (Store.claim_job db ~now:10021.) in
    check "job survives process restart" (job.id=recovered.id && recovered.attempts=2);
    Store.finish_job db recovered ~body:"검증된 요약" ~dry_run:false ~snapshot_version:None ~evidence:None;
    let outgoing = Option.get (Store.next_outgoing db ~now:10022.) in
    check "delivery intent persisted before network" (outgoing.body="검증된 요약");
    check "send claim persisted" (Store.begin_send db outgoing ~floor_seq:21L ~now:10022.);
    Store.close db;
    let db = Store.open_ path in
    Store.recover_jobs db ~now:10023.;
    check "interrupted send is uncertain, never automatically resent" (Store.next_outgoing db ~now:10023.=None);
    check "uncertain state retained" ((List.hd (Store.recent_outbox db)).state="uncertain");
    let echo = {(message ~sender_id:"bot" 22L "검증된 요약") with is_bot=true} in
    Store.transaction db (fun () -> Store.confirm_message db echo);
    check "later observed bot echo confirms uncertain delivery" ((List.hd (Store.recent_outbox db)).state="sent");
    Store.outgoing_state db outgoing ~state:"awaiting_echo" ();
    check "late HTTP acknowledgement cannot undo a confirmed echo" ((List.hd (Store.recent_outbox db)).state="sent");
    Store.backup db backup;
    check "backup never overwrites an existing file"
      (try Store.backup db backup; false with Unix.Unix_error(Unix.EEXIST,_,_)->true);
    let version = Store.room_version db ~source:"fixture:1" ~room:"a" in
    Store.put_embedding db ~source:"fixture:1" ~room:"a" ~key:"k" ~model:"embed" ~content:"old text" ~at:10023. ~version [|1.;0.|];
    check "embedding cannot cross rooms" (Store.get_embedding db ~source:"fixture:1" ~room:"b" ~key:"k" ~model:"embed" ~content:"old text"=None);
    check "cache hash collision cannot reuse different text" (Store.get_embedding db ~source:"fixture:1" ~room:"a" ~key:"k" ~model:"embed" ~content:"changed"=None);
    ignore (Store.put_message db ~is_command:false {prior with deleted=true});
    check "deleted content is erased" ((Option.get (Store.get_message db ~source:"fixture:1" ~seq:10L)).Types.text="");
    ignore (Store.put_message db ~is_command:false prior);
    check "late duplicate cannot resurrect a tombstone" ((Option.get (Store.get_message db ~source:"fixture:1" ~seq:10L)).Types.deleted);
    let snapshot=Store.open_ backup in
    check "backup is an independent consistent snapshot" ((Option.get (Store.get_message snapshot ~source:"fixture:1" ~seq:10L)).Types.text=prior.text);
    Store.close snapshot;
    check "message change invalidates derived embeddings" (Store.get_embedding db ~source:"fixture:1" ~room:"a" ~key:"k" ~model:"embed" ~content:"old text"=None);
    check "in-flight embedding cannot resurrect deleted data"
      (try Store.put_embedding db ~source:"fixture:1" ~room:"a" ~key:"k" ~model:"embed" ~content:"old text" ~at:10024. ~version [|1.;0.|]; false with Store.Stale_snapshot -> true);
    Store.record_tokens db ~at:10023. 100;
    ignore (Store.purge db ~before:10030.);
    check "retention removes source messages" (Store.get_message db ~source:"fixture:1" ~seq:20L=None);
    check "retention cascades output data" (Store.recent_outbox db=[]);
    check "aggregate budget survives content deletion" (Store.tokens_today db ~at:10023.=100);
    Store.close db)
