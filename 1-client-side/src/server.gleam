import db
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import mist
import record
import sqlight
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub type Context {
  Context(db: sqlight.Connection)
}

pub fn main() {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)
  use conn <- sqlight.with_connection("file:test.db?mode=rwc")
  let ctx = Context(db: conn)
  let assert Ok(_) = db.migrate(conn)

  let assert Ok(_) =
    wisp_mist.handler(handle_routing(ctx), secret_key_base)
    |> mist.new
    |> mist.port(8000)
    |> mist.start
  process.sleep_forever()
}

pub fn handle_routing(ctx: Context) -> fn(Request) -> Response {
  fn(req: Request) -> Response {
    use <- wisp.log_request(req)
    use <- wisp.rescue_crashes

    case wisp.path_segments(req) {
      ["record", ..path] -> handle_record(path, req, ctx)
      ["api", "latest"] -> handle_latest(req, ctx)
      _ -> wisp.not_found()
    }
  }
}

// Inserts a single record in the DB
fn handle_record(path: List(String), r: Request, ctx: Context) -> Response {
  let path = "/" <> string.join(path, "/")
  let default_status = case r.method {
    http.Get -> record.Success
    _ -> record.Failure
  }
  let rec = record.from_query(path, default_status, r)
  let body = case r.method {
    http.Get -> None
    http.Post ->
      r
      |> wisp.read_body_bits
      |> result.try(bit_array.to_string)
      |> option.from_result
    _ -> None
  }
  case db.insert_record(ctx.db, record.Record(..rec, logs: body)) {
    Ok(Nil) -> wisp.ok()
    Error(e) -> wisp.bad_request("invalid record format: " <> string.inspect(e))
  }
}

/// Returns the latest record for each path as JSON.
fn handle_latest(_r: Request, ctx: Context) -> Response {
  let records = case db.get_latest_records(ctx.db) {
    Ok(recs) -> recs
    Error(e) -> {
      wisp.log_error(string.inspect(e))
      []
    }
  }
  wisp.json_response(
    records
      |> list.map(record.to_json)
      |> json.preprocessed_array
      |> json.to_string,
    200,
  )
}
