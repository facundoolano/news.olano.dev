import feed.{
  type Entry, type Feed, type FeedError, Feed, FileError, NotModified,
  RequestError, ResponseError,
}
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
  process.try_call(feed, GetEntries(_), 10_000) |> result.unwrap([])
}

type State {
  State(
    feed: Feed,
    entries: List(Entry),
    etag: Option(String),
    last_modified: Option(String),
  )
}

/// Custom init function to read the file cache if any or do an initial polling.
/// Done here so process init doesn't slow down the rest of the app init.
fn init(feed: Feed) {
  // if there's a previously cached file, parse it now and request later
  // otherwise schedule to request now (after initialization, with a random delay)
  let #(entries, interval) =
    simplifile.read(cache_dir() <> feed.name)
    |> result.replace_error(FileError)
    |> result.try(feed.parse)
    |> result.map(fn(entries) { #(entries, poll_interval_ms) })
    |> result.lazy_unwrap(or: fn() { #([], int.random(5000)) })

  let state = State(feed, entries, None, None)

  // by default the actor will handle messages sent through the subject returned by start_spec
  // here I want to send a message to the actor from within init, so I need a new subject and
  // a selector that picks up messages sent to it
  let subject = process.new_subject()
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
      let result = {
        use #(new_state, body) <- result.try(fetch(state))
        use entries <- result.try(feed.parse(body))
        Ok(State(..new_state, entries: entries))
      }

      let new_state = case result {
        Ok(new_state) -> {
          io.println("ok " <> state.feed.url)
          new_state
        }
        Error(NotModified) -> {
          io.println("not modified " <> state.feed.url)
          state
        }
        Error(error) -> {
          io.println(
            "ERROR polling " <> state.feed.url <> " " <> string.inspect(error),
          )
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
fn fetch(state: State) -> Result(#(State, String), FeedError) {
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

  use resp <- result.try(
    httpc.configure()
    |> httpc.follow_redirects(True)
    |> httpc.dispatch(req)
    |> result.replace_error(RequestError),
  )

  case resp.status {
    304 -> Error(NotModified)
    status if status >= 400 -> Error(ResponseError(status))
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
