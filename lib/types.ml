type message = {
  source : string;
  seq : int64;
  native_id : string option;
  room_id : string;
  sender_id : string;
  sender_name : string;
  created_at : float;
  text : string;
  reply_to : string option;
  mentions : string list;
  is_bot : bool;
  deleted : bool;
}

(* Reply and Slash remain readable for older persisted jobs only. *)
type trigger = Mention | Reply | Slash
type invocation = { message : message; trigger : trigger; prompt : string }
type scope = Today | Since_previous | From_reply | Recent | Retained | Last_minutes of int
type focus = Overview | Highlights | Conclusions | Answer
type intent = { scope : scope; topic : string option; focus : focus }

type lower_bound = At_time of float | After_message of int64 | From_message of int64
type range = {
  source : string;
  room_id : string;
  lower : lower_bound;
  before_seq : int64;
  through_time : float;
  retention_start : float;
  note : string option;
}

let overview scope = { scope; topic = None; focus = Overview }
let trigger_name = function Mention -> "mention" | Reply -> "reply" | Slash -> "slash"
let focus_name = function Overview -> "overview" | Highlights -> "highlights" | Conclusions -> "conclusions" | Answer -> "answer"

let is_before (message : message) (request : message) =
  message.source = request.source && message.room_id = request.room_id
  && Int64.compare message.seq request.seq < 0
  && message.created_at <= request.created_at

let in_range (range : range) (message : message) =
  message.source = range.source && message.room_id = range.room_id
  && not message.deleted && not message.is_bot
  && message.created_at >= range.retention_start
  && message.created_at <= range.through_time
  && Int64.compare message.seq range.before_seq < 0
  && match range.lower with
     | At_time at -> message.created_at >= at
     | After_message seq -> Int64.compare message.seq seq > 0
     | From_message seq -> Int64.compare message.seq seq >= 0
