import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import wisp

/// Record of a tracked switch in the database
/// Contains the following fields:
///     path: Identifies the tracked process (e.g., /myproject/database/backup)
///     status: Success or Failure
///     ts: Timestamp when the record was sent (defaults to current time)
///     next: Timestamp when we expect the action to repeat (the deadman's switch)
///     logs: Output of the command
///
pub type Record {
  Record(
    id: Int,
    path: String,
    status: Status,
    ts: timestamp.Timestamp,
    next: Option(timestamp.Timestamp),
    logs: Option(String),
  )
}

/// Status is recorded only as success or failure in the database.  The implicit status `overdue` exists for
/// a deadman's switch when the current time exceeds the expected time recorded in `next`.
pub type Status {
  Success
  Failure
}

/// Status as a string
pub fn status_to_string(s: Status) -> String {
  case s {
    Success -> "success"
    Failure -> "failure"
  }
}

/// Status from a string, with leniency for forgetting the exact terminalogy for succcess failure. Failure
/// is defined as any string that contains "fail" in it (e.g., failed, failure, fail)
pub fn status_from_string(s: String) -> Status {
  case s |> string.lowercase |> string.contains("fail") {
    True -> Failure
    _ -> Success
  }
}

/// Decode a row from the database into a record
pub fn db_decoder() -> decode.Decoder(Record) {
  use id <- decode.field(0, decode.int)
  use path <- decode.field(1, decode.string)
  use status <- decode.field(
    2,
    decode.string
      |> decode.map(status_from_string),
  )
  use ts <- decode.field(
    3,
    decode.string
      |> decode.map(fn(s) {
        timestamp.parse_rfc3339(s)
        |> result.unwrap(timestamp.from_unix_seconds(0))
      }),
  )
  use next <- decode.field(
    4,
    decode.optional(decode.string)
      |> decode.map(fn(t) {
        case t {
          Some(t) -> timestamp.parse_rfc3339(t) |> option.from_result
          None -> None
        }
      }),
  )
  use logs <- decode.field(5, decode.optional(decode.string))
  decode.success(Record(id:, path:, status:, ts:, next:, logs:))
}

/// Is the current time past when we expected the next record for this path?
pub fn is_overdue(r: Record) -> Bool {
  use <- bool.guard(when: option.is_none(r.next), return: False)
  let now = timestamp.system_time()
  let assert Some(next) = r.next
  case timestamp.compare(now, next) {
    order.Gt | order.Eq -> True
    _ -> False
  }
}

/// Convert record to JSON
pub fn to_json(r: Record) -> json.Json {
  json.object([
    #("id", json.int(r.id)),
    #("path", json.string(r.path)),
    #("status", json.string(r.status |> status_to_string)),
    #("ts", json.string(r.ts |> timestamp.to_rfc3339(calendar.utc_offset))),
    #(
      "next",
      json.nullable(r.next, of: fn(t) {
        t |> timestamp.to_rfc3339(calendar.utc_offset) |> json.string
      }),
    ),
    #("logs", json.nullable(r.logs, of: json.string)),
  ])
}

/// parse a JSON string into a record
pub fn parse_json(j: String) -> Result(Record, json.DecodeError) {
  json.parse(j, using: json_decoder())
}

/// Decode record from JSON
fn json_decoder() -> decode.Decoder(Record) {
  use id <- decode.field("id", decode.int)
  use path <- decode.field("path", decode.string)
  use status <- decode.field(
    "status",
    decode.string
      |> decode.map(status_from_string),
  )
  use ts <- decode.field(
    "ts",
    decode.string
      |> decode.map(fn(s) {
        timestamp.parse_rfc3339(s)
        |> result.unwrap(timestamp.from_unix_seconds(0))
      }),
  )
  use next <- decode.field(
    "next",
    decode.optional(decode.string)
      |> decode.map(fn(t) {
        case t {
          Some(t) -> timestamp.parse_rfc3339(t) |> option.from_result
          None -> None
        }
      }),
  )
  use logs <- decode.field("logs", decode.optional(decode.string))
  decode.success(Record(id:, path:, status:, ts:, next:, logs:))
}

/// Add any additional informaion about the record from the query parameters.  This
/// checks for an explicit timestamp (default now), a deadman switch, and an explicit status.
///
/// For simplicity, the value of the deadman switch is expressed in a duration string of
/// hours, minutes, or seconds, and cannot be mixed.
///
/// ## Valid durations
///
/// ```
/// 9s (9 seconds)
/// 1m (1 minute)
/// 2h (2 hours)
/// ```
///
/// ## Invalid durations
///
/// ```
/// 1us (not a valid time unit)
/// 1d (use 24h instead)
/// 2m45s (only one unit allowed)
/// ```
///
/// ## Example
///
/// ```gleam
/// // curl https://server.com/record/a/b/c?ts=2025-12-15T00:00:00Z&status=fail&next=24h
///
/// Record(ts: 2025-12-15T00:00:00Z, status: Failure, next: )
/// ```
pub fn from_query(
  path: String,
  default_status: Status,
  req: wisp.Request,
) -> Record {
  let params = wisp.get_query(req)
  let ts =
    list.key_find(params, "ts")
    |> result.try(timestamp.parse_rfc3339)
    |> result.unwrap(timestamp.system_time())
  let next =
    list.key_find(params, "next")
    |> result.map(fn(d) { get_next_from_duration(ts, d) })
    |> option.from_result
    |> option.flatten
  let status =
    list.key_find(params, "status")
    |> result.map(status_from_string)
    |> result.unwrap(default_status)
  Record(id: 0, path:, ts:, next:, status:, logs: None)
}

/// Parse the duration and add it to the time of the record
fn get_next_from_duration(
  ts: timestamp.Timestamp,
  duration d: String,
) -> Option(timestamp.Timestamp) {
  use <- bool.guard(d == "", return: None)
  let assert Ok(unit) = d |> string.last
  let value = d |> string.drop_end(1)

  let new_time = fn(d) {
    value
    |> int.parse
    |> result.map(fn(t) { timestamp.add(ts, d(t)) })
    |> option.from_result
  }
  case unit {
    "s" -> new_time(duration.seconds)
    "m" -> new_time(duration.minutes)
    "h" -> new_time(duration.hours)
    _ -> None
  }
}
