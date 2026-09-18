open Asko
open Types
let check name value = if not value then failwith name else Printf.printf "ok: %s\n" name
let message ?(room="a") ?reply_to seq text = {
  source="test"; room_id=room; seq; native_id=Some (Int64.to_string seq);
  sender_id="alice"; sender_name="앨리스"; created_at=10000.+.Int64.to_float seq;
  text; reply_to; mentions=[]; is_bot=false; deleted=false;
}
let json = Yojson.Safe.from_string
let () =
  let max_bytes=Llm.answer_limit Config.default in
  let messages=[message 1L "postgres를 검토했어"; message 2L "아직 결정 안 했어"] in
  let answer=Llm.decode_answer ~max_bytes ~messages (json {|{"answer":"앨리스님이 postgres를 검토하자고 했어요.","sources":["1"]}|}) in
  check "grounded conversational answer accepted" (Result.is_ok answer);
  check "answer cannot cite an invented message"
    (Result.is_error(Llm.decode_answer ~max_bytes ~messages (json {|{"answer":"다른 방에서 말했어요.","sources":["999"]}|})));
  let timeline=String.concat "\n\n" (List.init 40 (fun i -> string_of_int i ^ "시: " ^
    String.concat " " (List.init 24 (fun _->"설명")))) in
  let long_json=`Assoc ["answer",`String timeline;"sources",`List [`String "1"]] in
  let long_answer=Llm.decode_answer ~max_bytes ~messages long_json in
  check "long Korean timeline accepted beyond the old 6000-byte cap"
    (String.length timeline>6000 && Result.is_ok long_answer);
  let rendered_long=Summary.render_answer ~max_bytes:Config.default.max_response_bytes ~messages (Result.get_ok long_answer) in
  check "long answer keeps all paragraphs and evidence"
    (String.starts_with ~prefix:timeline rendered_long && Retrieval.contains rendered_long "근거:");
  check "smaller configured answer limit is respected"
    (Result.is_error(Llm.decode_answer ~max_bytes:6000 ~messages long_json));
  let rendered_answer=Summary.render_answer ~max_bytes:7000 ~messages (Result.get_ok answer) in
  check "answer is direct rather than a forced summary"
    (String.starts_with ~prefix:"앨리스님" rendered_answer && not(Retrieval.contains rendered_answer "확인된 대화"));
  let summary=Llm.decode_summary ~messages (json {|{"bullets":[{"text":"DB 선택은 아직 미정이에요.","sources":["2"]}],"conclusion":"undecided"}|}) in
  check "valid evidence accepted" (Result.is_ok summary);
  check "fabricated source IDs rejected" (Result.is_error (Llm.decode_summary ~messages (json {|{"bullets":[{"text":"합의됨","sources":["999"]}],"conclusion":"agreed"}|})));
  check "ungrounded bullet rejected" (Result.is_error (Llm.decode_summary ~messages (json {|{"bullets":[{"text":"합의됨","sources":[]}],"conclusion":"agreed"}|})));
  check "vector dimension mismatch rejected" (Retrieval.cosine [|1.;0.|] [|1.|]=None);
  check "zero vector rejected" (Retrieval.cosine [|0.;0.|] [|1.;0.|]=None);
  check "semantic similarity" (Retrieval.cosine [|1.;0.|] [|2.;0.|]=Some 1.);
  let long=String.concat "" (List.init 5000 (fun _->"한글🦊")) in
  let pieces=Utf8.parts 3500 long in
  check "UTF-8 splitting preserves every byte" (String.concat "" pieces=long && List.for_all String.is_valid_utf_8 pieces);
  let batches=Summary.batches ~bytes:6000 [message 1L long] in
  check "period splitting never drops long-message content"
    (String.concat "" (List.concat_map (List.map (fun (m:message)->m.text)) batches)=long);
  let chunks=Retrieval.chunks [message 1L long] in
  check "embedding inputs stay below context budget" (List.for_all (fun (c:Retrieval.chunk)->String.length c.content<=6000) chunks);
  let middle=List.init 10 (fun index->message (Int64.of_int (index+2)) "다른 얘기") in
  let end_reply=message ~reply_to:"1" 20L "정정할게, 결론은 아직 미정" in
  let expanded=Retrieval.expand (List.hd messages::middle@[end_reply]) [List.hd messages] in
  check "reply context reaches a later correction" (List.exists (fun (m:message)->m.seq=20L) expanded);
  let range={source="test";room_id="a";lower=At_time 10000.;before_seq=30L;through_time=10030.;retention_start=0.;note=None} in
  let rendered=Summary.render ~max_bytes:700 ~range ~intent:{scope=Recent;topic=Some "postgres";focus=Conclusions}
      ~messages ~notes:[] (Result.get_ok summary) in
  check "render includes uncertainty and valid UTF-8"
    (String.is_valid_utf_8 rendered && String.length rendered<=700 && Retrieval.contains rendered "아직 결정되지");
  check "keyword aliases supplement embeddings" (Retrieval.lexical "postgres" "포스트그레스 관련 얘기">0.)
