open Types

let is_space = function ' ' | '\t' | '\r' | '\n' -> true | _ -> false
let normalize text =
  text |> String.map (fun c -> if is_space c then ' ' else c)
  |> String.split_on_char ' ' |> List.filter (( <> ) "") |> String.concat " "

(* A mention always invokes the bot. A quoted reply to one of the bot's own
   messages does too when the caller has confirmed the quoted message is the bot's. *)
let detect ?(reply_to_bot=false) ~bot_id message =
  if message.is_bot || message.deleted || message.sender_id = bot_id || bot_id = "" then None
  else if List.mem bot_id message.mentions
  then Some { message; trigger=Mention; prompt=String.trim message.text }
  else if reply_to_bot && message.reply_to<>None && String.trim message.text<>""
  then Some { message; trigger=Reply; prompt=String.trim message.text }
  else None
