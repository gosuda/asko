open Types
open Lwt.Infix

type chunk = { members : message list; content : string }
type selection = { messages : message list; note : string option }
let rec take n values = match n, values with 0,_ | _,[] -> [] | n,x::xs -> x :: take (n-1) xs
let chunk_content messages =
  messages |> List.map (fun (m:message) -> m.sender_name ^ ": " ^ m.text) |> String.concat "\n"

let chunks messages =
  let fragments = List.concat_map (fun (m:message) ->
    List.map (fun text -> {m with text}) (if m.text="" then [""] else Utf8.parts 1400 m.text)) messages in
  let emit members = {members; content=chunk_content members} in
  let rec loop current result = function
    | [] -> List.rev (if current=[] then result else emit current :: result)
    | message :: rest ->
        let candidate = current @ [message] in
        if current<>[] && (Int64.div (List.hd current).seq 32L <> Int64.div message.seq 32L ||
           List.length candidate>32 || String.length (chunk_content candidate)>2000) then
          let overlap = if Int64.div (List.hd current).seq 32L <> Int64.div message.seq 32L
            then [] else current |> List.rev |> take 2 |> List.rev in
          let next = if String.length (chunk_content (overlap @ [message]))<=2000 then overlap @ [message] else [message] in
          loop next (emit current :: result) rest
        else loop candidate result rest
  in loop [] [] fragments

let cosine a b =
  if Array.length a <> Array.length b || Array.length a=0 then None else
  let dot=ref 0. and aa=ref 0. and bb=ref 0. in
  for index=0 to Array.length a-1 do
    dot:= !dot +. a.(index)*.b.(index); aa:= !aa +. a.(index)*.a.(index); bb:= !bb +. b.(index)*.b.(index)
  done;
  if !aa<=0. || !bb<=0. then None else
  let value= !dot /. sqrt (!aa *. !bb) in
  if Float.is_finite value then Some (max (-1.) (min 1. value)) else None

let contains haystack needle =
  needle<>"" && try ignore (Str.search_forward (Str.regexp_string needle) haystack 0); true with Not_found -> false
let lexical topic content =
  let topic=String.lowercase_ascii topic and content=String.lowercase_ascii content in
  let tokens=String.split_on_char ' ' topic |> List.filter (fun x -> String.length x>=2) in
  let tokens=if List.exists (fun x -> List.mem x ["postgres";"postgresql";"포스트그레스"]) tokens
    then List.sort_uniq String.compare ("postgres"::"postgresql"::"포스트그레스"::tokens) else tokens in
  if contains content topic then 1.
  else if List.exists (contains content) tokens then 0.6 else 0.

let expand messages selected =
  let all=Array.of_list messages in
  let picked=Hashtbl.create 64 in
  List.iter (fun (m:message) -> Hashtbl.replace picked m.seq ()) selected;
  let seeds=Hashtbl.copy picked in
  Array.iteri (fun index (m:message) ->
    if Hashtbl.mem seeds m.seq then
      for n=max 0 (index-2) to min (Array.length all-1) (index+2) do Hashtbl.replace picked all.(n).seq () done) all;
  for _=1 to 2 do
    let native=Hashtbl.create 64 and parents=Hashtbl.create 64 in
    Array.iter (fun (m:message) -> if Hashtbl.mem picked m.seq then begin
      Option.iter (fun id -> Hashtbl.replace native id ()) m.native_id;
      Option.iter (fun id -> Hashtbl.replace parents id ()) m.reply_to
    end) all;
    Array.iter (fun (m:message) ->
      if (match m.native_id with Some id -> Hashtbl.mem parents id | None -> false)
         || (match m.reply_to with Some id -> Hashtbl.mem native id | None -> false)
      then Hashtbl.replace picked m.seq ()) all
  done;
  List.filter (fun (m:message) -> Hashtbl.mem picked m.seq) messages

let cache_key chunk = "v2:" ^ Digest.to_hex (Digest.string (
  String.concat "," (List.map (fun (m:message)->Int64.to_string m.seq) chunk.members) ^ "\000" ^ chunk.content))

let valid_vector expected vector =
  Array.length vector>0 && (match expected with None->true | Some n->Array.length vector=n)
  && Array.for_all Float.is_finite vector && Array.exists (fun x->x<>0.) vector

let expected_dimensions config =
  if not(Config.local_embeddings config) && config.Config.embedding_model="google/gemini-embedding-001"
  then Some 3072 else None

let index ?(progress=(fun _ _->())) ~config ~store ~llm ~range ~version messages =
  let messages=List.filter (in_range range) messages in
  let originals=Hashtbl.create (List.length messages) in
  List.iter(fun (m:message)->Hashtbl.replace originals m.seq m) messages;
  let snapshot chunk=List.map (fun (m:message)->m.seq) chunk.members |> List.sort_uniq Int64.compare
    |> List.filter_map (Hashtbl.find_opt originals) in
  let values=Array.of_list(chunks messages) in
  let vectors=Array.map (fun chunk->
    match Store.get_embedding store ~source:range.source ~room:range.room_id ~key:(cache_key chunk)
      ~model:config.Config.embedding_model ~content:chunk.content with
    | Some vector when valid_vector (expected_dimensions config) vector->Some vector
    | _->None) values in
  let missing=Array.to_list(Array.mapi(fun i v->if v=None then Some i else None) vectors) |> List.filter_map Fun.id in
  let total=Array.length values in
  progress (total-List.length missing) total;
  let rec fill pending = match pending with
    | []->Lwt.return(Ok(values,vectors))
    | _->
        let batch=take (if Config.local_embeddings config then 1 else 16) pending in
        let rest=List.filter (fun i->not(List.mem i batch)) pending in
        Llm.embed llm (List.map(fun i->values.(i).content) batch) >>= function
        | Error error->Lwt.return(Error error)
        | Ok embedded when List.length embedded<>List.length batch ||
            not(List.for_all (valid_vector (expected_dimensions config)) embedded)->
            Lwt.return(Error(Llm.Bad_response {stage="retrieval";reason="invalid document embedding count or dimensions"}))
        | Ok embedded->
            (try
              List.iter2(fun i vector->
                let chunk=values.(i) in
                Store.put_embedding ~snapshot:(snapshot chunk) store ~source:range.source ~room:range.room_id
                  ~key:(cache_key chunk) ~model:config.embedding_model ~content:chunk.content
                  ~at:(Unix.gettimeofday ()) ~version vector;
                vectors.(i)<-Some vector) batch embedded;
              progress (total-List.length rest) total;
              Lwt.pause () >>= fun ()->fill rest
             with Store.Stale_snapshot->Lwt.return(Error Llm.Source_changed)) in
  fill missing

let select ?corpus ~config ~store ~llm ~range ~version ~topic ~focus messages =
  let messages=List.filter (in_range range) messages in
  let corpus=Option.value ~default:messages corpus in
  (* Index stable room windows once. Time/speaker filters restrict returned originals,
     rather than rebuilding every chunk for every different query range. *)
  let corpus_range={range with lower=At_time range.retention_start;
    through_time=List.fold_left(fun at (m:message)->max at m.created_at) range.through_time messages} in
  let corpus=List.filter (in_range corpus_range) corpus in
  let permitted=Hashtbl.create(List.length messages) in
  List.iter(fun (m:message)->Hashtbl.replace permitted m.seq ()) messages;
  let selected_members chunk=List.filter(fun (m:message)->Hashtbl.mem permitted m.seq) chunk.members in
  let candidates=chunks corpus |> List.filter(fun chunk->selected_members chunk<>[]) in
  let lexical_fallback error =
    let hits=candidates |> List.map(fun c->lexical topic (chunk_content(selected_members c)),c)
      |> List.filter(fun (s,_)->s>0.) |> List.sort(fun (a,_) (b,_)->Float.compare b a) |> take 12 in
    if hits=[] then Error error else Ok {messages=expand messages (List.concat_map(fun (_,c)->selected_members c) hits);
      note=Some "의미 검색을 사용할 수 없어 키워드가 일치한 발췌만 확인했습니다. 전체 조사 결과가 아닙니다."} in
  if messages=[] then Lwt.return(Ok {messages=[];note=None}) else
  let query=topic ^ (if focus=Conclusions then " 최종 결론 합의 정정" else "") in
  Llm.embed llm ~query:true [query] >>= function
  | Error error->Lwt.return(lexical_fallback error)
  | Ok [query_vector] when valid_vector (expected_dimensions config) query_vector->
      index ~config ~store ~llm ~range:corpus_range ~version corpus >|= (function
      | Error error->lexical_fallback error
      | Ok(values,vectors)->
          let scored=Array.to_list(Array.mapi(fun i chunk->
            let eligible=selected_members chunk in
            let semantic=Option.bind vectors.(i) (cosine query_vector) |> Option.value ~default:(-1.) in
            let exact=lexical topic (chunk_content eligible) in
            eligible,semantic,exact,0.8*.semantic+.0.2*.exact) values) in
          let hits=scored |> List.filter(fun (members,semantic,exact,_)->members<>[] && (semantic>=0.25 || exact>0.))
            |> List.sort(fun (_,_,_,a) (_,_,_,b)->Float.compare b a) |> take 12 in
          Ok {messages=expand messages (List.concat_map(fun (members,_,_,_)->members) hits);note=None})
  | Ok _->Lwt.return(Error(Llm.Bad_response {stage="retrieval";reason="invalid query embedding"}))
