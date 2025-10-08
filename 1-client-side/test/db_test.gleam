import db
import gleam/list
import gleam/option.{None, Some}
import gleam/time/timestamp
import record.{Failure, Record, Success}
import sqlight

pub fn insert_records_test() {
  use conn <- sqlight.with_connection("file:test?mode=memory")

  assert Ok(Nil) == db.migrate(conn)

  let records = [
    Record(
      id: 0,
      path: "/test",
      status: Success,
      ts: timestamp.from_unix_seconds(0),
      next: None,
      logs: None,
    ),
  ]

  let out = records |> list.map(db.insert_record(conn, _))

  assert out == [Ok(Nil)]
}

pub fn get_latest_records_test() {
  use conn <- sqlight.with_connection("file:test?mode=memory")

  assert Ok(Nil) == db.migrate(conn)

  let records = [
    Record(
      id: 0,
      path: "/test",
      status: Success,
      ts: timestamp.from_unix_seconds(0),
      next: None,
      logs: None,
    ),
    Record(
      id: 0,
      path: "/test",
      status: Failure,
      ts: timestamp.from_unix_seconds(1),
      next: None,
      logs: None,
    ),
    Record(
      id: 0,
      path: "/test/a",
      status: Success,
      ts: timestamp.from_unix_seconds(2),
      next: None,
      logs: None,
    ),
  ]

  let out = records |> list.map(db.insert_record(conn, _))
  assert out |> list.length == 3

  let assert Ok(latest) = db.get_latest_records(conn)
  assert latest |> list.length == 2

  case latest {
    [r0, r1] -> {
      assert r0.path == "/test/a"
      assert r1.path == "/test"
      assert r1.status == Failure
      assert r1.ts == timestamp.from_unix_seconds(1)
    }
    _ -> panic
  }
}

pub fn overdue_test() {
  let rec =
    Record(
      id: 0,
      path: "/test",
      status: Success,
      ts: timestamp.from_unix_seconds(0),
      next: Some(timestamp.from_unix_seconds(1)),
      logs: None,
    )

  assert record.is_overdue(rec) == True

  let rec =
    Record(
      id: 0,
      path: "/test",
      status: Success,
      ts: timestamp.from_unix_seconds(0),
      next: None,
      logs: None,
    )

  assert record.is_overdue(rec) == False
}
