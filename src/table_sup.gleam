import feed.{type Feed}
import gleam/erlang/process
import gleam/list
import gleam/otp/static_supervisor as sup
import gleam/result
import poller
import table

pub fn start(feeds: List(Feed)) -> Result(process.Pid, Nil) {
  let subject = process.new_subject()

  let table_worker =
    sup.worker_child("table", fn() {
      let table = table.start()
      process.send(subject, table)
      Ok(process.subject_owner(table))
    })
  let table_sup = sup.new(sup.RestForOne) |> sup.add(table_worker)

  let assert Ok(table) = process.receive(subject, 1000)
  sup.add(table_sup, build_poller_sup(table, feeds))
  |> sup.start_link()
  |> result.replace_error(Nil)
}

fn build_poller_sup(table: table.Table, feeds: List(Feed)) -> sup.ChildBuilder {
  sup.supervisor_child("poller_sup", fn() {
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
  })
}
