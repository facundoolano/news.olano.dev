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

pub type State {
  State(url: String, entries: List(Int))
}

pub fn start(url: String) -> Subject(State) {
  let init = fn() {
    let subject = process.new_subject()
    let state = State(url, [1])
    process.send(subject, state)

    let selector =
      process.new_selector() |> process.selecting(subject, fn(x) { x })

    actor.Ready(subject, selector)
  }

  let loop = fn(state: State, subject) {
    io.println("received message! " <> state.url)
    let assert [head, ..] = state.entries
    let state = State(..state, entries: [head + 1, ..state.entries])
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

fn send_request() -> Result(List(String), httpc.HttpError) {
  let assert Ok(req) = request.to("https://olano.dev/feed.xml")
  use resp <- result.try(httpc.send(req))
  // TODO accept xml
  // TODO fail if error status
  let #(_ok, root, _tail) =
    parse_xml(resp.body, [
      #(atom.create_from_string("nameFun"), fn(name, _, _) { name }),
    ])
  let #(_, _, elements) = root

  let entries =
    list.filter(elements, fn(e) {
      let #(tag, _, _) = e
      charlist.to_string(tag) == "entry"
    })
  Ok(["ok"])
}

@external(erlang, "erlsom", "simple_form")
fn parse_xml(doc: String, options: List(a)) -> #(result, element, String)
