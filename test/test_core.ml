open Asko
open Types

let failures = ref 0
let check name predicate =
  if predicate then Printf.printf "ok: %s\n" name
  else (incr failures; Printf.eprintf "FAIL: %s\n" name)

let message ?(seq=100L) ?(room_id="room-a") ?(sender_id="alice")
    ?(created_at=1789516800.) ?reply_to ?(mentions=[]) ?(is_bot=false) text =
  { source="phone:1"; seq; native_id=Some ("native-" ^ Int64.to_string seq);
    room_id; sender_id; sender_name=sender_id; created_at; text;
    reply_to; mentions; is_bot; deleted=false }

let detect = Trigger.detect ~bot_id:"bot"
let invocation text = Option.get (detect (message ~mentions:["bot"] text))
let () =
  check "plain conversation ignored" (detect (message "오늘 postgres 얘기함") = None);
  check "typed bot name is not a native mention" (detect (message "@요약봇 오늘") = None);
  check "quoted mention ignored" (detect (message "> @요약봇 오늘") = None);
  check "bot echo ignored" (detect (message ~sender_id:"bot" "/요약") = None);
  check "ordinary reply ignored" (detect (message ~reply_to:"native-80" "그러네") = None);
  check "slash boundary" (detect (message "/요약서 작성") = None);
  check "mention accepted" ((invocation "@요약봇 오늘").trigger = Mention);
  check "native mention accepted" (Option.is_some (detect (message ~mentions:["bot"] "오늘 뭐있었어")));
  check "reply accepted" ((Option.get (detect (message ~reply_to:"native-80" "여기부터 요약"))).trigger = Reply);
  check "mention and reply produce one call"
    ((Option.get (detect (message ~mentions:["bot"] ~reply_to:"native-80" "@요약봇 오늘"))).trigger = Mention);
  check "fixed duration with topic"
    (Intent.shortcut (invocation "/요약 2시간 postgres 결론") =
     Summarize {scope=Last_minutes 120; topic=Some "postgres"; focus=Conclusions});
  check "free language classified later" (Intent.shortcut (invocation "@요약봇 잠깐 못봤는데 뭐 있었음") = Classify);
  check "natural today request is not mistaken for a topic" (Intent.shortcut (invocation "@요약봇 오늘 뭐 얘기함?") = Classify);
  check "invalid model range rejected" (Result.is_error (Intent.validate (overview (Last_minutes (-1)))));
  let call = invocation "/요약" in
  let prior = message ~seq:90L ~created_at:(call.message.created_at -. 30.) "마지막 발언" in
  let resolve ?previous ?anchor intent =
    Scope.resolve ~retention_start:0. ~previous ~anchor call intent |> Result.get_ok in
  let after = resolve ~previous:prior (overview Since_previous) in
  check "previous message is exclusive" (not (in_range after prior));
  check "same-second earlier messages included" (in_range after (message ~seq:99L "same second"));
  check "current invocation excluded" (not (in_range after call.message));
  check "later messages excluded" (not (in_range after (message ~seq:101L "later")));
  check "other room excluded even with matching sequence" (not (in_range after (message ~seq:99L ~room_id:"room-b" "private")));
  let fallback = resolve ~previous:(message ~seq:90L ~room_id:"room-b" "other room") (overview Since_previous) in
  check "other room never supplies previous anchor" (match fallback.lower with At_time _ -> true | _ -> false);
  check "missing history has explicit fallback" ((resolve (overview Since_previous)).note <> None);
  check "KST midnight is stable" (Scope.midnight 0. = -32400.);
  let replied = {call with message={call.message with reply_to=prior.native_id}} in
  let range = Scope.resolve ~retention_start:0. ~previous:None ~anchor:(Some prior) replied (overview From_reply) |> Result.get_ok in
  check "reply anchor is inclusive" (in_range range prior);
  check "reply native ID is not the local sequence"
    (Result.is_error (Scope.resolve ~retention_start:0. ~previous:None ~anchor:(Some {prior with native_id=Some "90"}) replied (overview From_reply)));
  check "deleted reply fails explicitly"
    (Result.is_error (Scope.resolve ~retention_start:0. ~previous:None ~anchor:(Some {prior with deleted=true}) replied (overview From_reply)));
  if !failures > 0 then exit 1
