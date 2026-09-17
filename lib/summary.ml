open Types
open Lwt.Infix

let batches ~bytes messages =
  let fragments=List.concat_map (fun (m:message) ->
    List.map (fun text -> {m with text}) (if m.text="" then [""] else Utf8.parts (max 1024 (bytes/2)) m.text)) messages in
  let size (m:message) = String.length (Json_util.to_string (Llm.context m)) + 1 in
  let rec loop current used result = function
    | [] -> List.rev (if current=[] then result else List.rev current :: result)
    | m::rest ->
        let next=size m in
        if current<>[] && used+next>bytes then loop [m] next (List.rev current::result) rest
        else loop (m::current) (used+next) result rest in
  loop [] 0 [] fragments

let generate llm ~intent ?request messages =
  let groups=batches ~bytes:(max 1024 (llm.Llm.config.max_input_bytes-8192)) messages in
  if groups=[] || List.length groups>8 then Lwt.return (Error Llm.Input_too_large)
  else
    let rec summarize acc = function
      | [] -> Lwt.return (Ok (List.rev acc))
      | group::rest -> Llm.summarize llm ~intent ?request ~messages:group () >>= function
          | Error error -> Lwt.return (Error error)
          | Ok summary -> summarize (summary::acc) rest in
    summarize [] groups >>= function
    | Error error -> Lwt.return (Error error)
    | Ok [summary] -> Lwt.return (Ok summary)
    | Ok drafts ->
        let ids=List.concat_map (fun (draft:Llm.summary) ->
          List.concat_map (fun (bullet:Llm.bullet) -> bullet.sources) draft.bullets) drafts in
        let evidence=List.filter (fun (m:message) -> List.mem m.seq ids) messages in
        Llm.summarize llm ~intent ?request ~messages:evidence ~drafts ()

let help = "카톡에서 봇 계정을 멘션하고 자연스럽게 물어보세요.\n예: 오늘 중요한 얘기 뭐 있었어? / DB 얘기 결론 뭐야?\n특정 메시지부터 보려면 그 메시지에 답장하면서 봇을 멘션해주세요."

let render ~max_bytes ~range ~intent ~messages ~notes (summary:Llm.summary) =
  let start = match range.lower, messages with
    | At_time at, _ -> at
    | _, first::_ -> first.created_at
    | _, [] -> range.through_time in
  let subject=match intent.topic with None->"" | Some topic->" · " ^ Utf8.take 128 (Trigger.normalize topic) in
  let header=Printf.sprintf "%s~%s · 확인된 대화 %d개%s"
    (Scope.seoul_time start) (Scope.seoul_time range.through_time) (List.length messages) subject in
  let conclusion=match summary.conclusion with
    | Llm.Agreed->"\n결론: 합의된 내용이 있어요."
    | Llm.Disputed->"\n결론: 의견이 갈려 있어요."
    | Llm.Undecided->"\n결론: 확인한 대화에서는 아직 결정되지 않았어요."
    | Llm.Not_requested->"" in
  let notes=List.filter ((<>) "") notes |> List.sort_uniq String.compare |> String.concat "\n" in
  let fixed=String.length header+String.length conclusion+String.length notes+16 in
  let per_bullet=max 40 ((max_bytes-fixed)/max 1 (List.length summary.bullets)-96) in
  let bullets=List.map (fun (bullet:Llm.bullet) ->
    let evidence=List.filter (fun (m:message) -> List.mem m.seq bullet.sources) messages in
    let times=List.map (fun (m:message) -> m.created_at) evidence |> List.sort Float.compare in
    let citation=match times with
      | []->""
      | first::rest ->
          let last=List.fold_left (fun _ value->value) first rest in
          if first=last then " (" ^ Scope.seoul_time first ^ ")"
          else " (" ^ Scope.seoul_time first ^ "~" ^ Scope.seoul_time last ^ ")" in
    let body=Trigger.normalize bullet.text in
    let body=if String.length body>per_bullet then Utf8.take (max 4 (per_bullet-3)) body ^ "…" else body in
    "• " ^ body ^ citation) summary.bullets |> String.concat "\n" in
  let body=header ^ "\n\n" ^ bullets ^ conclusion ^ (if notes="" then "" else "\n\n" ^ notes) in
  if String.length body<=max_bytes then body
  else Utf8.take (max_bytes-64) body ^ "\n(길이 제한으로 일부를 줄였어요.)"

let render_answer ~max_bytes ~messages (answer:Llm.answer) =
  let times=messages |> List.filter (fun (m:message)->List.mem m.seq answer.answer_sources)
    |> List.map (fun (m:message)->Scope.seoul_time m.created_at) |> List.sort_uniq String.compare in
  let evidence=if times=[] then "" else "\n(근거: " ^ String.concat ", " times ^ ")" in
  Utf8.take (max 1 (max_bytes-String.length evidence)) answer.answer_text ^ evidence
