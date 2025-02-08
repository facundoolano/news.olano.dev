import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import mist.{type Connection, type ResponseData}

import feed
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import simplifile
import table

pub fn main() {
  let assert Ok(Nil) = setup_feeds()
  run_server()
}

fn setup_feeds() {
  // TODO should we do this in the table module?
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
  Ok(table.start(feeds))
}

fn run_server() {
  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("Not Found!")))

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      case request.path_segments(req) {
        // for now a single page
        [] -> home(req)
        _ -> not_found
      }
    }
    |> mist.new
    |> mist.port(3000)
    |> mist.start_http

  process.sleep_forever()
}

fn home(_request: Request(Connection)) -> Response(ResponseData) {
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("Hello World!")))
}
