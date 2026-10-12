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
            Pcre = try java_to_pcre(Src)
                   catch throw:{bad_regex, Why0} -> bad_regex(Src, Why0, 0)
                   end,
            Text = case Mode of
                       search -> Pcre;
                       whole -> <<"(?:", Pcre/binary, ")\\z">>
                   end,
            %% no ucp: \w \d \s \b are ASCII, as in java.util.regex by default
            case re:compile(Text, [unicode]) of
                {ok, MP} ->
                    ets:info(?TAB, size) > ?CACHE_MAX andalso ets:delete_all_objects(?TAB),
                    N = group_count(Src),
                    ets:insert(?TAB, {Key, MP, N}),
                    {MP, N};
                {error, {Why, At}} -> bad_regex(Src, Why, At)
            end
    end.

bad_regex(Src, Why, At) ->
    erlang:error(clj2_rt:ex_info(
                   unicode:characters_to_binary(io_lib:format("Invalid regex ~ts at ~b: ~ts", [Src, At, Why])),
                   clj2_coll:hash_map_kv([':pattern', Src, ':type', ':PatternSyntaxException']), nil)).

%%====================================================================
%% Java regex syntax → PCRE
%%
%% java.util.regex and PCRE agree on most syntax; this rewrites where they
%% differ (behaviour as java.util.regex.Pattern documents it):
%%   \uXXXX and \0ooo (octal)       → \x{...}
%%   \p{Alpha} ... (POSIX, ASCII)     → the ASCII set
%%   \p{javaLowerCase} \p{IsLatin} \p{IsLu} \p{gc=Lu} \p{sc=Latin}
%%                                    → PCRE properties
%%   \p{Name} not a category/POSIX/java name → an error, as in Java
%%   inline flags u d c U (Java)      → dropped
%%   [\w-_]: a - next to a class escape is a literal -
%%   [a[bc]]: a nested class is a union  → flattened
%%   [a-z&&[^aeiou]]: intersection      → (?:(?=[^aeiou])[a-z])
%%   [\b]                              → an error, as in Java
%%====================================================================

java_to_pcre(Src) -> unicode:characters_to_binary(out(unicode:characters_to_list(Src))).

out([]) -> [];
out("\\Q" ++ R) ->                                 % \Q...\E: literal, untouched
    {Quoted, Rest} = quoted(R, []),
    ["\\Q", Quoted, "\\E" | out(Rest)];
out("\\u" ++ R) -> {Cp, Rest} = hex4(R), [hexchar(Cp) | out(Rest)];
out("\\0" ++ R) -> {Cp, Rest} = octal(R), [hexchar(Cp) | out(Rest)];
out("\\p{" ++ R) -> {Prop, Rest} = prop(R, false, false), [Prop | out(Rest)];
out("\\P{" ++ R) -> {Prop, Rest} = prop(R, true, false), [Prop | out(Rest)];
out([$\\, C | R]) -> [$\\, C | out(R)];
out("(?" ++ R) -> {Flags, Rest} = flags(R), ["(?", Flags | out(Rest)];
out("[" ++ R) -> {Class, Rest} = class(R), [Class | out(Rest)];
out([C | R]) -> [C | out(R)].

quoted("\\E" ++ R, Acc) -> {lists:reverse(Acc), R};
quoted([C | R], Acc) -> quoted(R, [C | Acc]);
quoted([], Acc) -> {lists:reverse(Acc), []}.

hex4(R) ->
    {H, Rest} = lists:split(min(4, length(R)), R),
    length(H) =:= 4 andalso lists:all(fun is_hex/1, H) orelse throw({bad_regex, "Illegal Unicode escape sequence"}),
    {list_to_integer(H, 16), Rest}.

%% \0 then one to three octal digits (at most 0377)
octal(R) ->
    {Ds, Rest} = lists:splitwith(fun(C) -> C >= $0 andalso C =< $7 end, R),
    Ds =/= [] orelse throw({bad_regex, "Illegal octal escape sequence"}),
    {Take, Back} = lists:split(min(3, length(Ds)), Ds),
    Take1 = case Take of
                [D1, _, _] when D1 > $3 -> lists:sublist(Take, 2);
                _ -> Take
            end,
    Extra = lists:nthtail(length(Take1), Take),
    {list_to_integer(Take1, 8), Extra ++ Back ++ Rest}.

is_hex(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) orelse (C >= $A andalso C =< $F).

hexchar(Cp) -> "\\x{" ++ integer_to_list(Cp, 16) ++ "}".

%% \p{...}: Neg for \P; InClass: produce class members, not a class
prop(R, Neg, InClass) ->
    {Name, Rest} = case string:split(R, "}") of
                       [N, After] -> {N, After};
                       _ -> throw({bad_regex, "Unclosed character family"})
                   end,
    {prop_text(Name, Neg, InClass), Rest}.

prop_text(Name, Neg, InClass) ->
    case posix(Name) of
        {ok, Set} when InClass, not Neg -> Set;
        {ok, Set} when InClass -> "&&[^" ++ Set ++ "]";            % handled by class/1
        {ok, Set} when Neg -> "[^" ++ Set ++ "]";
        {ok, Set} -> "[" ++ Set ++ "]";
        error -> [$\\, case Neg of true -> $P; false -> $p end, ${, pcre_prop(Name), $}]
    end.

%% POSIX classes are ASCII in Java (without UNICODE_CHARACTER_CLASS)
posix("Lower") -> {ok, "a-z"};
posix("Upper") -> {ok, "A-Z"};
posix("ASCII") -> {ok, "\\x00-\\x7F"};
posix("Alpha") -> {ok, "a-zA-Z"};
posix("Digit") -> {ok, "0-9"};
posix("Alnum") -> {ok, "a-zA-Z0-9"};
posix("Punct") -> {ok, "!-/:-@\\[-`{-~"};
posix("Graph") -> {ok, "!-~"};
posix("Print") -> {ok, " -~"};
posix("Blank") -> {ok, " \\t"};
posix("Cntrl") -> {ok, "\\x00-\\x1F\\x7F"};
posix("XDigit") -> {ok, "0-9a-fA-F"};
posix("Space") -> {ok, " \\t\\n\\x0B\\f\\r"};
posix("javaWhitespace") -> {ok, "\\t-\\r\\x1C-\\x20\\x{1680}\\x{2000}-\\x{2006}\\x{2008}-\\x{200A}\\x{2028}\\x{2029}\\x{205F}\\x{3000}"};
posix("IsHex_Digit") -> {ok, "\\p{Nd}A-Fa-f\\x{FF21}-\\x{FF26}\\x{FF41}-\\x{FF46}"};
posix("IsWhite_Space") -> {ok, "\\t-\\r \\x{85}\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}"};
posix("javaLetterOrDigit") -> {ok, "\\p{L}\\p{Nd}"};
posix(_) -> error.

%% the PCRE name of a Java property
pcre_prop("javaLowerCase") -> "Ll";
pcre_prop("javaUpperCase") -> "Lu";
pcre_prop("javaTitleCase") -> "Lt";
pcre_prop("javaDigit") -> "Nd";
pcre_prop("javaLetter") -> "L";
pcre_prop("javaAlphabetic") -> "L";
pcre_prop("IsAlphabetic") -> "L";
pcre_prop("IsLetter") -> "L";
pcre_prop("IsDigit") -> "Nd";
pcre_prop("IsUppercase") -> "Lu";
pcre_prop("IsLowercase") -> "Ll";
pcre_prop("IsPunctuation") -> "P";
pcre_prop("Is" ++ Rest) ->                                   % IsLu, IsLatin
    case is_category(Rest) of
        true -> Rest;
        false -> Rest                                        % a script name
    end;
pcre_prop(Name) ->
    case string:split(Name, "=") of
        [Key, Value] ->
            case string:lowercase(Key) of
                K when K =:= "gc"; K =:= "general_category" ->
                    is_category(Value) orelse throw({bad_regex, "Unknown character property name {" ++ Name ++ "}"}),
                    Value;
                K when K =:= "sc"; K =:= "script" -> Value;
                _ -> throw({bad_regex, "Unknown Unicode property {name=<" ++ Key ++ ">, value=<" ++ Value ++ ">}"})
            end;
        [_] ->
            is_category(Name) orelse throw({bad_regex, "Unknown character property name {" ++ Name ++ "}"}),
            case Name of "LC" -> "L&"; _ -> Name end
    end.

is_category(N) ->
    lists:member(N, ["L", "Lu", "Ll", "Lt", "Lm", "Lo", "LC", "L&", "M", "Mn", "Mc", "Me",
                     "N", "Nd", "Nl", "No", "P", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
                     "S", "Sm", "Sc", "Sk", "So", "Z", "Zs", "Zl", "Zp",
                     "C", "Cc", "Cf", "Co", "Cs", "Cn"]).

%% (?flags) / (?flags:  — Java's u d c U have no PCRE counterpart here
flags(R) ->
    {Fl, Rest} = lists:splitwith(fun(C) -> lists:member(C, "idmsuxcU-") end, R),
    case Rest of
        [C | _] when C =:= $); C =:= $: ->
            {[F || F <- Fl, not lists:member(F, "udcU")], Rest};
        _ -> {Fl, Rest}                                       % (?= (?<name> ... untouched
    end.

%% A character class: [ already consumed. → {Text, Rest}
class(R0) ->
    {Neg, R1} = case R0 of
                    "^" ++ T -> {true, T};
                    _ -> {false, R0}
                end,
    {Parts, Rest} = class_items(R1, [], [], first),
    %% Parts: a list of intersected operands, each a list of members
    Text = case Parts of
               [Members] -> ["[", neg(Neg), Members, "]"];
               [First | Others] ->
                   Inner = ["(?:", [["(?=[", O, "])"] || O <- Others], "[", First, "])"],
                   case Neg of
                       true -> ["(?:(?!", Inner, ")[\\s\\S])"];
                       false -> Inner
                   end
           end,
    {Text, Rest}.

neg(true) -> "^";
neg(false) -> "".

%% Acc: members of the current operand (reversed); Ops: finished operands
class_items("]" ++ R, Acc, Ops, Pos) when Pos =/= first ->
    {lists:reverse([lists:reverse(Acc) | Ops]), R};
class_items("&&" ++ R, Acc, Ops, _) -> class_items(R, [], [lists:reverse(Acc) | Ops], next);
%% a nested class standing alone as an operand ([a-z&&[^aeiou]]): it is
%% the operand, negation included
class_items("[" ++ R, [], Ops, Pos) when Pos =:= first; Pos =:= next ->
    {Neg, R1} = case R of "^" ++ T -> {true, T}; _ -> {false, R} end,
    {Inner, Rest} = class_items(R1, [], [], first),
    case Inner of
        [M] when Neg -> class_items(Rest, lists:reverse("^" ++ M), Ops, next);
        [M] -> class_items(Rest, lists:reverse(M), Ops, next);
        _ -> throw({bad_regex, "Nested intersected character classes are not supported"})
    end;
class_items("[" ++ R, Acc, Ops, _) ->
    %% a nested class: a union member (negated ones become an operand
    %% intersected with the complement)
    {Neg, R1} = case R of "^" ++ T -> {true, T}; _ -> {false, R} end,
    {Inner, Rest} = class_items(R1, [], [], first),
    case {Neg, Inner} of
        {false, [M]} -> class_items(Rest, lists:reverse(M, Acc), Ops, next);
        _ -> throw({bad_regex, "Nested negated or intersected character classes are not supported"})
    end;
class_items("\\b" ++ _, _, _, _) -> throw({bad_regex, "Illegal/unsupported escape sequence \\b in a class"});
class_items("\\u" ++ R, Acc, Ops, _) -> {Cp, Rest} = hex4(R), class_items(Rest, lists:reverse(hexchar(Cp), Acc), Ops, next);
class_items("\\0" ++ R, Acc, Ops, _) -> {Cp, Rest} = octal(R), class_items(Rest, lists:reverse(hexchar(Cp), Acc), Ops, next);
class_items("\\p{" ++ R, Acc, Ops, _) -> {Prop, Rest} = prop(R, false, true), class_items(Rest, lists:reverse(Prop, Acc), Ops, shorthand);
class_items("\\P{" ++ R, Acc, Ops, _) -> {Prop, Rest} = prop(R, true, true), class_items(Rest, lists:reverse(Prop, Acc), Ops, shorthand);
class_items("\\Q" ++ R, Acc, Ops, _) ->
    {Quoted, Rest} = quoted(R, []),
    Quoted =/= [] orelse throw({bad_regex, "Empty \\Q\\E in a class"}),
    class_items(Rest, lists:reverse(lists:append([[$\\, C] || C <- Quoted]), Acc), Ops, next);
class_items([$\\, C | R], Acc, Ops, _) when C =:= $w; C =:= $W; C =:= $d; C =:= $D; C =:= $s; C =:= $S; C =:= $h; C =:= $H; C =:= $v; C =:= $V ->
    class_items(R, [C, $\\ | Acc], Ops, shorthand);
class_items([$\\, C | R], Acc, Ops, _) -> class_items(R, [C, $\\ | Acc], Ops, next);
%% a - right after a class escape, or right before one, is a literal -
class_items("-" ++ R, Acc, Ops, shorthand) -> class_items(R, [$-, $\\ | Acc], Ops, next);
class_items("-\\" ++ [C | R], Acc, Ops, _) when C =:= $w; C =:= $W; C =:= $d; C =:= $D; C =:= $s; C =:= $S; C =:= $p; C =:= $P ->
    class_items([$\\, C | R], [$-, $\\ | Acc], Ops, next);
class_items([C | R], Acc, Ops, _) -> class_items(R, [C | Acc], Ops, next);
class_items([], _, _, _) -> throw({bad_regex, "Unclosed character class"}).


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
