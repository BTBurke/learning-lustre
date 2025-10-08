import gleam/dynamic/decode
import gleam/option
import gleam/time/calendar
import gleam/time/timestamp
import record.{type Record}
import sqlight.{type Connection}

/// Set up the Sqlite database to accept switch records
pub fn migrate(db: Connection) -> Result(Nil, sqlight.Error) {
  let sql =
    "CREATE TABLE IF NOT EXISTS records (
        id INTEGER PRIMARY KEY,
        path TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'success',
        ts TEXT NOT NULL DEFAULT current_timestamp,
        next TEXT,
        logs TEXT);"

  sqlight.exec(sql, db)
}

/// Returns the most recent record for each switch path defined in the database
pub fn get_latest_records(db: Connection) -> Result(List(Record), sqlight.Error) {
  let sql =
    "SELECT *
    FROM        records t
    JOIN        (
        SELECT      path,
                    MAX(ts) latest_record
        FROM        records
        GROUP BY    path
    )  t2
    ON          t.path = t2.path
    AND         t.ts = t2.latest_record
    ORDER BY    t.ts DESC;"

  sqlight.query(sql, on: db, with: [], expecting: record.db_decoder())
}

/// Inserts a single record in the database
pub fn insert_record(db: Connection, r: Record) -> Result(Nil, sqlight.Error) {
  let sql =
    "INSERT INTO records (path, status, ts, next, logs)
        VALUES (?, ?, ?, ? , ?);"

  case
    sqlight.query(
      sql,
      on: db,
      with: [
        r.path |> sqlight.text,
        r.status |> record.status_to_string |> sqlight.text,
        r.ts |> timestamp.to_rfc3339(calendar.utc_offset) |> sqlight.text,
        r.next
          |> option.map(fn(t) { timestamp.to_rfc3339(t, calendar.utc_offset) })
          |> sqlight.nullable(sqlight.text, _),
        r.logs |> sqlight.nullable(sqlight.text, _),
      ],
      expecting: decode.success(Nil),
    )
  {
    Error(e) -> Error(e)
    _ -> Ok(Nil)
  }
}
