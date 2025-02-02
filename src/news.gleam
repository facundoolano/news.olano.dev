import feed
import gleam/io
import gleam/list

pub fn main() {
  io.println("Hello from news!")

  [
    feed.start("olano.dev", "https://olano.dev/feed.xml"),
    feed.start("jorge", "https://jorge.olano.dev/feed.xml"),
  ]
  |> loop
}

fn loop(feeds) {
  list.flat_map(feeds, feed.entries)
  |> list.sort(by: feed.entry_compare)
  |> list.map(fn(e) { io.println(feed.entry_format(e)) })
  // process.sleep(1000)
  // loop(feeds)
}
