#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa ./build/erlang-shipment/erlsom/ebin

main([Filename]) ->
    %% Open and read the file
    case file:read_file(Filename) of
        {ok, Content} ->
            %% Parse the XML content
            case parse_feed(Content) of
                {ok, <<"rss">>, Elements} ->
                    io:format("Parsed RSS: ~p~n", [Elements]);
                {ok, <<"atom">>, Elements} ->
                    io:format("Parsed Atom: ~p~n", [Elements]);
                {error, Reason} ->
                    io:format("Error parsing XML: ~p~n", [Reason])
            end;
        {error, Reason} ->
            io:format("Error reading file: ~p~n", [Reason])
    end;
main(_) ->
    io:format("Usage: scriptname <filename>~n").

parse_feed(Body) ->
    try erlsom:simple_form(Body, [{nameFun, fun(Name, _,_) -> list_to_binary(Name) end }]) of
        {ok, {<<"rss">>, _, [{_, _, Elements}|_]}, _} -> {ok, <<"rss">>, parse_rss(Elements)};
        {ok, {<<"feed">>, _, Elements}, _} -> {ok, <<"atom">>, parse_atom(Elements)};
        Error -> {error, Error}
    catch _:_ ->
            {error, bad_parse}
    end.


parse_atom(Elements) ->
    Entries = lists:foldl(fun({<<"entry">>, _, Attrs}, Acc) -> [parse_atom_entry(Attrs, #{}) |Acc];
                             (_, Acc) -> Acc
                          end, [], Elements),
    Entries.

parse_atom_entry([], Acc) ->
    Acc;
parse_atom_entry([{<<"title">>, _, [Title]}|Rest], Acc) ->
    parse_atom_entry(Rest, Acc#{ <<"title">> => list_to_binary(Title)});
parse_atom_entry([{<<"published">>, _, [Published]}|Rest], Acc) ->
    parse_atom_entry(Rest, Acc#{ <<"published">> => list_to_binary(Published)});
parse_atom_entry([{<<"link">>, LinkAttrs, _}|Rest], Acc) ->
    Url = maps:get(<<"href">>, maps:from_list(LinkAttrs)),
    parse_atom_entry(Rest, Acc#{ <<"url">> => list_to_binary(Url)});
parse_atom_entry([_|Rest], Acc) ->
    parse_atom_entry(Rest, Acc).




parse_rss(Elements)->
    Elements.
