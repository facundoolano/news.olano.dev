import birl
import feed.{type Entry, Entry}
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri

/// Given an xml document of an Atom or RSS feed, parse it into a list of entries.
pub fn parse(body: String) -> Result(List(Entry), String) {
  case parse_feed(body) {
    #("error", msg) -> Error(string.inspect(msg))
    #(feed_type, entries) -> {
      let entries =
        list.fold(entries, [], fn(acc, e) {
          case parse_entry(feed_type, e) {
            Ok(entry) -> [entry, ..acc]
            _ -> acc
          }
        })
      Ok(entries)
    }
  }
}

/// Takes the erlang generated Entry map and wraps it in proper types
fn parse_entry(
  feed_type: String,
  entry: dict.Dict(String, String),
) -> Result(Entry, Nil) {
  let title = dict.get(entry, "title")
  let url = dict.get(entry, "url") |> result.try(normalize)
  let published = dict.get(entry, "published")
  let published = case feed_type {
    "atom" -> result.try(published, birl.from_naive)
    "rss" -> result.try(published, birl.from_http)
    _ -> Error(Nil)
  }

  case title, url, published {
    Ok(title), Ok(url), Ok(published) -> Ok(Entry(title, url, published))
    _, _, _ -> Error(Nil)
  }
}

fn normalize(url: String) -> Result(String, Nil) {
  use parsed <- result.try(uri.parse(url))
  use host <- result.try(option.to_result(parsed.host, Nil))
  let path = case string.ends_with(parsed.path, "/") {
    True -> string.drop_end(parsed.path, up_to: 1)
    False -> parsed.path
  }
  let host = string.replace(host, "www.", "")
  let url = "https://" <> host <> path
  Ok(url)
}

// Rely on erlang to call the xml parsing library and traversing the resulting
// (very dynamic) structure.
@external(erlang, "parser_ffi", "parse_feed")
fn parse_feed(doc: String) -> #(String, List(dict.Dict(String, String)))
