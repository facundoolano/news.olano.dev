import birl
import birl/duration
import feed.{type Entry as FeedEntry}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/order
import gleam/otp/actor
import poller.{type Poller as Feed}

const table_key = "entry_table"

const rebuild_interval = 100_000

const max_table_size = 100

const cut_off_months = 4

pub type Message {
  Rebuild(Subject(Message))
}

type State {
  State(feeds: List(Feed))
}

type Entry {
  Entry(bucket: Int, entry: FeedEntry)
}

pub fn start(feeds: List(Feed)) {
  let state = State(feeds)
  let assert Ok(table) = actor.start(state, handle_message)
  table_put(table_key, [])
  process.send(table, Rebuild(table))
}

pub fn get() -> List(FeedEntry) {
  table_get(table_key) |> list.map(fn(e) { e.entry })
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
        Entry(int.min(e.bucket, stored.bucket), e.entry)
      }
      _ -> e
    }
    dict.insert(acc, e.entry.url, merged)
  })
  |> dict.values
  |> list.sort(by: entry_compare)
  |> list.take(max_table_size)
}

fn bucketed_entries(feed: Feed) -> List(Entry) {
  let entries =
    poller.entries(feed)
    |> list.filter(fn(e) {
      // exclude entries over a yer old, and do it before calculating bucket
      // so a later bloomer (?) doesn't take all the spots
      let delta = birl.difference(birl.now(), e.published)
      duration.blur_to(delta, duration.Month) < cut_off_months
    })

  let bucket = calc_bucket(entries)
  list.map(entries, fn(entry) { Entry(bucket, entry) })
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
