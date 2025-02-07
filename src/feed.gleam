import birl
import birl/duration
import gleam/dict
import gleam/erlang
import gleam/erlang/atom
import gleam/erlang/charlist
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/result
import simplifile

const poll_interval_ms = 3_600_000

const cache_dir: String = "./feedcache/"

pub type Message {
  PollFeed(Subject(Message))
  GetEntries(Subject(List(Entry)))
}

// TODO consider moving to its own mod
// TODO the bucket is more of an attr of the the feed, although it's more convenient to
// set it in the entry for later access / ordering, may need to revisit this
pub type Entry {
  Entry(title: String, url: String, published: birl.Time, freq_bucket: Int)
}

type State {
  State(
    name: String,
    url: String,
    entries: List(Entry),
    etag: Option(String),
    last_modified: Option(String),
  )
}

pub fn start(name: String, url: String) -> Subject(Message) {
  let assert Ok(source) =
    actor.start_spec(actor.Spec(
      init: fn() { init(name, url) },
      loop: handle_message,
      init_timeout: 10_000,
    ))
  source
}

pub fn entries(feed: Subject(Message)) -> List(Entry) {
  let entries = actor.call(feed, GetEntries(_), 10_000)
  let bucket = calc_bucket(entries)
  list.map(entries, fn(e) { Entry(..e, freq_bucket: bucket) })
}

/// Compare entries by frequency bucket and published date
/// (less frequent and newest come first)
pub fn entry_compare(e1: Entry, e2: Entry) -> order.Order {
  case int.compare(e1.freq_bucket, e2.freq_bucket) {
    order.Eq -> birl.compare(e2.published, e1.published)
    // swap to get newer first
    result -> result
  }
}

pub fn entry_format(entry: Entry) {
  entry.title
  <> " ("
  <> entry.url
  <> ")\n"
  <> birl.legible_difference(birl.now(), entry.published)
  <> "\n"
}

// TODO unit test this
fn calc_bucket(entries: List(Entry)) -> Int {
  let by_date =
    list.sort(entries, by: fn(e1, e2) {
      birl.compare(e1.published, e2.published)
    })

  case list.first(by_date), list.last(by_date) {
    Ok(first), Ok(last) -> {
      let delta = birl.difference(last.published, first.published)
      let days = int.max(1, duration.blur_to(delta, duration.Day))
      let posts_per_day =
        int.to_float(list.length(entries)) /. int.to_float(days)

      case posts_per_day {
        // once a month or less
        n if n <=. 1.0 /. 30.0 -> 0
        // once week or less
        n if n <=. 1.0 /. 7.0 -> 1
        // once a day or less
        n if n <=. 1.0 /. 1.0 -> 2
        // 5 times a day or less
        n if n <=. 1.0 /. 5.0 -> 3
        // 20 times a day or less
        n if n <=. 1.0 /. 20.0 -> 4
        // more
        _ -> 5
      }
    }
    _, _ -> 0
  }
}

fn init(name: String, url: String) {
  // if there's a previously cached file, parse it now and request later
  // otherwise schedule to request now (after initialization, with a random delay)
  let #(entries, interval) =
    simplifile.read(cache_dir <> name)
    |> result.replace_error(Nil)
    |> result.try(parse_feed)
    |> result.map(fn(entries) { #(entries, poll_interval_ms) })
    |> result.lazy_unwrap(or: fn() { #([], int.random(5000)) })

  let state = State(name, url, entries, None, None)
  let subject = process.new_subject()
  process.send_after(subject, interval, PollFeed(subject))

  // I don't really understand what this means
  let selector =
    process.new_selector() |> process.selecting(subject, fn(x) { x })

  actor.Ready(state, selector)
}

fn handle_message(message: Message, state: State) {
  case message {
    GetEntries(client) -> {
      process.send(client, state.entries)
      actor.continue(state)
    }
    PollFeed(self) -> {
      io.println("polling " <> state.name)
      let maybe_response =
        fetch(
          state.name,
          state.url,
          state.etag,
          state.last_modified,
          cache_to: cache_dir,
        )

      // TODO refactor
      let state = case maybe_response {
        Ok(#(body, etag, last_modified)) ->
          case parse_feed(body) {
            Ok(entries) ->
              State(
                ..state,
                entries: entries,
                etag: etag,
                last_modified: last_modified,
              )
            _ -> {
              io.println("parsing error querying " <> state.url)
              state
            }
          }
        _ -> {
          io.println("request error querying " <> state.url)
          state
        }
      }

      process.send_after(self, poll_interval_ms, PollFeed(self))
      actor.continue(state)
    }
  }
}

/// TODO explain
fn fetch(
  name: String,
  url: String,
  etag: Option(String),
  last_modified: Option(String),
  cache_to cache_dir: String,
) -> Result(#(String, Option(String), Option(String)), String) {
  let path = cache_dir <> name

  use _ <- result.try_recover(
    result.map(simplifile.read(path), fn(body) { #(body, None, None) }),
  )
  let assert Ok(req) = request.to(url)
  let req = request.prepend_header(req, "accept", "application/xml")
  let req = case etag {
    Some(etag) -> request.prepend_header(req, "If-None-Match", etag)
    _ -> req
  }
  let req = case last_modified {
    Some(last_modified) ->
      request.prepend_header(req, "If-Modified-Since", last_modified)
    _ -> req
  }

  // TODO fail if error status
  use resp <- result.try(result.replace_error(httpc.send(req), "request error"))

  case resp.status {
    status if status >= 400 -> {
      Error("response error " <> int.to_string(status))
    }
    _ -> {
      // cache contents for next time
      let _ =
        result.try(simplifile.create_directory_all(cache_dir), fn(_) {
          simplifile.write(path, resp.body)
        })

      Ok(#(
        resp.body,
        option.from_result(response.get_header(resp, "ETag")),
        option.from_result(response.get_header(resp, "Last-Modified")),
      ))
    }
  }
}

fn parse_feed(body: String) -> Result(List(Entry), Nil) {
  // parsing here just to check the tag, then parsing again in the internal atom/rss
  // helpers because if I try to reuse the structure the type checker complaints
  // about the differing structures of the two formats
  // hacky but beats figuring out the gleam decoder stuff
  case parse_xml_root(body) {
    Ok(#("feed", _)) -> parse_atom_feed(body)
    Ok(#("rss", _)) -> parse_rss_feed(body)
    Ok(#(other, _)) -> {
      io.println("unknown feed type " <> other)
      Error(Nil)
    }
    err -> {
      let _ = io.debug(err)
      Error(Nil)
    }
  }
}

fn parse_rss_feed(body: String) -> Result(List(Entry), Nil) {
  use #(_, elements) <- result.try(parse_xml_root(body))

  let assert [#(_, _, elements), ..] = elements
  list.fold(elements, [], fn(acc, entry) {
    case entry {
      #("item", _, etc) -> {
        parse_rss_entry(etc)
        |> result.map(fn(entry) { [entry, ..acc] })
        |> result.unwrap(acc)
      }
      _ -> acc
    }
  })
  |> list.reverse
  |> Ok
}

fn parse_atom_feed(body: String) -> Result(List(Entry), Nil) {
  use #(_, root) <- result.try(parse_xml_root(body))

  list.fold(root, [], fn(acc, entry) {
    case entry {
      #("entry", _, elements) -> {
        parse_atom_entry(elements)
        |> result.map(fn(entry) { [entry, ..acc] })
        |> result.unwrap(acc)
      }
      _ -> acc
    }
  })
  |> list.reverse
  |> Ok
}

fn parse_rss_entry(etc) -> Result(Entry, Nil) {
  let values =
    list.fold(etc, dict.new(), fn(entry, element) {
      case element {
        #("title", _, [title]) ->
          dict.insert(entry, "title", charlist.to_string(title))
        #("pubDate", _, [published]) -> {
          dict.insert(entry, "published", charlist.to_string(published))
        }
        #("link", _, [link]) -> {
          dict.insert(entry, "url", charlist.to_string(link))
        }
        #(_, _, _) -> entry
      }
    })

  use title <- result.try(dict.get(values, "title"))
  use url <- result.try(dict.get(values, "url"))
  use published <- result.try(dict.get(values, "published"))
  use datetime <- result.try(birl.from_http(published))
  Ok(Entry(title, url, datetime, 0))
}

fn parse_atom_entry(elements: List(#(_, _, _))) -> Result(Entry, Nil) {
  let values =
    list.fold(elements, dict.new(), fn(entry, element) {
      case element {
        #("title", _, [title]) ->
          dict.insert(entry, "title", charlist.to_string(title))
        #("published", _, [published]) -> {
          dict.insert(entry, "published", charlist.to_string(published))
        }
        #("link", link_attrs, _) -> {
          dict.from_list(link_attrs)
          |> dict.get("href")
          |> result.map(charlist.to_string)
          |> result.map(fn(url) { dict.insert(entry, "url", url) })
          |> result.unwrap(entry)
        }
        #(_, _, _) -> entry
      }
    })

  use title <- result.try(dict.get(values, "title"))
  use url <- result.try(dict.get(values, "url"))
  use published <- result.try(dict.get(values, "published"))
  use datetime <- result.try(birl.from_naive(published))
  Ok(Entry(title, url, datetime, 0))
}

// TODO rescue to prevent errors
fn parse_xml_root(body: String) -> Result(#(String, root2), Nil) {
  let parsed_safe =
    erlang.rescue(fn() {
      parse_xml(body, [
        #(atom.create_from_string("nameFun"), fn(name, _, _) {
          charlist.to_string(name)
        }),
      ])
    })

  case parsed_safe {
    Ok(#(_ok, root, _tail)) -> {
      let #(tag, _, elements) = root
      Ok(#(tag, elements))
    }
    _ -> Error(Nil)
  }
}

@external(erlang, "erlsom", "simple_form")
fn parse_xml(doc: String, options: List(a)) -> #(result, item, String)
