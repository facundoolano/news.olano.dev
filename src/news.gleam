import feed_source
import gleam/erlang/process
import gleam/io
import gleam/list

pub fn main() {
  io.println("Hello from news!")

  [
    feed_source.start("https://olano.dev/feed.xml"),
    feed_source.start("https://jorge.olano.dev/feed.xml"),
  ]
  |> loop
}

fn loop(feeds) {
  list.flat_map(feeds, feed_source.entries)
  |> io.debug

  process.sleep(1000)
  loop(feeds)
}
