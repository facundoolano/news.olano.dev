#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa ./build/erlang-shipment/erlsom/ebin -pa ./build/erlang-shipment/news/ebin

main([Filename]) ->
    %% Open and read the file
    case file:read_file(Filename) of
        {ok, Content} ->
            %% Parse the XML content
            case parser:parse_feed(Content) of
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
