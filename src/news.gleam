import feed
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile
import table

pub fn main() {
  use contents <- result.try(simplifile.read("feeds.csv"))
  let feeds =
    contents
    |> string.split("\n")
    |> list.fold([], fn(acc, line) {
      case string.split(line, ",") {
        [name, url] -> [feed.start(name, url), ..acc]
        _ -> acc
      }
    })

  table.start(feeds)
  loop()

  Ok(Nil)
}

fn loop() {
  table.get()
  |> list.map(fn(e) { io.println(feed.entry_format(e)) })
  process.sleep(10_000)
  loop()
}
