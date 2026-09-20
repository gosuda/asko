open Asko
open Lwt.Infix
let check name yes=if not yes then failwith name else Printf.printf "ok: %s\n%!" name
let field k j=Yojson.Safe.Util.member k j
let str k j=field k j |> Yojson.Safe.Util.to_string
let () =
  let events=ref [] in
  let output j=events:=j::!events in
  Lwt_main.run(Telemetry.with_trace ~output ~kind:"test" (fun ()->
    Telemetry.span "parent" (fun ()->
      Lwt.join(List.map (fun n->Telemetry.span ("child"^string_of_int n) (fun ()->
        Lwt_unix.sleep 0.001 >>= fun ()->Telemetry.emit "child_event" [];Lwt.return_unit)) [1;2]) >>= fun ()->
      Telemetry.result ~error:Fun.id "failed_result" (fun ()->Lwt.return(Error "synthetic")) >>= fun _->
      Lwt.catch (fun ()->Telemetry.span "cancelled" (fun ()->Lwt.fail Lwt.Canceled)) (fun _->Lwt.return_unit))));
  let ends=List.filter(fun j->str "event" j="span_end") !events in
  let parent=List.find(fun j->str "stage" j="parent") ends in
  check "concurrent spans retain the same parent" (List.for_all (fun name->
    let child=List.find(fun j->str "stage" j=name) ends in
    field "parent_span_id" child=field "span_id" parent) ["child1";"child2"]);
  check "trace ID propagated" (List.for_all(fun j->field "trace_id" j=field "trace_id" parent) !events);
  check "result errors counted" (List.exists(fun j->str "stage" j="failed_result" && str "status" j="error") ends);
  check "cancelled spans closed" (List.exists(fun j->str "stage" j="cancelled" && str "status" j="cancelled") ends);
  let usage=`Assoc(Telemetry.usage_fields (`Assoc ["usage",`Assoc ["cost",`Float 0.002;"total_tokens",`Int 12];
    "messages",`String "private text";"api_key",`String "secret"])) in
  check "reported cost preserved" (field "cost_usd" usage=`Float 0.002);
  check "unknown usage stays null" (field "prompt_tokens" usage=`Null);
  check "usage excludes response content and credentials" (field "messages" usage=`Null && field "api_key" usage=`Null);
  check "malformed usage safe" (List.assoc "cost_usd" (Telemetry.usage_fields `Null)=`Null);
  let dir=Filename.temp_file "asko-telemetry" "" in Sys.remove dir;Unix.mkdir dir 0o700;
  let path=Filename.concat dir "events.jsonl" in
  let write n=Telemetry.file_sink ~path ~max_bytes:200000 ~backups:2 (`Assoc["n",`Int n]) in
  let child=Unix.fork () in
  if child=0 then (for n=1 to 50 do write n done;Unix._exit 0);
  for n=51 to 100 do write n done;
  let _,status=Unix.waitpid [] child in check "child writer succeeds" (status=Unix.WEXITED 0);
  let ic=open_in path in let count=ref 0 in
  (try while true do ignore(Yojson.Safe.from_string(input_line ic));incr count done with End_of_file->close_in ic);
  check "concurrent writers preserve complete JSON lines" (!count=100);
  for n=1 to 8 do Telemetry.file_sink ~path ~max_bytes:30 ~backups:2 (`Assoc["n",`Int n]) done;
  check "rotation bounded" (Sys.file_exists(path^".2") && not(Sys.file_exists(path^".3")));
  check "logs private" ((Unix.stat path).Unix.st_perm land 0o777=0o600);
  Array.iter(fun name->Sys.remove(Filename.concat dir name)) (Sys.readdir dir);Unix.rmdir dir;
  Lwt_main.run(Telemetry.with_trace ~output:(fun _->failwith "sink failed") ~kind:"test"
    (fun ()->Telemetry.span "survives" (fun ()->Lwt.return_unit)));
  check "logging failure does not fail work" true
