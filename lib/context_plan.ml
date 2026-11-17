open Types

let timestamp at = match Ptime.of_float_s at with
  | Some time -> Ptime.to_rfc3339 ~tz_offset_s:32400 time | None -> ""

(* The requester's earlier exchange, with the coverage and web pages its answer used. *)
let reference_json = function
  | None -> `Null
  | Some (r:Store.answer_reference) ->
      let stored key=match r.evidence with None->`Null | Some value->
        match Json_util.protect(fun ()->Yojson.Safe.from_string value |> Json_util.field key) with
        | Ok(Some json)->json | _->`Null in
      `Assoc [
      "question",`String r.question.text;"answer",`String r.body;
      "time",`String(timestamp r.question.created_at);
      "coverage",stored "coverage";"web_sources",stored "web"]
