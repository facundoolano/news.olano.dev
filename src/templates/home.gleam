// DO NOT EDIT: Code generated by matcha from home.matcha

import gleam/list
import gleam/string_tree.{type StringTree}

import feed.{type Entry}

pub fn render_tree(entries entries: List(Entry)) -> StringTree {
  let tree = string_tree.from_string("")
  let tree =
    string_tree.append(
      tree,
      "<!DOCTYPE html>
<html>
  <head>
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
    <meta charset=\"utf-8\" />
    <title>news.olano.dev</title>
    <link
      type=\"application/atom+xml\"
      rel=\"alternate\"
      href=\"/feed\"
      title=\"news.olano.dev\"
    />
    <style type=\"text/css\">
     body {
         max-width: 60em;
         margin: 0 auto;
         padding: 0 1rem;
         width: auto;
         font-family: Tahoma, Verdana, Arial, sans-serif;
         line-height: 1.6;
         font-size: 1rem;
     }
     h1,footer {
         text-align: center;
     }
     small {
         display: block;
     }
    </style>
  </head>
  <body>
      <h1>news.olano.dev</h1>
      <br/>
    <ol>
      ",
    )
  let tree =
    list.fold(entries, tree, fn(tree, entry) {
      let tree =
        string_tree.append(
          tree,
          "
      <li>
          <a href=\"",
        )
      let tree = string_tree.append(tree, entry.url)
      let tree = string_tree.append(tree, "\" target=\"_blank\">")
      let tree = string_tree.append(tree, entry.title)
      let tree =
        string_tree.append(
          tree,
          "</a>
          <small>",
        )
      let tree = string_tree.append(tree, feed.domain(entry))
      let tree = string_tree.append(tree, " | ")
      let tree = string_tree.append(tree, feed.time_ago(entry))
      let tree =
        string_tree.append(
          tree,
          "</small>
      </li>
      ",
        )

      tree
    })
  let tree =
    string_tree.append(
      tree,
      "
    </ol>
    <br/>
    <footer>
    <span>built with <a href=\"https://gleam.run/\">Gleam</a> | </span>
    <span>
        <a href=\"https://github.com/facundoolano/news.olano.dev/\">source code</a> |
    </span>
    <span>
        <a href=\"https://olano.dev/\">home</a>
    </span>
    </footer>
    <br/>
  </body>
</html>
",
    )

  tree
}

pub fn render(entries entries: List(Entry)) -> String {
  string_tree.to_string(render_tree(entries: entries))
}
