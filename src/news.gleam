import feed_source
import gleam/erlang/process
import gleam/io

pub fn main() {
  io.println("Hello from news!")

  feed_source.start("https://olano.dev/feed.xml")
  |> loop
}

fn loop(feed) {
  feed
  |> feed_source.entries
  |> io.debug

  process.sleep(1000)
  loop(feed)
}
