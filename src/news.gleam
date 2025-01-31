import feed
import gleam/erlang/process
import gleam/io
import gleam/list

pub fn main() {
  io.println("Hello from news!")

  [
    feed.start("https://olano.dev/feed.xml"),
    feed.start("https://jorge.olano.dev/feed.xml"),
  ]
  |> loop
}

fn loop(feeds) {
  list.flat_map(feeds, feed.entries)
  |> io.debug

  process.sleep(1000)
  loop(feeds)
}
