open Types

let is_space = function ' ' | '\t' | '\r' | '\n' -> true | _ -> false
let normalize text =
  text |> String.map (fun c -> if is_space c then ' ' else c)
  |> String.split_on_char ' ' |> List.filter (( <> ) "") |> String.concat " "

let detect ~bot_id message =
  if message.is_bot || message.deleted || message.sender_id = bot_id
     || bot_id = "" || not (List.mem bot_id message.mentions)
  then None
  else Some { message; trigger=Mention; prompt=String.trim message.text }
