import birl
import gleam/dict
import gleam/erlang/atom
import gleam/erlang/charlist
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/httpc
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string

pub type Message {
  PollFeed(Subject(Message))
  GetEntries(Subject(List(Entry)))
}

pub type Entry {
  Entry(title: String, url: String, published: birl.Time)
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
  actor.call(feed, GetEntries(_), 10_000)
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
  Ok(Entry(title, url, datetime))
}

@external(erlang, "erlsom", "simple_form")
fn parse_xml(doc: String, options: List(a)) -> #(result, element, String)
