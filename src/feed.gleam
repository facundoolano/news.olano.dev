import birl
import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/uri

pub type Feed {
  Feed(name: String, url: String)
}

pub type FeedError {
  NotModified
  RequestError
  ResponseError(status: Int)
  ParsingError(msg: String)
  FileError
}

pub type Entry {
  Entry(title: String, url: String, published: birl.Time)
}

pub fn time_ago(entry: Entry) -> String {
  birl.legible_difference(birl.now(), entry.published)
}

pub fn domain(entry: Entry) -> String {
  let assert Ok(parsed) = uri.parse(entry.url)
  let assert Some(host) = parsed.host
  string.replace(host, "www.", "")
}

/// Given an xml document of an Atom or RSS feed, parse it into a list of entries.
pub fn parse(body: String) -> Result(List(Entry), FeedError) {
  case parse_feed(body) {
    #("error", msg) -> Error(ParsingError(string.inspect(msg)))
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
@external(erlang, "parser", "parse_feed")
fn parse_feed(doc: String) -> #(String, List(dict.Dict(String, String)))
