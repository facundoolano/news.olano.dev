import feed.{type Entry, type Feed}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

const table_key = "entry_table"

const rebuild_interval = 600_000

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
  todo
}

@external(erlang, "persistent_term", "put")
fn table_put(key: String, value: List(Entry)) -> ok

@external(erlang, "persistent_term", "put")
fn table_get(key: String) -> List(entry)
