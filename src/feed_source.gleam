import gleam/dict
import gleam/erlang/atom
import gleam/erlang/charlist
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/httpc
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

pub type ServerMessage {
  PollFeed
  GetEntries(client: Subject(List(Entry)))
}

pub type Feed {
  Feed(url: String, entries: List(Entry), server: Subject(ServerMessage))
}

pub type Entry {
  Entry(title: String, url: String, publised: String)
}

pub fn start(url: String) {
  // TODO consider extracting this init function
  let init = fn() {
    let server = process.new_subject()
    let state = Feed(url, [], server)
    process.send(server, PollFeed)

    let selector = process.new_selector()

    actor.Ready(state, selector)
  }

  // TODO consider extracting this server function
  let loop = fn(message: ServerMessage, state: Feed) {
    case message {
      GetEntries(client) -> {
        process.send(client, state.entries)
        actor.continue(state)
      }
      PollFeed -> {
        let state = case send_request(state.url) {
          Ok(entries) -> {
            Feed(..state, entries: entries)
          }
          Error(msg) -> {
            io.println("request error " <> string.inspect(msg))
            state
          }
        }
        process.send_after(state.server, 10_000, PollFeed)
        actor.continue(state)
      }
    }
  }

  let assert Ok(source) =
    actor.start_spec(actor.Spec(init: init, loop: loop, init_timeout: 50))

  source
}

pub fn entries(feed: Subject(ServerMessage)) -> List(Entry) {
  actor.call(feed, GetEntries, 500)
}

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

  let entries =
    list.fold(elements, [], fn(acc, entry) {
      case entry {
        #("entry", _, elements) -> {
          parse_atom_entry(elements)
          |> option.map(fn(entry) { [entry, ..acc] })
          |> option.unwrap(acc)
        }
        _ -> acc
      }
    })
    |> list.reverse
  Ok(entries)
}

fn parse_atom_entry(elements: List(#(_, _, _))) -> Option(Entry) {
  let values =
    list.fold(elements, dict.new(), fn(entry, element) {
      case element {
        #("title", _, [title]) ->
          dict.insert(entry, "title", charlist.to_string(title))
        #("published", _, [published]) ->
          dict.insert(entry, "published", charlist.to_string(published))
        #("link", link_attrs, _) -> {
          dict.from_list(link_attrs)
          |> dict.get("href")
          |> result.map(fn(url) {
            dict.insert(entry, "url", charlist.to_string(url))
          })
          |> result.unwrap(entry)
        }
        #(_, _, _) -> entry
      }
    })

  case
    dict.get(values, "title"),
    dict.get(values, "url"),
    dict.get(values, "published")
  {
    Ok(title), Ok(url), Ok(published) -> Some(Entry(title, url, published))
    _, _, _ -> None
  }
}

@external(erlang, "erlsom", "simple_form")
fn parse_xml(doc: String, options: List(a)) -> #(result, element, String)
