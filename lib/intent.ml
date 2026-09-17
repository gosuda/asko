open Types

let validate intent =
  match intent.scope, intent.topic with
  | Last_minutes n, _ when n <= 0 || n > 10080 -> Error "minutes must be between 1 and 10080"
  | _, Some topic when String.trim topic = "" || String.length topic > 1024 -> Error "invalid topic"
  | _ -> Ok intent
