import feed.{type Entry, type Feed, Feed}
import gleam/erlang
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile

const poll_interval_ms = 1_800_000

pub type Poller =
  Subject(Message)

pub type Message {
  PollFeed(Subject(Message))
  GetEntries(Subject(List(Entry)))
}

/// Create a poller actor that will periodically fetch entries from an RSS/Atom feed,
/// parse, and save them locally.
pub fn start(feed: Feed) -> Result(Poller, actor.StartError) {
  actor.start_spec(actor.Spec(
    init: fn() { init(feed) },
    loop: handle_message,
    init_timeout: 10_000,
  ))
}

pub fn entries(feed: Subject(Message)) -> List(Entry) {
  actor.call(feed, GetEntries(_), 10_000)
}

type State {
  State(
    feed: Feed,
    entries: List(Entry),
    etag: Option(String),
    last_modified: Option(String),
  )
}

fn init(feed: Feed) {
  // if there's a previously cached file, parse it now and request later
  // otherwise schedule to request now (after initialization, with a random delay)
  let #(entries, interval) =
    simplifile.read(cache_dir() <> feed.name)
    |> result.map_error(string.inspect)
    |> result.try(feed.parse)
    |> result.map(fn(entries) { #(entries, poll_interval_ms) })
    |> result.lazy_unwrap(or: fn() { #([], int.random(5000)) })

  let state = State(feed, entries, None, None)
  let subject = process.new_subject()
  // I don't really understand what this means
  let selector =
    process.new_selector() |> process.selecting(subject, fn(x) { x })

  process.send_after(subject, interval, PollFeed(subject))

  actor.Ready(state, selector)
}

fn handle_message(message: Message, state: State) {
  case message {
    GetEntries(client) -> {
      process.send(client, state.entries)
      actor.continue(state)
    }
    PollFeed(self) -> {
      let new_state = case fetch(state) {
        Ok(#(new_state, body)) ->
          case feed.parse(body) {
            Ok(entries) -> {
              io.println("OK " <> state.feed.url)
              State(..new_state, entries: entries)
            }
            Error(error) -> {
              io.println("ERROR parsing " <> state.feed.url <> " " <> error)
              state
            }
          }
        Error(error) -> {
          io.println("ERROR fetching " <> state.feed.url <> " " <> error)
          state
        }
      }

      process.send_after(self, poll_interval_ms, PollFeed(self))
      actor.continue(new_state)
    }
  }
}

/// Request the source feed url, honoring the etag/last-modified config from the server,
/// and saving the response to a local file cache for using on restarts
fn fetch(state: State) -> Result(#(State, String), String) {
  let assert Ok(req) = request.to(state.feed.url)
  let req = request.prepend_header(req, "accept", "application/xml")
  let req = case state.etag {
    Some(etag) -> request.prepend_header(req, "If-None-Match", etag)
    _ -> req
  }
  let req = case state.last_modified {
    Some(last_modified) ->
      request.prepend_header(req, "If-Modified-Since", last_modified)
    _ -> req
  }

  let maybe_resp =
    httpc.configure()
    |> httpc.follow_redirects(True)
    |> httpc.dispatch(req)
    |> result.map_error(string.inspect)

  use resp <- result.try(maybe_resp)

  case resp.status {
    status if status >= 400 -> Error("response error " <> int.to_string(status))
    _ -> {
      // cache contents for next time
      let path = cache_dir() <> state.feed.name
      let _ =
        result.try(simplifile.create_directory_all(cache_dir()), fn(_) {
          simplifile.write(path, resp.body)
        })

      let etag = option.from_result(response.get_header(resp, "ETag"))
      let last_modified =
        option.from_result(response.get_header(resp, "Last-Modified"))
      Ok(#(State(..state, etag: etag, last_modified: last_modified), resp.body))
    }
  }
}

fn cache_dir() -> String {
  let assert Ok(cachedir) = erlang.priv_directory("news")
  cachedir <> "/feedcache/"
}
