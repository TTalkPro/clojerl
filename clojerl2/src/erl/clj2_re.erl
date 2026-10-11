%%%-------------------------------------------------------------------
%%% @doc clj2_re — regular expressions (clojerl2-020) on Erlang's `re'
%%% (PCRE2), in unicode mode over UTF-8 binaries.
%%%
%%% A pattern is `{regex, nil, Source}'; it prints as #"Source". OTP 28's
%%% compiled patterns hold a reference, so they cannot be compiled-in
%%% constants: they are compiled on first use and kept in the ETS cache
%%% `clj2_re' (bounded: cleared past ?CACHE_MAX entries). Java and PCRE
%%% regex syntax agree on what Clojure code uses (classes, groups, named
%%% groups, lookaround, \p{..}, flags (?i)...).
%%%
%%% A matcher (re-matcher) is `{matcher, nil, Key}', its position kept in
%%% this process's dictionary, like a volatile.
%%%-------------------------------------------------------------------
-module(clj2_re).

-export([new_table/0, pattern/1, source/1, is_pattern/1]).
-export([re_find/2, re_matches/2, re_seq/2, matcher/2, matcher_find/1, groups/1]).
-export([matches/2, compiled/1, compiled_n/2, group_numbers/1, result/3]).

-define(TAB, clj2_re).
-define(CACHE_MAX, 10000).

%% @private called by the clj2_ns server, which owns the table
new_table() ->
    ?TAB = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    ok.

%% @doc (re-pattern s): a pattern; a pattern is returned as is.
pattern({regex, _, _} = P) -> P;
pattern(Src) when is_binary(Src) -> _ = compiled(Src), {regex, nil, Src}.

source({regex, _, Src}) -> Src.

is_pattern({regex, _, _}) -> true;
is_pattern(_) -> false.

%% the compiled form of a source: as written (search), or wrapped to match
%% the whole input (re-matches)
compiled(Src) -> compiled(Src, search).

compiled(Src, Mode) -> element(1, compiled_n(Src, Mode)).

%% → {MP, NumberOfGroups}: PCRE leaves out trailing unmatched groups, Java
%% reports every group (nil when unmatched), so results are padded
compiled_n(Src, Mode) ->
    clj2_ns:ensure_started(),
    Key = {Mode, Src},
    case ets:lookup(?TAB, Key) of
        [{_, MP, N}] -> {MP, N};
        [] ->
            Text = case Mode of
                       search -> Src;
                       whole -> <<"(?:", Src/binary, ")\\z">>
                   end,
            case re:compile(Text, [unicode, ucp]) of
                {ok, MP} ->
                    ets:info(?TAB, size) > ?CACHE_MAX andalso ets:delete_all_objects(?TAB),
                    N = group_count(Src),
                    ets:insert(?TAB, {Key, MP, N}),
                    {MP, N};
                {error, {Why, At}} ->
                    erlang:error(clj2_rt:ex_info(
                                   iolist_to_binary(io_lib:format("Invalid regex ~ts at ~b: ~ts",
                                                                  [Src, At, Why])),
                                   clj2_coll:hash_map_kv([':pattern', Src]), nil))
            end
    end.

%% match → the whole match, or [whole g1 g2 ...] when the pattern has
%% groups (an unmatched group is nil), as in Clojure
result(S, Idx, 0) -> part(S, hd(Idx));
result(S, Idx, N) ->
    Padded = Idx ++ lists:duplicate(N + 1 - length(Idx), {-1, 0}),
    clj2_coll:vector([part(S, I) || I <- Padded]).

%% @doc The number of capturing groups in a regex source: plain ( and
%% named groups count; (?: (?= (?! (?<= (?<! (?> ... do not; escapes and
%% [...] classes are skipped.
group_count(Src) -> length([K || K <- maps:keys(group_numbers(Src)), is_integer(K)]).

%% @doc #{Number => Number, Name => Number} for the groups of a source
%% (re:inspect lists names alphabetically, not by group number).
group_numbers(Src) -> groups(Src, 0, false, #{}).

groups(<<"\\", _/utf8, R/binary>>, N, InClass, Acc) -> groups(R, N, InClass, Acc);
groups(<<"[", R/binary>>, N, false, Acc) -> groups(R, N, true, Acc);
groups(<<"]", R/binary>>, N, true, Acc) -> groups(R, N, false, Acc);
groups(<<"(?<=", R/binary>>, N, false, Acc) -> groups(R, N, false, Acc);
groups(<<"(?<!", R/binary>>, N, false, Acc) -> groups(R, N, false, Acc);
groups(<<"(?<", R/binary>>, N, false, Acc) -> named(R, $>, N + 1, Acc);
groups(<<"(?P<", R/binary>>, N, false, Acc) -> named(R, $>, N + 1, Acc);
groups(<<"(?'", R/binary>>, N, false, Acc) -> named(R, $', N + 1, Acc);
groups(<<"(?", R/binary>>, N, false, Acc) -> groups(R, N, false, Acc);
groups(<<"(", R/binary>>, N, false, Acc) -> groups(R, N + 1, false, Acc#{N + 1 => N + 1});
groups(<<_/utf8, R/binary>>, N, InClass, Acc) -> groups(R, N, InClass, Acc);
groups(<<>>, _, _, Acc) -> Acc.

named(R, Close, N, Acc) ->
    [Name, After] = binary:split(R, <<Close>>),
    groups(After, N, false, Acc#{N => N, Name => N}).



part(_, {-1, _}) -> nil;
part(S, {B, L}) -> binary:part(S, B, L).

%% @doc (re-find re s), or (re-find matcher)
re_find(Re, S) when is_binary(S) ->
    {MP, N} = compiled_n(source(pattern(Re)), search),
    case re:run(S, MP, [{capture, all, index}]) of
        {match, Idx} -> result(S, Idx, N);
        nomatch -> nil
    end.

%% @doc (re-matches re s): the whole of s must match
re_matches(Re, S) when is_binary(S) ->
    {MP, N} = compiled_n(source(pattern(Re)), whole),
    case re:run(S, MP, [anchored, {capture, all, index}]) of
        {match, Idx} -> result(S, Idx, N);
        nomatch -> nil
    end.

%% @doc Does the whole of S match? (for clojure.string and friends)
matches(Re, S) -> re_matches(Re, S) =/= nil.

%% @doc (re-seq re s): every match, left to right
re_seq(Re, S) when is_binary(S) ->
    {MP, N} = compiled_n(source(pattern(Re)), search),
    case re:run(S, MP, [global, {capture, all, index}]) of
        {match, Ms} -> [result(S, Idx, N) || Idx <- Ms];
        nomatch -> nil
    end.

%%--------------------------------------------------------------------
%% matchers

matcher(Re, S) when is_binary(S) ->
    Key = make_ref(),
    put({clj2_matcher, Key}, {source(pattern(Re)), S, 0, nil}),
    {matcher, nil, Key}.

%% @doc (re-find m): the next match after the previous one
matcher_find({matcher, _, Key}) ->
    {Src, S, Pos, _} = get({clj2_matcher, Key}),
    case Pos =< byte_size(S) andalso
         re:run(S, compiled(Src), [{offset, Pos}, {capture, all, index}]) of
        {match, [{B, L} | _] = Idx0} ->
            Idx = Idx0 ++ lists:duplicate(element(2, compiled_n(Src, search)) + 1 - length(Idx0), {-1, 0}),
            %% an empty match moves on by one character
            Next = case L of
                       0 -> B + next_char(S, B);
                       _ -> B + L
                   end,
            put({clj2_matcher, Key}, {Src, S, Next, Idx}),
            result(S, Idx, length(Idx) - 1);
        _ ->
            put({clj2_matcher, Key}, {Src, S, byte_size(S) + 1, nil}),
            nil
    end.

next_char(S, B) when B < byte_size(S) ->
    <<_:B/binary, C/utf8, _/binary>> = S,
    byte_size(<<C/utf8>>);
next_char(_, _) -> 1.

%% @doc (re-groups m): the groups of the last match
groups({matcher, _, Key}) ->
    case get({clj2_matcher, Key}) of
        {_, S, _, Idx} when Idx =/= nil -> result(S, Idx, length(Idx) - 1);
        _ -> erlang:error(clj2_rt:ex_info(<<"No match found">>, clj2_coll:hash_map_kv([]), nil))
    end.
