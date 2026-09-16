let take bytes text =
  if bytes < 0 || not (String.is_valid_utf_8 text) then invalid_arg "UTF-8 boundary";
  if String.length text <= bytes then text else
    let index = ref bytes in
    while !index > 0 && Char.code text.[!index] land 0xc0 = 0x80 do decr index done;
    String.sub text 0 !index

let parts bytes text =
  if bytes < 4 then invalid_arg "UTF-8 part size";
  let rec loop offset acc =
    if offset = String.length text then List.rev acc else
    let remaining = String.sub text offset (String.length text - offset) in
    let part = take bytes remaining in
    loop (offset + String.length part) (part :: acc)
  in loop 0 []
