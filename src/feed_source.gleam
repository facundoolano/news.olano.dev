import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/otp/actor

pub type State {
  State(url: String, entries: List(String))
}

pub fn start(url: String) -> Subject(State) {
  let init = fn() {
    let subject = process.new_subject()
    let state = State(url, [])
    process.send(subject, state)

    let selector =
      process.new_selector() |> process.selecting(subject, fn(x) { x })

    actor.Ready(subject, selector)
  }

  let loop = fn(state: State, subject) {
    io.println("received message! " <> state.url)
    process.send_after(subject, 1000, state)
    actor.continue(subject)
  }

  let assert Ok(source) =
    actor.start_spec(actor.Spec(init: init, loop: loop, init_timeout: 50))

  source
}
