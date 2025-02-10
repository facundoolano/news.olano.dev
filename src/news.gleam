import feed.{Feed}
import gleam/bytes_tree
import gleam/dict
import gleam/http
import gleam/http/cookie
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import mist.{type Connection, type ResponseData}
import templates/atom_feed
import templates/home

import gleam/erlang/process
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

      let segments = request.path_segments(req)
      let resp = case req.method, segments {
        // for now a single page
        http.Get, [] -> home(req)
        http.Post, ["next"] -> next_page(req)
        http.Post, ["reset"] -> reset_seen(req)
        _, ["feed"] -> atom_feed()
        _, _ -> not_found
      }

      io.println(" -> " <> int.to_string(resp.status))
      resp
    }
    |> mist.new
    |> mist.port(3210)
    |> mist.start_http

  process.sleep_forever()
}

fn home(req: Request(Connection)) -> Response(ResponseData) {
  // TODO read preexisting seen from request, if present use them to filter results
  let cookies = request.get_cookies(req) |> dict.from_list
  let seen_from = option.from_result(dict.get(cookies, "seen_from"))
  let seen_to = option.from_result(dict.get(cookies, "seen_to"))

  let #(entries, sent_from, sent_to) = table.filter(seen_from, seen_to)

  let body =
    entries
    |> home.render_tree()
    |> bytes_tree.from_string_tree()
    |> mist.Bytes

  response.new(200)
  |> response.set_header("Content-Type", "text/html")
  |> response.set_body(body)
  |> response.set_cookie(
    "sent_from",
    option.unwrap(sent_from, ""),
    cookie.defaults(http.Https),
  )
  |> response.set_cookie(
    "sent_to",
    option.unwrap(sent_to, ""),
    cookie.defaults(http.Https),
  )
}

fn next_page(req: Request(Connection)) -> Response(ResponseData) {
  // get the SENT cookies
  let cookies = request.get_cookies(req) |> dict.from_list
  let sent_from = option.from_result(dict.get(cookies, "sent_from"))
  let sent_to = option.from_result(dict.get(cookies, "sent_to"))

  // Use them to set the SEEN cookies, the previous page as seen
  // and redirect to fetch a new page
  response.new(303)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
  |> response.set_header("location", "/")
  |> response.set_cookie(
    "seen_from",
    option.unwrap(sent_from, ""),
    cookie.defaults(http.Http),
  )
  |> response.set_cookie(
    "seen_to",
    option.unwrap(sent_to, ""),
    cookie.defaults(http.Http),
  )
}

fn reset_seen(_req: Request(Connection)) -> Response(ResponseData) {
  response.new(303)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
  |> response.set_header("location", "/")
  |> response.set_cookie("seen_from", "", cookie.defaults(http.Http))
  |> response.set_cookie("seen_to", "", cookie.defaults(http.Http))
}

fn atom_feed() -> Response(ResponseData) {
  let body =
    table.get()
    |> atom_feed.render_tree()
    |> bytes_tree.from_string_tree()
    |> mist.Bytes

  response.new(200)
  |> response.set_header("Content-Type", "text/xml")
  |> response.set_body(body)
}
