import birl
import gleam/option.{Some}
import gleam/string
import gleam/uri

pub type Feed {
  Feed(name: String, url: String)
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
