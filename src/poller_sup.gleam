import feed.{type Feed}
import gleam/erlang/process
import gleam/list
import gleam/otp/static_supervisor as sup
import gleam/result
import poller

pub fn start(feeds: List(Feed)) {
  let sup = sup.new(sup.OneForOne)
  list.fold(feeds, sup, fn(sup, feed) {
    let worker =
      sup.worker_child(feed.name, fn() {
        result.map(poller.start(feed), process.subject_owner)
      })
    sup.add(sup, worker)
  })
  |> sup.start_link()
}
