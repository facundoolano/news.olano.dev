import feed.{type Entry}
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub fn main() {
  use contents <- result.try(simplifile.read("feeds.csv"))
  contents
  |> string.split("\n")
  |> list.fold([], fn(acc, line) {
    case string.split(line, ",") {
      [name, url] -> [feed.start(name, url), ..acc]
      _ -> acc
    }
  })
  |> loop
  Ok(Nil)
}

fn loop(feeds) {
  latest_entries(feeds)
  |> list.take(30)
  |> list.map(fn(e) { io.println(feed.entry_format(e)) })
  process.sleep(10_000)
  loop(feeds)
}

fn latest_entries(feeds) -> List(Entry) {
  list.flat_map(feeds, feed.entries)
  |> list.sort(by: feed.entry_compare)
  // TODO remove older than 48hs
  // TODO order by bucket asc + date desc
  // TODO remove duplicates
}
