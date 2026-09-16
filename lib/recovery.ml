open Lwt.Infix
let room ~config ~store ~iris ?through room =
  if not (Config.allowed config room) then Lwt.return (Error (Net.Http_status 403)) else
  let now = Unix.gettimeofday () in
  let since = now -. float_of_int (config.Config.retention_days * 86400) in
  Iris.latest iris room >>= function
  | Error error -> Lwt.return (Error error)
  | Ok (latest, coverage_start) ->
      let upper = match through with None -> latest | Some upper -> min upper latest in
      let initial = Store.cursor store ~source:config.source_id ~room in
      let rec loop after =
        if after >= upper then Lwt.return (Ok ())
        else Iris.page iris ~room ~after ~through:upper ~since >>= function
          | Error error -> Lwt.return (Error error)
          | Ok [] ->
              Store.save_cursor store ~source:config.source_id ~room ~cursor:upper ~at:now ~coverage_start;
              Lwt.return (Ok ())
          | Ok rows ->
              let decoded = List.map (Iris_event.of_query_row ~source:config.source_id ~bot_id:config.bot_id) rows in
              if List.exists Result.is_error decoded then Lwt.return (Error Net.Invalid_json)
              else
                let messages = List.map Result.get_ok decoded in
                if List.exists (fun (m:Types.message) -> m.room_id <> room || m.seq <= after || m.seq > upper) messages
                then Lwt.return (Error Net.Invalid_json)
                else begin
                  (* Each message is committed before advancing the verified page cursor.
                     Replayed history never creates jobs; duplicate live callbacks still can. *)
                  List.iter (fun m -> ignore (Ingest.apply ~config ~store ~now ~live:false m)) messages;
                  let next = List.fold_left (fun acc (m:Types.message) -> max acc m.seq) after messages in
                  Store.save_cursor store ~source:config.source_id ~room ~cursor:next ~at:now ~coverage_start;
                  Lwt.pause () >>= fun () -> loop next
                end
      in
      loop initial >|= fun result ->
      (match result with
       | Ok () -> Store.save_cursor store ~source:config.source_id ~room ~cursor:upper ~at:now ~coverage_start
       | Error _ -> ());
      result
