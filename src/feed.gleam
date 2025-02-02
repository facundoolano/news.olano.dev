import birl
import birl/duration
import gleam/dict
import gleam/erlang/atom
import gleam/erlang/charlist
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/string

pub type Message {
  PollFeed(Subject(Message))
  GetEntries(Subject(List(Entry)))
}

// TODO consider moving to its own mod
// TODO the bucket is more of an attr of the the feed, although it's more convenient to
// set it in the entry for later access / ordering, may need to revisit this
pub type Entry {
  Entry(title: String, url: String, published: birl.Time, freq_bucket: Int)
}

type State {
  State(url: String, entries: List(Entry))
}

pub fn start(url: String) -> Subject(Message) {
  let assert Ok(source) =
    actor.start_spec(actor.Spec(
      init: fn() { init(url) },
      loop: handle_message,
      init_timeout: 50,
    ))
  source
}

pub fn entries(feed: Subject(Message)) -> List(Entry) {
  let entries = actor.call(feed, GetEntries(_), 10_000)
  let bucket = calc_bucket(entries)
  list.map(entries, fn(e) { Entry(..e, freq_bucket: bucket) })
}

/// Compare entries by frequency bucket and published date
/// (less frequent and newest come first)
pub fn entry_compare(e1: Entry, e2: Entry) -> order.Order {
  case int.compare(e1.freq_bucket, e2.freq_bucket) {
    order.Eq -> birl.compare(e2.published, e1.published)
    // swap to get newer first
    result -> result
  }
}

pub fn entry_format(entry: Entry) {
  entry.title
  <> "("
  <> entry.url
  <> ")\n"
  <> birl.legible_difference(birl.now(), entry.published)
  <> "\n"
}

// TODO unit test this
fn calc_bucket(entries: List(Entry)) -> Int {
  let by_date =
    list.sort(entries, by: fn(e1, e2) {
      birl.compare(e2.published, e1.published)
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

fn init(url: String) {
  let subject = process.new_subject()
  let state = State(url, [])
  process.send(subject, PollFeed(subject))

  // I don't really understand what this means
  let selector =
    process.new_selector() |> process.selecting(subject, fn(x) { x })

  actor.Ready(state, selector)
}

fn handle_message(message: Message, state: State) {
  case message {
    GetEntries(client) -> {
      process.send(client, state.entries)
      actor.continue(state)
    }
    PollFeed(self) -> {
      io.println("polling server")
      let state = case send_request(state.url) {
        Ok(entries) -> {
          State(..state, entries: entries)
        }
        Error(msg) -> {
          io.println("request error " <> string.inspect(msg))
          state
        }
      }
      process.send_after(self, 30_000, PollFeed(self))
      actor.continue(state)
    }
  }
}

// TODO separate http from atom from domain specific Entry
// TODO add rss support
fn send_request(url: String) -> Result(List(Entry), httpc.HttpError) {
  let assert Ok(req) = request.to(url)
  use resp <- result.try(httpc.send(req))
  // TODO accept xml
  // TODO fail if error status

  let #(_ok, root, _tail) =
    parse_xml(resp.body, [
      #(atom.create_from_string("nameFun"), fn(name, _, _) {
        charlist.to_string(name)
      }),
    ])
  let #(_, _, elements) = root

  list.fold(elements, [], fn(acc, entry) {
    case entry {
      #("entry", _, elements) -> {
        parse_atom_entry(elements)
        |> result.map(fn(entry) { [entry, ..acc] })
        |> result.unwrap(acc)
      }
      _ -> acc
    }
  })
  |> list.reverse
  |> Ok
}

fn parse_atom_entry(elements: List(#(_, _, _))) -> Result(Entry, Nil) {
  let values =
    list.fold(elements, dict.new(), fn(entry, element) {
      case element {
        #("title", _, [title]) ->
          dict.insert(entry, "title", charlist.to_string(title))
        #("published", _, [published]) -> {
          dict.insert(entry, "published", charlist.to_string(published))
        }
        #("link", link_attrs, _) -> {
          dict.from_list(link_attrs)
          |> dict.get("href")
          |> result.map(charlist.to_string)
          |> result.map(fn(url) { dict.insert(entry, "url", url) })
          |> result.unwrap(entry)
        }
        #(_, _, _) -> entry
      }
    })

  use title <- result.try(dict.get(values, "title"))
  use url <- result.try(dict.get(values, "url"))
  use published <- result.try(dict.get(values, "published"))
  use datetime <- result.try(birl.parse(published))
  Ok(Entry(title, url, datetime, 0))
}

@external(erlang, "erlsom", "simple_form")
fn parse_xml(doc: String, options: List(a)) -> #(result, element, String)
