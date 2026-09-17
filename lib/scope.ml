open Types

let seoul_offset = 9. *. 3600.
let midnight at = floor ((at +. seoul_offset) /. 86400.) *. 86400. -. seoul_offset

let resolve ~retention_start ~previous ~anchor invocation intent =
  let request = invocation.message in
  let make ?note lower =
    Ok { source = request.source; room_id = request.room_id;
         lower; before_seq = request.seq; through_time = request.created_at;
         retention_start; note }
  in
  let at_time start =
    if start < retention_start then
      make ~note:"보관 중인 대화부터 요약했어요." (At_time retention_start)
    else make (At_time start)
  in
  match Intent.validate intent with
  | Error error -> Error error
  | Ok _ ->
      match intent.scope with
      | Today -> at_time (midnight request.created_at)
      | Recent -> at_time (request.created_at -. 86400.)
      | Retained -> make ~note:"보관 중인 대화를 기준으로 확인했어요." (At_time retention_start)
      | Last_minutes n -> at_time (request.created_at -. float_of_int (n * 60))
      | Since_previous ->
          (match previous with
           | Some message when is_before message request && message.sender_id = request.sender_id
                               && not message.is_bot && not message.deleted ->
               if message.created_at < retention_start then
                 make ~note:"이전 발언이 보관 기간 밖에 있어, 보관 중인 대화부터 요약했어요."
                   (At_time retention_start)
               else make (After_message message.seq)
           | _ -> make ~note:"보관된 이전 발언이 없어 최근 1시간을 요약했어요."
                    (At_time (max retention_start (request.created_at -. 3600.))))
      | From_reply ->
          (match anchor with
           | Some message when is_before message request && not message.deleted
                               && message.created_at >= retention_start
                               && message.native_id = request.reply_to && request.reply_to <> None ->
               make (From_message message.seq)
           | _ -> Error "답장 원본을 찾을 수 없어요. 다른 메시지에 답장하면서 봇을 멘션하거나, 봇을 멘션하고 오늘 대화를 요청해주세요.")

let seoul_time at =
  let t = Unix.gmtime (at +. seoul_offset) in
  Printf.sprintf "%02d/%02d %02d:%02d" (t.Unix.tm_mon + 1) t.Unix.tm_mday t.Unix.tm_hour t.Unix.tm_min
