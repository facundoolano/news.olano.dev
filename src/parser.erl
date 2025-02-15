-module(parser).
-export([parse_feed/1]).

parse_feed(Body) ->
    try erlsom:simple_form(Body, [{nameFun, fun(Name, _,_) -> unicode:characters_to_binary(Name) end }]) of
        {ok, {<<"rss">>, _, [{_, _, Elements}|_]}, _} -> {<<"rss">>, parse_rss(Elements)};
        {ok, {<<"feed">>, _, Elements}, _} -> {<<"atom">>, parse_atom(Elements)};
        Error -> {<<"error">>, Error}
    catch _:_ ->
            {<<"error">>, bad_parse}
    end.


parse_atom(Elements) ->
    Entries = lists:foldl(fun({<<"entry">>, _, Attrs}, Acc) -> [parse_atom_entry(Attrs, #{}) |Acc];
                             (_, Acc) -> Acc
                          end, [], Elements),
    Entries.

parse_atom_entry([], Acc) ->
    Acc;
parse_atom_entry([{<<"title">>, _, [Title]}|Rest], Acc) ->
    parse_atom_entry(Rest, Acc#{ <<"title">> => unicode:characters_to_binary(Title)});
parse_atom_entry([{<<"published">>, _, [Published]}|Rest], Acc) ->
    parse_atom_entry(Rest, Acc#{ <<"published">> => unicode:characters_to_binary(Published)});
parse_atom_entry([{<<"link">>, LinkAttrs, _}|Rest], Acc) ->
    Url = maps:get(<<"href">>, maps:from_list(LinkAttrs)),
    parse_atom_entry(Rest, Acc#{ <<"url">> => unicode:characters_to_binary(Url)});
parse_atom_entry([_|Rest], Acc) ->
    parse_atom_entry(Rest, Acc).


parse_rss(Elements) ->
    Entries = lists:foldl(fun({<<"item">>, _, Attrs}, Acc) -> [parse_rss_entry(Attrs, #{}) |Acc];
                             (_, Acc) -> Acc
                          end, [], Elements),
    Entries.

parse_rss_entry([], Acc) ->
    Acc;
parse_rss_entry([{<<"title">>, _, [Title]}|Rest], Acc) ->
    parse_rss_entry(Rest, Acc#{ <<"title">> => unicode:characters_to_binary(Title)});
parse_rss_entry([{<<"pubDate">>, _, [Published]}|Rest], Acc) ->
    parse_rss_entry(Rest, Acc#{ <<"published">> => unicode:characters_to_binary(Published)});
parse_rss_entry([{<<"link">>, _, [Url]}|Rest], Acc) ->
    parse_rss_entry(Rest, Acc#{ <<"url">> => unicode:characters_to_binary(Url)});
parse_rss_entry([_|Rest], Acc) ->
    parse_rss_entry(Rest, Acc).
