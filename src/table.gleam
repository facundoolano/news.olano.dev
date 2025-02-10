import birl
import birl/duration
import feed.{type Entry as FeedEntry}
import gleam/dict
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import poller.{type Poller as Feed}

const table_key = "entry_table"

const rebuild_interval = 100_000

const max_table_size = 1000

const page_size = 30

pub type Message {
  Rebuild(Subject(Message))
}

type State {
  State(feeds: List(Feed))
}

type Entry {
  Entry(bucket: Int, entry: FeedEntry, created_at: Int)
}

pub fn start(feeds: List(Feed)) {
  let state = State(feeds)
  let assert Ok(table) = actor.start(state, handle_message)
  table_put(table_key, [])
  process.send(table, Rebuild(table))
}

// TODO
pub fn get() -> List(FeedEntry) {
  table_get(table_key) |> list.map(fn(e) { e.entry }) |> list.take(page_size)
}

// TODO unit test this
pub fn filter(
  from: Option(String),
  to: Option(String),
) -> #(List(FeedEntry), Option(String), Option(String)) {
  let entries =
    table_get(table_key)
    |> list.filter(fn(entry) {
      case from, to {
        Some(""), Some(_) | Some(_), Some("") -> True
        Some(from), Some(to) -> {
          let assert Ok(from) = int.parse(from)
          let assert Ok(to) = int.parse(to)
          entry.created_at > from || entry.created_at < to
        }
        _, _ -> True
      }
    })
    |> list.take(page_size)

  let #(new_from, new_to) = case list.first(entries), list.last(entries) {
    Ok(first), Ok(last) -> {
      let new_from = first.created_at
      let new_to = last.created_at
      merge_ranges(from, to, new_from, new_to)
    }
    _, _ -> #(None, None)
  }

  let entries = list.map(entries, fn(e) { e.entry })

  #(entries, new_from, new_to)
}

// FIXME I'm sure there are bugs here but YOLO
fn merge_ranges(
  old_from: Option(String),
  old_to: Option(String),
  new_from: Int,
  new_to: Int,
) -> #(Option(String), Option(String)) {
  case old_from, old_to {
    Some(""), Some(_) | Some(_), Some("") | None, _ | _, None -> #(
      Some(int.to_string(new_from)),
      Some(int.to_string(new_to)),
    )
    Some(old_from_str), Some(old_to_str) -> {
      let assert Ok(old_from) = int.parse(old_from_str)
      let assert Ok(old_to) = int.parse(old_to_str)

      // TODO explain
      let #(new_from, new_to) = case
        new_to >= old_from && new_to - old_from < 100_000
      {
        True -> #(new_from, old_to)
        False -> #(new_from, new_to)
      }
      #(Some(int.to_string(new_from)), Some(int.to_string(new_to)))
    }
  }
}

fn handle_message(message: Message, state: State) {
  let state = case message {
    Rebuild(self) -> {
      let entries = latest_entries(state.feeds)
      table_put(table_key, entries)
      io.println("refreshed table")

      process.send_after(self, rebuild_interval, Rebuild(self))
      state
    }
  }
  actor.continue(state)
}

/// TODO explain
fn latest_entries(feeds: List(Feed)) -> List(Entry) {
  list.flat_map(feeds, bucketed_entries)
  |> list.append(table_get(table_key))
  |> list.fold(dict.new(), fn(acc: dict.Dict(String, Entry), e) {
    // index by url to remove duplicates, preserving the earliest created at and the lower bucket
    let merged = case dict.get(acc, e.entry.url) {
      Ok(stored) -> {
        Entry(
          int.min(e.bucket, stored.bucket),
          e.entry,
          int.max(e.created_at, stored.created_at),
        )
      }
      _ -> e
    }
    dict.insert(acc, e.entry.url, merged)
  })
  |> dict.values
  |> list.sort(by: entry_compare)
  |> list.fold_right([], fn(acc, e) {
    case e.created_at {
      0 -> [Entry(..e, created_at: monotonic_int()), ..acc]
      _ -> [e, ..acc]
    }
  })
  |> list.take(max_table_size)
}

fn bucketed_entries(feed: Feed) -> List(Entry) {
  let entries =
    poller.entries(feed)
    |> list.filter(fn(e) {
      // exclude entries over a yer old, and do it before calculating bucket
      // so a later bloomer (?) doesn't take all the spots
      let delta = birl.difference(birl.now(), e.published)
      duration.blur_to(delta, duration.Month) < 12
    })

  let bucket = calc_bucket(entries)
  // FIXME this zero business is funky
  list.map(entries, fn(entry) { Entry(bucket, entry, 0) })
}

/// Compare entries by frequency bucket and published date (less frequent and newest come first)
fn entry_compare(e1: Entry, e2: Entry) -> order.Order {
  let delta1 =
    duration.blur_to(
      birl.difference(birl.now(), e1.entry.published),
      duration.Hour,
    )

  let delta2 =
    duration.blur_to(
      birl.difference(birl.now(), e2.entry.published),
      duration.Hour,
    )

  // we want anything in the last 48 hs first, than anything else we have available
  // within those two groups, distribute between the frequency buckets
  // showing most recent first within the bucket
  case delta1 < 48, delta2 < 48 {
    True, True | False, False -> {
      case int.compare(e1.bucket, e2.bucket) {
        order.Eq -> birl.compare({ e2.entry }.published, { e1.entry }.published)
        // swap to get newer first
        result -> result
      }
    }
    True, False -> order.Lt
    False, True -> order.Gt
  }
}

// TODO unit test this
fn calc_bucket(entries: List(FeedEntry)) -> Int {
  let by_date =
    list.sort(entries, by: fn(e1, e2) {
      birl.compare(e1.published, e2.published)
    })

  case list.first(by_date), list.last(by_date) {
    Ok(first), Ok(last) -> {
      let delta = birl.difference(last.published, first.published)
      let days = int.max(1, duration.blur_to(delta, duration.Day))
      let posts_per_day =
        int.to_float(list.length(entries)) /. int.to_float(days)

      case posts_per_day {
        // once a month or less
        n if n <=. 1.0 /. 30.0 -> 0
        // once week or less
        n if n <=. 1.0 /. 7.0 -> 1
        // once a day or less
        n if n <=. 1.0 /. 1.0 -> 2
        // 5 times a day or less
        n if n <=. 1.0 /. 5.0 -> 3
        // 20 times a day or less
        n if n <=. 1.0 /. 20.0 -> 4
        // more
        _ -> 5
      }
    }
    _, _ -> 0
  }
}

@external(erlang, "persistent_term", "put")
fn table_put(key: String, value: List(Entry)) -> ok

@external(erlang, "persistent_term", "get")
fn table_get(key: String) -> List(Entry)

@external(erlang, "erlang", "system_time")
fn erlang_system_time(unit: atom.Atom) -> Int

fn monotonic_int() -> Int {
  // FIXME this is not really monotonic but well
  erlang_system_time(atom.create_from_string("microsecond"))
}
