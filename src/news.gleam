import feed.{Feed}
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import mist.{type Connection, type ResponseData}
import templates/home

import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import poller
import simplifile
import table

pub fn main() {
  let assert Ok(Nil) = setup_feeds()
  run_server()
}

fn setup_feeds() {
  use contents <- result.try(simplifile.read("feeds.csv"))
  let feeds =
    contents
    |> string.split("\n")
    |> list.fold([], fn(acc, line) {
      case string.split(line, ",") {
        // NOTE this should likely be done by a supervisor?
        [name, url] ->
          case poller.start(Feed(name, url)) {
            Ok(poller) -> [poller, ..acc]
            _ -> acc
          }
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
      io.print(
        req.method |> http.method_to_string |> string.uppercase
        <> " "
        <> req.path,
      )

      let resp = case request.path_segments(req) {
        // for now a single page
        [] -> home()
        _ -> not_found
      }

      io.println(" -> " <> int.to_string(resp.status))
      resp
    }
    |> mist.new
    |> mist.port(3210)
    |> mist.start_http

  process.sleep_forever()
}

fn home() -> Response(ResponseData) {
  let body =
    table.get()
    |> home.render_tree()
    |> bytes_tree.from_string_tree()
    |> mist.Bytes

  response.new(200)
  |> response.set_header("Content-Type", "text/html")
  |> response.set_body(body)
}
