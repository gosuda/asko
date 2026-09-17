open Types

let is_space = function ' ' | '\t' | '\r' | '\n' -> true | _ -> false
let normalize text =
  text |> String.map (fun c -> if is_space c then ' ' else c)
  |> String.split_on_char ' ' |> List.filter (( <> ) "") |> String.concat " "

let strip_token token text =
  let len = String.length token in
  if text = token then Some ""
  else if String.starts_with ~prefix:token text && String.length text > len
          && (is_space text.[len] || List.mem text.[len] [':'; ',']) then
    Some (String.trim (String.sub text (len + 1) (String.length text - len - 1)))
  else None

let reply_request text =
  let text = normalize text in
  List.mem text ["여기부터 요약"; "여기부터 요약해줘"; "여기부터 요약해주세요";
                  "여기부터 정리해줘"; "이후 대화 요약"; "이후 대화 요약해줘"]

let detect ~bot_id message =
  let text = String.trim message.text in
  if message.is_bot || message.deleted || message.sender_id = bot_id
     || String.starts_with ~prefix:">" text || String.starts_with ~prefix:"```" text
  then None
  else
    let make trigger prompt = Some { message; trigger; prompt } in
    match strip_token "/요약" text with
    | Some prompt -> make Slash prompt
    | None when bot_id <> "" && List.mem bot_id message.mentions -> make Mention text
    | None when message.reply_to <> None && reply_request text -> make Reply text
    | None -> None
