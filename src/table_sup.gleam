import feed.{type Feed}
import gleam/erlang/process
import gleam/list
import gleam/otp/static_supervisor as sup
import gleam/result
import poller
import table

pub fn start(feeds: List(Feed)) -> Result(process.Pid, Nil) {
  let table = table.start()

  let poller_sup = sup.new(sup.OneForOne)
  list.fold(feeds, poller_sup, fn(sup, feed) {
    let worker =
      sup.worker_child(feed.name, fn() {
        result.map(poller.start(feed), fn(poller) {
          table.register(table, feed.name, poller)
          process.subject_owner(poller)
        })
      })
    sup.add(sup, worker)
  })
  |> sup.start_link()
  |> result.replace_error(Nil)
}
