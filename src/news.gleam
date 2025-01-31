import feed_source
import gleam/erlang/process
import gleam/io

pub fn main() {
  io.println("Hello from news!")

  let feed = feed_source.start("https://olano.dev/feed.xml")

  feed
  |> feed_source.entries
  |> io.debug

  process.sleep(10_000)

  feed
  |> feed_source.entries
  |> io.debug
}
