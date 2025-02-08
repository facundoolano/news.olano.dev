import birl
import birl/duration
import feed.{type Entry, type Feed}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor

const table_key = "entry_table"

const rebuild_interval = 600_000

const entries_cutoff_days = 4

pub type Message {
  Rebuild(Subject(Message))
}

type State {
  State(feeds: List(Feed))
}

pub fn start(feeds: List(Feed)) {
  let state = State(feeds)
  let assert Ok(table) = actor.start(state, handle_message)
  table_put(table_key, [])
  process.send(table, Rebuild(table))
}

pub fn get() -> List(Entry) {
  table_get(table_key)
}

fn handle_message(message: Message, state: State) {
  let state = case message {
    Rebuild(self) -> {
      let entries = latest_entries(state.feeds)
      table_put(table_key, entries)

      process.send_after(self, rebuild_interval, Rebuild(self))
      state
    }
  }
  actor.continue(state)
}

fn latest_entries(feeds: List(Feed)) -> List(Entry) {
  list.flat_map(feeds, feed.entries)
  // index by url to remove duplicates
  // and keep only the last 48hs of entries
  |> list.fold_right(dict.new(), fn(acc, e) {
    let delta = birl.difference(birl.now(), e.published)
    case duration.blur_to(delta, duration.Day) <= entries_cutoff_days {
      True -> dict.insert(acc, e.url, e)
      False -> acc
    }
  })
  |> dict.values
  |> list.sort(by: feed.entry_compare)
}

@external(erlang, "persistent_term", "put")
fn table_put(key: String, value: List(Entry)) -> ok

@external(erlang, "persistent_term", "get")
fn table_get(key: String) -> List(entry)
