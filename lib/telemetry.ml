external now : unit -> float = "asko_monotonic_seconds"
let ms seconds = `Float (Float.round(max 0. seconds *. 1000000.) /. 1000.)
let timestamp () = match Ptime.of_float_s(Unix.gettimeofday ()) with
  | Some t->Ptime.to_rfc3339 ~frac_s:3 t | None->""
let merge a b=List.filter(fun (key,_)->not(List.mem_assoc key b)) a @ b

(* Writes are append-only, bounded, and serialized across serve/replay/backfill
   processes. A logging failure must not turn a successful answer into a retry. *)
let rec mkdir path =
  if path<>"." && not(Sys.file_exists path) then (mkdir(Filename.dirname path);Unix.mkdir path 0o700)
let file_sink ~path ~max_bytes ~backups json =
  let line=Json_util.to_string json ^ "\n" in
  mkdir(Filename.dirname path);
  let lock=Unix.openfile (path^".lock") [Unix.O_CREAT;Unix.O_WRONLY;Unix.O_CLOEXEC] 0o600 in
  Fun.protect ~finally:(fun ()->Unix.close lock) (fun ()->
    Unix.fchmod lock 0o600;
    Unix.lockf lock Unix.F_LOCK 0;
    Fun.protect ~finally:(fun ()->Unix.lockf lock Unix.F_ULOCK 0) (fun ()->
      let size=try (Unix.stat path).Unix.st_size with Unix.Unix_error(Unix.ENOENT,_,_)->0 in
      if size>0 && size+String.length line>max_bytes then begin
        let last=path ^ "." ^ string_of_int backups in
        if Sys.file_exists last then Sys.remove last;
        for n=backups-1 downto 1 do
          let src=path ^ "." ^ string_of_int n in
          if Sys.file_exists src then Sys.rename src (path ^ "." ^ string_of_int(n+1))
        done;
        Sys.rename path (path ^ ".1")
      end;
      let fd=Unix.openfile path [Unix.O_CREAT;Unix.O_WRONLY;Unix.O_APPEND;Unix.O_CLOEXEC] 0o600 in
      Fun.protect ~finally:(fun ()->Unix.close fd) (fun ()->
        Unix.fchmod fd 0o600;
        let rec write offset = if offset<String.length line then
          let n=Unix.write_substring fd line offset (String.length line-offset) in
          if n=0 then failwith "telemetry write stalled" else write(offset+n) in
        write 0)))

let sink=ref (fun (_:Yojson.Safe.t)->())
let configure ~path ~max_bytes ~backups =
  sink:=(if path="" then (fun _->()) else file_sink ~path ~max_bytes ~backups)

type trace = { id : string; kind : string; fields : (string * Yojson.Safe.t) list;
  started : float; mutable next_span : int; output : Yojson.Safe.t -> unit }
type scope = { trace : trace; parent : string option }
let key : scope Lwt.key = Lwt.new_key ()
let serial=ref 0
let make_trace ?(fields=[]) ?output kind =
  incr serial;
  {id=Printf.sprintf "%d-%.0f-%d" (Unix.getpid ()) (Unix.gettimeofday ()*.1000000.) !serial;
   kind;fields;started=now ();next_span=0;output=Option.value ~default:!sink output}
let base scope = ["trace_id",`String scope.trace.id;"kind",`String scope.trace.kind] @ scope.trace.fields
let write scope event fields =
  let json=`Assoc(merge (merge ["schema_version",`Int 1;"event",`String event;
    "at",`String(timestamp ())] (base scope)) fields) in
  try scope.trace.output json with _->()
let emit event fields = match Lwt.get key with
  | Some scope->write scope event (merge ["span_id",Json_util.option (fun x->`String x) scope.parent] fields)
  | None->let scope={trace=make_trace "standalone";parent=None} in write scope event fields

let with_trace ?fields ?output ~kind f =
  let scope={trace=make_trace ?fields ?output kind;parent=None} in
  write scope "trace_start" [];
  Lwt.with_value key (Some scope) (fun ()->
    Lwt.try_bind f
      (fun value->write scope "trace_end" ["status",`String "ok";"duration_ms",ms(now()-.scope.trace.started)];Lwt.return value)
      (fun exn->write scope "trace_end" ["status",`String(if exn=Lwt.Canceled then "cancelled" else "error");
         "error_code",`String(Printexc.exn_slot_name exn);"duration_ms",ms(now()-.scope.trace.started)];Lwt.fail exn))
let ensure ?fields ~kind f = match Lwt.get key with
  | Some _->f () | None->with_trace ?fields ~kind f

let begin_span scope stage fields =
  scope.trace.next_span<-scope.trace.next_span+1;
  let id=string_of_int scope.trace.next_span and started=now () in
  let fields=merge ["span_id",`String id;"parent_span_id",Json_util.option (fun x->`String x) scope.parent;
    "stage",`String stage;"start_offset_ms",ms(started-.scope.trace.started)] fields in
  write scope "span_start" fields;
  {scope with parent=Some id},started,fields
let end_span scope started fields status extra =
  write scope "span_end" (merge (merge fields ["status",`String status;"duration_ms",ms(now()-.started)]) extra)
let span ?(fields=[]) ?(describe=(fun _->[])) stage f =
  ensure ~kind:"standalone" (fun ()->
    let scope,started,fields=begin_span (Option.get(Lwt.get key)) stage fields in
    Lwt.with_value key (Some scope) (fun ()->Lwt.try_bind f
      (fun value->end_span scope started fields "ok" (try describe value with _->[]);Lwt.return value)
      (fun exn->end_span scope started fields (if exn=Lwt.Canceled then "cancelled" else "error")
        ["error_code",`String(Printexc.exn_slot_name exn)];Lwt.fail exn)))
let result_fields error = function
  | Ok _->[] | Error e->["status",`String "error";"error_code",`String(error e)]
let result ?fields ~error stage f = span ?fields ~describe:(result_fields error) stage f
let sync ?(fields=[]) stage f = match Lwt.get key with
  | None->f ()
  | Some parent->
      let scope,started,fields=begin_span parent stage fields in
      Lwt.with_value key (Some scope) (fun ()->
        match f () with
        | value->end_span scope started fields "ok" [];value
        | exception exn->end_span scope started fields "error" ["error_code",`String(Printexc.exn_slot_name exn)];raise exn)

let number_field name json = match Json_util.protect(fun ()->
  Json_util.required name json |> Json_util.float) with
  | Ok n when n>=0.->`Float n | _->`Null
let label_field name json = match Json_util.protect(fun ()->Json_util.required name json |> Json_util.string) with
  | Ok s when String.length s<=160 && not(String.exists(fun c->Char.code c<32) s)->`String s
  | _->`Null
let object_field name json=match json with
  | `Assoc fields->(match List.assoc_opt name fields with Some(`Assoc _ as value)->value | _->`Assoc [])
  | _->`Assoc []
let usage_fields json =
  let usage=object_field "usage" json in
  let completion=object_field "completion_tokens_details" usage and prompt=object_field "prompt_tokens_details" usage in
  ["generation_id",label_field "id" json;"provider",label_field "provider" json;
   "response_model",label_field "model" json;
   "prompt_tokens",number_field "prompt_tokens" usage;
   "completion_tokens",number_field "completion_tokens" usage;
   "total_tokens",number_field "total_tokens" usage;
   "reasoning_tokens",number_field "reasoning_tokens" completion;
   "cached_tokens",number_field "cached_tokens" prompt;
   "cost_usd",number_field "cost" usage]
