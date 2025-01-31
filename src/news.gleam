import feed_source
import gleam/erlang/process
import gleam/io

pub fn main() {
  io.println("Hello from news!")

  feed_source.start("test url")

  process.sleep_forever()
}
