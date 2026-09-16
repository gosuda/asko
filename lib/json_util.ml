exception Invalid of string
let invalid message = raise (Invalid message)
let object_ = function
  | `Assoc fields ->
      let names = List.map fst fields in
      if List.length (List.sort_uniq String.compare names) <> List.length names then
        invalid "duplicate JSON keys";
      fields
  | _ -> invalid "expected JSON object"
let field name json = List.assoc_opt name (object_ json)
let required name json = match field name json with Some value -> value | None -> invalid ("missing " ^ name)
let string = function `String value -> value | _ -> invalid "expected string"
let id = function
  | `String value | `Intlit value ->
      if value = "" || String.length value > 128 || String.exists (fun c -> Char.code c < 32) value
      then invalid "invalid ID" else value
  | `Int value -> string_of_int value
  | _ -> invalid "expected exact string or integer ID"
let int = function `Int value -> value | _ -> invalid "expected integer"
let float = function
  | `Float value -> if Float.is_finite value then value else invalid "non-finite number"
  | `Int value -> float_of_int value
  | `Intlit value | `String value ->
      (match float_of_string_opt value with Some value when Float.is_finite value -> value | _ -> invalid "invalid number")
  | _ -> invalid "expected number"
let bool = function `Bool value -> value | _ -> invalid "expected boolean"
let list decode = function `List values -> List.map decode values | _ -> invalid "expected array"
let optional decode = function None | Some `Null -> None | Some value -> Some (decode value)
let default decode value = function None | Some `Null -> value | Some json -> decode json
let json_string = function
  | `String "" | `String "{}" | `Null -> `Assoc []
  | `String value -> Yojson.Safe.from_string value
  | `Assoc _ as json -> json
  | _ -> invalid "expected embedded JSON object"
let protect f =
  try Ok (f ()) with
  | Invalid message -> Error message
  | Yojson.Json_error _ -> Error "invalid JSON"
  | Failure _ | Invalid_argument _ -> Error "invalid value"
let to_string = Yojson.Safe.to_string
let option encode = function None -> `Null | Some value -> encode value
