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

pub type State {
  Source(url: String, entries: List(Int))
}

pub type Entry {
  Entry(title: String, url: String, publised: String)
}

pub fn start(url: String) -> Subject(State) {
  let init = fn() {
    let subject = process.new_subject()
    let state = Source(url, [1])
    process.send(subject, state)

    let selector =
      process.new_selector() |> process.selecting(subject, fn(x) { x })

    actor.Ready(subject, selector)
  }

  let loop = fn(state: State, subject) {
    io.println("received message! " <> state.url)
    let assert [head, ..] = state.entries
    let state = Source(..state, entries: [head + 1, ..state.entries])
    case send_request() {
      Ok(body) -> {
        io.debug(body)
        // FIXME
        Nil
      }
      Error(msg) -> io.println("request error " <> string.inspect(msg))
    }
    process.send_after(subject, 10_000, state)
    actor.continue(subject)
  }

  let assert Ok(source) =
    actor.start_spec(actor.Spec(init: init, loop: loop, init_timeout: 50))

  source
}

fn send_request() -> Result(List(Entry), httpc.HttpError) {
  let assert Ok(req) = request.to("https://olano.dev/feed.xml")
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
