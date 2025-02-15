# news.olano.dev

A little link aggregator built with [Gleam](https://gleam.run/). See it live [here](https://news.olano.dev/).

## How it works
The app periodically pulls links from RSS/Atom feeds listed in a [config file](priv/feeds.csv) and sorts the entries in "inverted frequency order" (the sources that post least frequently show up first, so spammy feeds don't bury infrequent ones). This is a sort of spin-off of my [personal feed reader](https://github.com/facundoolano/feedi).

The list of entries is kept in memory and rebuilt every time the application starts (with a file cache to avoid spamming source feeds).

## Project structure and notes

- `src/news.gleam`: The entrypoint of the app, creates a supervision tree with worker processes and serves a couple of HTTP endpoits using mist.
- `src/templates/`: Defines a couple of [matcha](https://github.com/michaeljones/matcha) templates for the home page and the atom feed xml.
- `src/feed.gleam`: Basic Feed and Entry types, and functions to helpers to build them from parsed xml files.
- `src/parser.erl`: Erlang helper wrapping around [erlsom](https://github.com/willemdj/erlsom) to simplify extracting basic link data from atom and rss feeds.
- `src/poller.gleam`: [gleam/otp/actor](https://hexdocs.pm/gleam_otp/gleam/otp/actor.html) (Gleam equivalent of a [gen_server](https://www.erlang.org/docs/24/man/gen_server)) that periodically fetches the xml from a source feed url and parses its entries.
- `src/table.gleam`: a worker process that manages a sorted list of entries by merging the output of all poller processes. The table is stored to an erlang [persistent term](https://www.erlang.org/doc/apps/erts/persistent_term.html#get/0), to make it globally available without process communication.
- `src/table_sup.gleam`: Defines a supervision tree with a supervisor for the table and another for the list of poller actors. If the table process dies, the rest of the processes are restarted.

## Deploy

There are some general guidelines to deploy a Gleam app on linux [here](https://gleam.run/deployment/linux-server/).

Since I prefer to run without containers, I just installed a recent version of erlang via [kerl](https://github.com/kerl/kerl) and served the app with nginx as a proxy:

``` nginx
server {
    server_name news.olano.dev;

    location / {
    proxy_pass http://127.0.0.1:3210;
        include proxy_params;
    }
}
```

(I use [certbot](https://certbot.eff.org/) to manage certificates/https, which modified that config).

Then I have this systemd unit config to run it as a service:

```
[Unit]
Description=news.olano.dev
After=network.target

[Service]
Type=simple
User=news
Group=news
WorkingDirectory=/home/news/gleam_news
Environment="PATH=/home/news/erlang27/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/home/news/gleam_news/erlang-shipment/entrypoint.sh run
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Notice that I need to add the erlang bin dir to the path.

To deploy the project I export an erlang package from gleam and rsync it to the server (see [this makefile target](https://github.com/facundoolano/news.olano.dev/blob/4ddae39b471834ffd40e68cef996e43a03edbdd6/Makefile#L3-L5)).
