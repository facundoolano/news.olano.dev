import birl
import feed.{Feed}
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import mist.{type Connection, type ResponseData}

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
  // TODO should we do this in the table module?
  use contents <- result.try(simplifile.read("feeds.csv"))
  let feeds =
    contents
    |> string.split("\n")
    |> list.fold([], fn(acc, line) {
      case string.split(line, ",") {
        [name, url] -> [poller.start(Feed(name, url)), ..acc]
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
  let entry_items =
    table.get()
    |> list.map(fn(entry) {
      let time_ago = birl.legible_difference(birl.now(), entry.published)

      "<li>"
      <> "<a href=\""
      <> entry.url
      <> "\" target=\"_blank\">"
      <> entry.title
      <> "</a> | "
      <> time_ago
      <> " </li>"
    })
    |> string.join("\n")

  let body = "<!DOCTYPE html>
<html>
    <head>
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
        <meta charset=\"utf-8\">
        <title>news.olano.dev</title>
        <link type=\"application/atom+xml\" rel=\"alternate\" href=\"/feed.xml\" title=\"{{ site.config.name }}\"/>
    </head>
    <body>
      <h1>news.olano.dev</h1>
        <ol>
" <> entry_items <> "
        </ol>
        <p>built with <a href=\"https://gleam.run/\">Gleam</a></p>
        <p><a href=\"https://github.com/facundoolano/news.olano.dev/\">source code</a></p>
    </body>
</html>"

  response.new(200)
  |> response.set_header("Content-Type", "text/html")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
