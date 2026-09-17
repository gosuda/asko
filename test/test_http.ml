open Asko
open Lwt.Infix
let check name value = if not value then failwith name else Printf.printf "ok: %s\n%!" name
let get name json = Json_util.required name json

let event ?(room="a") ?(sender="alice") ?(mentions=[]) seq message = `Assoc [
  "msg", `String message; "room", `String "display name is not identity"; "sender", `String sender;
  "json", `Assoc ["_id", `String (string_of_int seq); "id", `String ("native-" ^ string_of_int seq);
    "chat_id", `String room; "user_id", `String sender; "created_at", `Float (Unix.gettimeofday ());
    "attachment", `Assoc ["mentions", `List (List.map (fun id -> `Assoc ["user_id",`String id]) mentions)]; "v", `String "{}"]]

let () =
  let path = Filename.temp_file "asko-http" ".sqlite" in
  let store = Store.open_ path in
  let config = {Config.default with port=0; db_path=path; source_id="http:1";
                rooms=["a"]; bot_id="bot"; cooldown=0.; ingest_token_env="ASKO_TEST_INGEST_TOKEN"} in
  Unix.putenv config.ingest_token_env "test-secret";
  let cleanup () =
    Store.close store;
    List.iter (fun p -> try Sys.remove p with Sys_error _ -> ()) [path;path^"-wal";path^"-shm"] in
  Fun.protect ~finally:cleanup (fun () -> Lwt_main.run (
    let stop, stop_waker = Lwt.wait () in
    let ready, ready_waker = Lwt.wait () in
    let server = Server.run ~on_ready:(Lwt.wakeup_later ready_waker) ~stop config store in
    Lwt.finalize (fun () -> ready >>= fun port ->
      let url path = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path) in
      let headers = ["x-asko-token","test-secret"] in
      let post data = Net.json ~headers ~body:data ~timeout:3. `POST (url "/events/iris") in
      Net.json ~timeout:3. `GET (url "/health") >>= fun health ->
      check "HTTP health returns JSON" (get "ok" (Result.get_ok health)=`Bool true);
      Net.json ~body:(event 1 "안녕") ~timeout:3. `POST (url "/events/iris") >>= fun unauthorized ->
      check "unauthorized webhook rejected" (unauthorized=Error (Net.Http_status 401));
      post (event ~room:"b" 1 "비공개 방") >>= fun ignored ->
      check "disallowed room not stored" (get "stored" (Result.get_ok ignored)=`Bool false);
      post (event 1 "한국어 대화") >>= fun inserted ->
      check "UTF-8 Iris event stored" (get "inserted" (Result.get_ok inserted)=`Bool true);
      post (event 1 "한국어 대화") >>= fun duplicate ->
      check "duplicate HTTP event remains idempotent" (get "inserted" (Result.get_ok duplicate)=`Bool false);
      post (event ~mentions:["bot"] 2 "@요약봇 오늘 중요한거") >>= fun invocation ->
      check "HTTP mention produces a durable job" (get "job_state" (Result.get_ok invocation)=`String "queued");
      post (event ~sender:"bot" 3 "@요약봇 오늘") >>= fun echo ->
      check "bot output never triggers a new job" (get "job_state" (Result.get_ok echo)=`String "not_requested");
      Net.request ~headers ~body:"{" ~timeout:3. `POST (url "/events/iris") >>= fun invalid ->
      check "malformed JSON is a client error" (match invalid with Ok (400,_) -> true | _ -> false);
      Net.json ~timeout:3. `GET (url "/not-a-route") >>= fun missing ->
      check "unknown route returns 404" (missing=Error (Net.Http_status 404));
      let stored = Store.get_message store ~source:"http:1" ~seq:1L |> Option.get in
      check "persisted UTF-8 remains intact" (stored.Types.text="한국어 대화");
      Lwt.return_unit)
      (fun () -> if Lwt.is_sleeping stop then Lwt.wakeup_later stop_waker (); server)))
