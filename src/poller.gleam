import feed.{type Entry, type Feed, Feed}
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
import parser
import simplifile

const poll_interval_ms = 3_600_000

const cache_dir: String = "./feedcache/"

pub type Poller =
  Subject(Message)

pub type Message {
  PollFeed(Subject(Message))
  GetEntries(Subject(List(Entry)))
}

pub fn start(feed: Feed) -> Poller {
  let assert Ok(feed) =
    actor.start_spec(actor.Spec(
      init: fn() { init(feed) },
      loop: handle_message,
      init_timeout: 10_000,
    ))
  feed
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
    simplifile.read(cache_dir <> feed.name)
    // TODO cleanup errors
    |> result.replace_error(Nil)
    |> result.try(parser.parse)
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
      let state = case fetch(state) {
        Ok(#(state, body)) ->
          case parser.parse(body) {
            Ok(entries) -> {
              io.println("OK " <> state.feed.url)
              State(..state, entries: entries)
            }
            // TODO cleanup errors
            Error(error) -> {
              io.println(
                "ERROR parsing "
                <> state.feed.url
                <> " "
                <> string.inspect(error),
              )

              state
            }
          }
        // TODO cleanup errors
        Error(error) -> {
          io.println(
            "ERROR fetching " <> state.feed.url <> " " <> string.inspect(error),
          )
          state
        }
      }

      process.send_after(self, poll_interval_ms, PollFeed(self))
      actor.continue(state)
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
    // TODO cleanup errors
    |> result.map_error(fn(e) { "request error: " <> string.inspect(e) })

  use resp <- result.try(maybe_resp)

  case resp.status {
    status if status >= 400 -> {
      // TODO cleanup errors?
      Error("response error " <> int.to_string(status))
    }
    _ -> {
      // cache contents for next time
      let path = cache_dir <> state.feed.name
      let _ =
        result.try(simplifile.create_directory_all(cache_dir), fn(_) {
          simplifile.write(path, resp.body)
        })

      let etag = option.from_result(response.get_header(resp, "ETag"))
      let last_modified =
        option.from_result(response.get_header(resp, "Last-Modified"))
      Ok(#(State(..state, etag: etag, last_modified: last_modified), resp.body))
    }
  }
}
