import birl
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
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import simplifile

const poll_interval_ms = 3_600_000

const cache_dir: String = "./feedcache/"

pub type Feed =
  Subject(Message)

pub type Message {
  PollFeed(Subject(Message))
  GetEntries(Subject(List(Entry)))
}

pub type Entry {
  Entry(title: String, url: String, published: birl.Time)
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

pub fn start(name: String, url: String) -> Feed {
  let assert Ok(feed) =
    actor.start_spec(actor.Spec(
      init: fn() { init(name, url) },
      loop: handle_message,
      init_timeout: 10_000,
    ))
  feed
}

pub fn entries(feed: Subject(Message)) -> List(Entry) {
  actor.call(feed, GetEntries(_), 10_000)
}

pub fn entry_format(entry: Entry) {
  entry.title
  <> " ["
  <> entry.url
  <> "] | "
  <> birl.legible_difference(birl.now(), entry.published)
  // <> "\n"
}

fn init(name: String, url: String) {
  // if there's a previously cached file, parse it now and request later
  // otherwise schedule to request now (after initialization, with a random delay)
  let #(entries, interval) =
    simplifile.read(cache_dir <> name)
    // TODO cleanup errors
    |> result.replace_error(Nil)
    |> result.try(parse_feed)
    |> result.map(fn(entries) { #(entries, poll_interval_ms) })
    |> result.lazy_unwrap(or: fn() { #([], int.random(5000)) })

  let state = State(name, url, entries, None, None)
  let subject = process.new_subject()
  // I don't really understand what this means
  let selector =
    process.new_selector() |> process.selecting(subject, fn(x) { x })

  process.send_after(subject, interval, PollFeed(subject))

  actor.Ready(state, selector)
}

fn handle_message(message: Message, state: State) {
  case message {
    GetEntries(client) -> {
      process.send(client, state.entries)
      actor.continue(state)
    }
    PollFeed(self) -> {
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
            Ok(entries) -> {
              io.println("OK " <> state.url)
              State(
                ..state,
                entries: entries,
                etag: etag,
                last_modified: last_modified,
              )
            }
            // TODO cleanup errors
            Error(error) -> {
              io.println(
                "ERROR parsing " <> state.url <> " " <> string.inspect(error),
              )

              state
            }
          }
        // TODO cleanup errors
        Error(error) -> {
          io.println(
            "ERROR fetching " <> state.url <> " " <> string.inspect(error),
          )
          state
        }
      }

      process.send_after(self, poll_interval_ms, PollFeed(self))
      actor.continue(state)
    }
  }
}

// FIXME maybe take a feed and return a feed in addition to the body?
// or separate in two: http only and feed manipulation
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

  let maybe_resp =
    httpc.configure()
    |> httpc.follow_redirects(True)
    |> httpc.dispatch(req)
    // TODO cleanup errors
    |> result.map_error(fn(e) { "request error: " <> string.inspect(e) })

  use resp <- result.try(maybe_resp)

  case resp.status {
    status if status >= 400 -> {
      // TODO cleanup errors?
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
      // TODO cleanup errors
      io.println("unknown feed type " <> other)
      Error(Nil)
    }
    err -> {
      // TODO cleanup errors
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
  use url <- result.try(normalize(url))
  use datetime <- result.try(birl.from_http(published))
  Ok(Entry(title, url, datetime))
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
  use url <- result.try(normalize(url))
  use published <- result.try(dict.get(values, "published"))
  use datetime <- result.try(birl.from_naive(published))
  Ok(Entry(title, url, datetime))
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
