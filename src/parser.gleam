import birl
import feed.{type Entry, Entry}
import gleam/dict
import gleam/erlang
import gleam/erlang/atom
import gleam/erlang/charlist
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri

pub fn parse(body: String) -> Result(List(Entry), Nil) {
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
