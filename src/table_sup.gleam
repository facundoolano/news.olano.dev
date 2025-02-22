import feed.{type Feed}
import gleam/erlang/process
import gleam/list
import gleam/otp/static_supervisor as sup
import gleam/result
import poller
import table

/// Creates a supervision tree for the entry table and the feed pollers it will be populated from.
///
///  table_sup
///  ├── table_worker
///  └── poller_sup
///      ├── feed_poller_worker
///      ├── feed_poller_worker
///      └── ...
///
pub fn start(feeds: List(Feed)) -> Result(process.Pid, Nil) {
  let table_worker =
    sup.worker_child("table", fn() {
      table.start() |> process.subject_owner |> Ok
    })

  // the table sup is rest for one so if the table gets killed, we restart the poller sup
  // along with all children, so they register on the new table
  let table_sup = sup.new(sup.RestForOne) |> sup.add(table_worker)

  sup.add(table_sup, build_poller_sup(feeds))
  |> sup.start_link()
  |> result.replace_error(Nil)
}

fn build_poller_sup(feeds: List(Feed)) -> sup.ChildBuilder {
  use <- sup.supervisor_child("poller_sup")
  // One for one so a feed dying doesn't affect the rest
  let poller_sup = sup.new(sup.OneForOne)

  // for each feed on the input list, create a poller actor, register it to the table
  // convert it to a child worker, and add it to the poller supervisor
  let poller_sup = {
    use poller_sup, feed <- list.fold(feeds, poller_sup)
    let worker = {
      use <- sup.worker_child(feed.name)
      use poller <- result.map(poller.start(feed))
      table.register(feed.name, poller)
      process.subject_owner(poller)
    }

    sup.add(poller_sup, worker)
  }

  sup.start_link(poller_sup)
}
