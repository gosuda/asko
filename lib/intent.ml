open Types

let words text = String.split_on_char ' ' (Trigger.normalize text)

let minutes token =
  let parse suffix multiplier =
    if String.ends_with ~suffix token then
      let number = String.sub token 0 (String.length token - String.length suffix) in
      match int_of_string_opt number with
      | Some n when n > 0 && n <= 10080 / multiplier -> Some (n * multiplier)
      | _ -> None
    else None
  in
  match parse "시간" 60 with Some _ as value -> value | None -> parse "분" 1

let from_words scope rest =
  let focus, rest =
    if List.mem "결론" rest then Conclusions, List.filter (( <> ) "결론") rest
    else if List.exists (fun word -> List.mem word ["중요한거"; "중요한것"; "중요한것만"]) rest
    then Highlights, List.filter (fun word -> not (List.mem word ["중요한거"; "중요한것"; "중요한것만"])) rest
    else Overview, rest
  in
  let topic = match rest with [] -> None | xs -> Some (String.concat " " xs) in
  Summarize { scope; topic; focus }

let shortcut invocation =
  let tokens = words invocation.prompt in
  match invocation.trigger, tokens with
  | _, ["도움말"] | _, ["help"] -> Help
  | Reply, _ -> Summarize (overview From_reply)
  | Slash, [] -> Summarize (overview Since_previous)
  | Mention, [] -> Help
  | _, ["오늘"] -> from_words Today []
  | _, ["오늘"; ("중요한거" | "중요한것" | "중요한것만" as word)] -> from_words Today [word]
  | Slash, "오늘" :: rest -> from_words Today rest
  | _, "이후" :: [] -> Summarize (overview Since_previous)
  | _, "여기부터" :: [] when invocation.message.reply_to <> None -> Summarize (overview From_reply)
  | Slash, token :: rest ->
      (match minutes token with Some n -> from_words (Last_minutes n) rest | None -> Classify)
  | _ -> Classify

let validate intent =
  match intent.scope, intent.topic with
  | Last_minutes n, _ when n <= 0 || n > 10080 -> Error "minutes must be between 1 and 10080"
  | _, Some topic when String.trim topic = "" || String.length topic > 1024 -> Error "invalid topic"
  | _ -> Ok intent
