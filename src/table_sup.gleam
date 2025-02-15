import feed.{type Feed}
import gleam/erlang/process
import gleam/list
import gleam/otp/static_supervisor as sup
import gleam/result
import poller
import table

/// Creates a supervisio tree for the entry table and the feed pollers it will be populated from.
pub fn start(feeds: List(Feed)) -> Result(process.Pid, Nil) {
  // Supervision tree
  //
  //  table_sup
  //  ├── table_worker
  //  └── poller_sup
  //      ├── feed_poller_worker
  //      ├── feed_poller_worker
  //      └── ...

  // prepare a subject for the table worker to communicate back a reference to the table
  // that the pollers will need to register themselves
  let table_subject = process.new_subject()
  let table_worker =
    sup.worker_child("table", fn() {
      let table = table.start()
      process.send(table_subject, table)
      Ok(process.subject_owner(table))
    })

  // the table sup is rest for one so if the table gets killed, we restart the poller sup
  // along with all children, so they register on the new table
  let table_sup = sup.new(sup.RestForOne) |> sup.add(table_worker)

  // get back a reference to the table actor to be used for the pollers to register
  let assert Ok(table) = process.receive(table_subject, 1000)

  sup.add(table_sup, build_poller_sup(table, feeds))
  |> sup.start_link()
  |> result.replace_error(Nil)
}

fn build_poller_sup(table: table.Table, feeds: List(Feed)) -> sup.ChildBuilder {
  sup.supervisor_child("poller_sup", fn() {
    // One for one so a feed dying doesn't affect the rest
    let poller_sup = sup.new(sup.OneForOne)

    // for each feed on the input list, create a poller actor, register it to the table
    // convert it to a child worker, and add it to the poller supervisor
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
  })
}
