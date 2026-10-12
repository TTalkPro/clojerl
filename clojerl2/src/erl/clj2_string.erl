%%%-------------------------------------------------------------------
%%% @doc clj2_string — string, char and UUID primitives (clojerl2-020):
%%% the work behind clojure.string and the char/uuid fns of clojure.core.
%%%
%%% Strings are UTF-8 binaries; indices count code points (known
%%% divergence :string/code-point-indexing); chars are code points
%%% (:char/integer). Text is converted only with the unicode module.
%%%-------------------------------------------------------------------
-module(clj2_string).

-export([upper/1, lower/1, capitalize/1, trim/1, triml/1, trimr/1, trim_newline/1,
         is_blank/1, starts_with/2, ends_with/2, includes/2, index_of/3, last_index_of/3,
         reverse/1, join/2, split/3, split_lines/1, replace/4, escape/2, re_quote_replacement/1]).
-export([char/1, is_char/1, char_name/1, char_escape/1]).
-export([random_uuid/0, parse_uuid/1, uuid/1, is_uuid/1]).

chars(S) -> unicode:characters_to_list(S).
bin(Cs) -> unicode:characters_to_binary(Cs).

upper(S) -> bin(string:uppercase(S)).
lower(S) -> bin(string:lowercase(S)).

capitalize(<<>>) -> <<>>;
capitalize(S) ->
    [C | Rest] = chars(S),
    bin([string:uppercase([C]), string:lowercase(Rest)]).

%% Clojure trims Java whitespace (Character/isWhitespace), not just ASCII
%% "\r\n" is one grapheme cluster to the string module, so it is listed
%% as a separator of its own besides \r and \n
trim(S) -> bin(string:trim(S, both, ws())).
triml(S) -> bin(string:trim(S, leading, ws())).
trimr(S) -> bin(string:trim(S, trailing, ws())).
ws() -> [[$\r, $\n] | ws_chars()].
ws_chars() -> " \t\n\r\f\v\x{1C}\x{1D}\x{1E}\x{1F}\x{1680}\x{2000}\x{2001}\x{2002}\x{2003}\x{2004}\x{2005}\x{2006}\x{2008}\x{2009}\x{200A}\x{2028}\x{2029}\x{205F}\x{3000}".

trim_newline(S) -> bin(string:trim(S, trailing, [[$\r, $\n], $\r, $\n])).

is_blank(nil) -> true;
is_blank(S) -> string:trim(S, both, ws()) =:= <<>> orelse string:trim(S, both, ws()) =:= [].

starts_with(S, P) -> binary:longest_common_prefix([S, P]) =:= byte_size(P).
ends_with(S, P) -> binary:longest_common_suffix([S, P]) =:= byte_size(P).
includes(S, P) -> P =:= <<>> orelse binary:match(S, P) =/= nomatch.

%% index-of / last-index-of: code point indices, nil when absent. Value is
%% a string or a char (code point).
index_of(S, V, From) ->
    Cs = chars(S), Vs = needle(V),
    find(lists:nthtail(min(max(From, 0), length(Cs)), Cs), Vs, max(From, 0)).

find(Cs, Vs, I) ->
    case lists:prefix(Vs, Cs) of
        true -> I;
        false when Cs =:= [] -> nil;
        false -> find(tl(Cs), Vs, I + 1)
    end.

last_index_of(S, V, From) ->
    Cs = chars(S), Vs = needle(V),
    Start = case From of
                nil -> length(Cs);
                _ -> min(From, length(Cs))
            end,
    rfind(Cs, Vs, Start).

rfind(_, _, I) when I < 0 -> nil;
rfind(Cs, Vs, I) ->
    case lists:prefix(Vs, lists:nthtail(min(I, length(Cs)), Cs)) of
        true -> I;
        false -> rfind(Cs, Vs, I - 1)
    end.

needle(V) when is_integer(V) -> [V];
needle(V) -> chars(V).

reverse(S) -> bin(lists:reverse(chars(S))).

%% (join sep coll): str of each element, nil as ""
join(Sep, Coll) ->
    bin(lists:join(clj2_rt:str([Sep]), [clj2_rt:str([X]) || X <- clj2_coll:to_list(Coll)])).

%% (split s re limit): Java String.split semantics — trailing empty
%% strings dropped when limit is 0; a positive limit caps the parts; an
%% empty pattern splits into characters
split(S, Re, Limit) ->
    Parts = case clj2_re:source(clj2_re:pattern(Re)) of
                <<>> -> [bin([C]) || C <- chars(S)];
                _ -> split_at(S, Re, Limit)
            end,
    Trimmed = case Limit of
                  0 -> drop_trailing_empty(Parts);
                  _ -> Parts
              end,
    clj2_coll:vector(case Trimmed of [] -> [<<>>]; _ -> Trimmed end).

split_at(S, Re, Limit) ->
    MP = clj2_re:compiled(clj2_re:source(clj2_re:pattern(Re))),
    Ms = case re:run(S, MP, [global, {capture, first, index}]) of
             {match, M} -> [I || [I] <- M];
             nomatch -> []
         end,
    %% a zero-width match at the very start yields no leading empty part
    Ms1 = [M || M = {B, L} <- Ms, not (B =:= 0 andalso L =:= 0)],
    Ms2 = case Limit > 0 of
              true -> lists:sublist(Ms1, Limit - 1);
              false -> Ms1
          end,
    cut(S, 0, Ms2).

cut(S, Pos, []) -> [binary:part(S, Pos, byte_size(S) - Pos)];
cut(S, Pos, [{B, L} | Rest]) -> [binary:part(S, Pos, B - Pos) | cut(S, B + L, Rest)].

drop_trailing_empty(Parts) ->
    lists:reverse(lists:dropwhile(fun(P) -> P =:= <<>> end, lists:reverse(Parts))).

split_lines(S) -> split(S, {regex, nil, <<"\\r?\\n">>}, 0).

%% (replace s match replacement) / replace-first (Which = all | first).
%% match: string, char or pattern; replacement: string (for a pattern,
%% with Java's $1 ${name} \$ syntax), char, or a fn of the match.
replace(S, Match, Repl, Which) when is_binary(Match); is_integer(Match) ->
    M = case Match of
            C when is_integer(C) -> bin([C]);
            B -> B
        end,
    R = case Repl of
            C2 when is_integer(C2) -> bin([C2]);
            B2 -> B2
        end,
    case M of
        %% an empty match is at every position, ends included
        <<>> -> bin([[R, [C]] || C <- chars(S)] ++ [R]);
        _ ->
            Opts = case Which of
                       all -> [global];
                       first -> []
                   end,
            binary:replace(S, M, R, Opts)
    end;
replace(S, Re, Repl, Which) ->
    Src = clj2_re:source(clj2_re:pattern(Re)),
    Opts = case Which of
               all -> [global, {capture, all, index}];
               first -> [{capture, all, index}]
           end,
    Names = clj2_re:group_numbers(Src),
    NGroups = length([K || K <- maps:keys(Names), is_integer(K)]),
    case re:run(S, clj2_re:compiled(Src), Opts) of
        nomatch -> S;
        {match, Ms0} ->
            Ms1 = case Which of
                      all -> Ms0;
                      first -> [Ms0]
                  end,
            Ms = [Idx ++ lists:duplicate(NGroups + 1 - length(Idx), {-1, 0}) || Idx <- Ms1],
            iolist_to_binary(splice(S, 0, Ms, Repl, Names, Src))
    end.

splice(S, Pos, [], _, _, _) -> [binary:part(S, Pos, byte_size(S) - Pos)];
splice(S, Pos, [[{B, L} | _] = Idx | Rest], Repl, Names, Src) ->
    Groups = [case I of {-1, _} -> nil; {GB, GL} -> binary:part(S, GB, GL) end || I <- Idx],
    Out = case Repl of
              R when is_binary(R) -> expand(R, Groups, Names, Src);
              R when is_integer(R) -> bin([R]);
              F -> clj2_rt:str([clj2_rt:invoke(F, [match_value(Groups)])])
          end,
    [binary:part(S, Pos, B - Pos), Out | splice(S, B + L, Rest, Repl, Names, Src)].

match_value([Whole]) -> Whole;
match_value(Groups) -> clj2_coll:vector(Groups).

%% Java replacement syntax: $n, ${name}, \x is x
expand(<<"\\", C/utf8, Rest/binary>>, G, N, Src) -> [<<C/utf8>> | expand(Rest, G, N, Src)];
expand(<<"${", Rest/binary>>, G, N, Src) ->
    [Name, After] = binary:split(Rest, <<"}">>),
    I = case N of
            #{Name := Num} -> Num;
            _ -> erlang:error(clj2_rt:ex_info(<<"No group with name {", Name/binary, "}">>,
                                              clj2_coll:hash_map_kv([]), nil))
        end,
    [nil_empty(lists:nth(I + 1, G)) | expand(After, G, N, Src)];
expand(<<"$", Rest/binary>>, G, N, Src) ->
    {Digits, After} = take_digits(Rest, <<>>),
    Digits =:= <<>> andalso erlang:error(clj2_rt:ex_info(<<"Illegal group reference">>,
                                                         clj2_coll:hash_map_kv([]), nil)),
    I = binary_to_integer(Digits),
    I < length(G) orelse erlang:error(clj2_rt:ex_info(<<"No group ", Digits/binary>>,
                                                      clj2_coll:hash_map_kv([]), nil)),
    [nil_empty(lists:nth(I + 1, G)) | expand(After, G, N, Src)];
expand(<<C/utf8, Rest/binary>>, G, N, Src) -> [<<C/utf8>> | expand(Rest, G, N, Src)];
expand(<<>>, _, _, _) -> [].

take_digits(<<D, Rest/binary>>, Acc) when D >= $0, D =< $9 -> take_digits(Rest, <<Acc/binary, D>>);
take_digits(Rest, Acc) -> {Acc, Rest}.

nil_empty(nil) -> <<>>;
nil_empty(B) -> B.

%% (escape s cmap): each char looked up in cmap (a map or fn of the char)
escape(S, CMap) ->
    bin([case clj2_rt:invoke(CMap, [C]) of
             nil -> [C];
             R -> clj2_rt:str([R])
         end || C <- chars(S)]).

%% a replacement string that inserts s literally
re_quote_replacement(S) ->
    bin([case C of $\\ -> "\\\\"; $$ -> "\\$"; _ -> [C] end || C <- chars(S)]).

%%====================================================================
%% chars
%%====================================================================

%% (char x): a code point; anything else is an error
char(C) when is_integer(C), C >= 0, C =< 16#10FFFF -> C;
char(X) -> erlang:error(clj2_rt:ex_info(<<"Value out of range for char">>,
                                        clj2_coll:hash_map_kv([':value', X]), nil)).

%% (char? x): chars are code points, so any integer that is one
is_char(C) -> is_integer(C) andalso C >= 0 andalso C =< 16#10FFFF.

char_name($\n) -> <<"newline">>;
char_name($\t) -> <<"tab">>;
char_name($\s) -> <<"space">>;
char_name($\b) -> <<"backspace">>;
char_name($\f) -> <<"formfeed">>;
char_name($\r) -> <<"return">>;
char_name(_) -> nil.

char_escape($\n) -> <<"\\n">>;
char_escape($\t) -> <<"\\t">>;
char_escape($\r) -> <<"\\r">>;
char_escape($") -> <<"\\\"">>;
char_escape($\\) -> <<"\\\\">>;
char_escape($\f) -> <<"\\f">>;
char_escape($\b) -> <<"\\b">>;
char_escape(_) -> nil.

%%====================================================================
%% UUIDs: {uuid, nil, <<"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx">>}, lower case
%%====================================================================

random_uuid() ->
    <<A:48, _:4, B:12, _:2, C:62>> = crypto:strong_rand_bytes(16),
    <<U:128>> = <<A:48, 4:4, B:12, 2:2, C:62>>,
    {uuid, nil, format_uuid(U)}.

format_uuid(U) ->
    H = iolist_to_binary(io_lib:format("~32.16.0b", [U])),
    <<P1:8/binary, P2:4/binary, P3:4/binary, P4:4/binary, P5:12/binary>> = H,
    <<P1/binary, $-, P2/binary, $-, P3/binary, $-, P4/binary, $-, P5/binary>>.

%% (parse-uuid s): the uuid, or nil when s is not one; s must be a string
parse_uuid(S) when is_binary(S) ->
    case re:run(S, <<"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$">>) of
        {match, _} -> {uuid, nil, string:lowercase(S)};
        nomatch -> nil
    end;
parse_uuid(X) ->
    erlang:error(clj2_rt:ex_info(<<"parse-uuid takes a string">>, clj2_coll:hash_map_kv([':value', X]), nil)).

%% the #uuid reader literal: an invalid one is an error
uuid(S) ->
    case parse_uuid(S) of
        nil -> erlang:error(clj2_rt:ex_info(<<"Invalid UUID string: ", S/binary>>,
                                            clj2_coll:hash_map_kv([]), nil));
        U -> U
    end.

is_uuid({uuid, _, _}) -> true;
is_uuid(_) -> false.
