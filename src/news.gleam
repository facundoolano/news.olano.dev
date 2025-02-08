import birl
import birl/duration
import feed.{type Entry}
import gleam/dict
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
  |> list.map(fn(e) { io.println(feed.entry_format(e)) })
  process.sleep(10_000)
  loop(feeds)
}

fn latest_entries(feeds) -> List(Entry) {
  list.flat_map(feeds, feed.entries)
  // index by url to remove duplicates
  // and keep only the last 48hs of entries
  |> list.fold_right(dict.new(), fn(acc, e) {
    let delta = birl.difference(birl.now(), e.published)
    case duration.blur_to(delta, duration.Hour) < 72 {
      True -> dict.insert(acc, e.url, e)
      False -> acc
    }
  })
  |> dict.values
  |> list.sort(by: feed.entry_compare)
}
