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

const rebuild_interval = 600_000

const entries_cutoff_days = 4

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

fn latest_entries(feeds: List(Feed)) -> List(Entry) {
  list.flat_map(feeds, bucketed_entries)
  |> list.fold_right(dict.new(), fn(acc, e) {
    // index by url to remove duplicates
    // and keep only the last N days of entries
    let delta = birl.difference(birl.now(), { e.entry }.published)
    case duration.blur_to(delta, duration.Day) <= entries_cutoff_days {
      True -> dict.insert(acc, { e.entry }.url, e)
      False -> acc
    }
  })
  |> dict.values
  |> list.sort(by: entry_compare)
}

fn bucketed_entries(feed: Feed) -> List(Entry) {
  let entries = poller.entries(feed)
  let bucket = calc_bucket(entries)
  list.map(entries, fn(entry) { Entry(bucket, entry, birl.monotonic_now()) })
}

/// Compare entries by frequency bucket and published date (less frequent and newest come first)
fn entry_compare(e1: Entry, e2: Entry) -> order.Order {
  case int.compare(e1.bucket, e2.bucket) {
    order.Eq -> birl.compare({ e2.entry }.published, { e1.entry }.published)
    // swap to get newer first
    result -> result
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
