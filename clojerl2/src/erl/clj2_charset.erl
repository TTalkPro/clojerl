%%%-------------------------------------------------------------------
%%% @doc clj2_charset — named charsets for (String. bytes charset),
%%% .getBytes, URLEncoder/URLDecoder (clojerl2-041).
%%%
%%% Bytes are the integers of a byte array (signed or not: band 255).
%%% Decoding replaces malformed input with U+FFFD the way the JVM's
%%% decoders do: for UTF-8 one replacement per maximal valid prefix of a
%%% sequence, so an overlong C0 AF is two, E0 80 AF three, and a UTF-8
%%% encoded surrogate (ED A0 80) one; a BOM is kept as U+FEFF. Charsets:
%%% UTF-8, ISO-8859-1, US-ASCII, windows-1252, UTF-16 (BE, LE, and with
%%% a BOM), ISO-2022-JP's ASCII set. Any other name is java.io.UnsupportedEncodingException.
%%%-------------------------------------------------------------------
-module(clj2_charset).

-export([decode/2, encode/2, canonical/1]).

-define(REPL, 16#FFFD).

%% @doc bytes → string in charset Cs (a name, as a string)
decode(Bytes, Cs) ->
    Bs = [B band 255 || B <- Bytes],
    Cps = case canonical(Cs) of
              utf8 -> utf8(Bs);
              latin1 -> Bs;
              ascii -> [case B < 128 of true -> B; false -> ?REPL end || B <- Bs];
              cp1252 -> [cp1252(B) || B <- Bs];
              utf16 -> utf16(Bs, be, true);
              utf16be -> utf16(Bs, be, false);
              utf16le -> utf16(Bs, le, false);
              iso2022jp -> [case B < 128 andalso B =/= 27 of true -> B; false -> ?REPL end || B <- Bs]
          end,
    unicode:characters_to_binary(Cps).

%% @doc string → byte values (0..255) in charset Cs; a character the
%% charset has no byte for is `?', as String.getBytes makes it
encode(S, Cs) when is_binary(S) ->
    Cps = unicode:characters_to_list(S),
    case canonical(Cs) of
        utf8 -> binary_to_list(S);
        latin1 -> [case C < 256 of true -> C; false -> $? end || C <- Cps];
        ascii -> [case C < 128 of true -> C; false -> $? end || C <- Cps];
        cp1252 -> [cp1252_byte(C) || C <- Cps];
        utf16 -> [16#FE, 16#FF | binary_to_list(unicode:characters_to_binary(S, utf8, {utf16, big}))];
        utf16be -> binary_to_list(unicode:characters_to_binary(S, utf8, {utf16, big}));
        utf16le -> binary_to_list(unicode:characters_to_binary(S, utf8, {utf16, little}));
        %% only its ASCII set: the JIS X 0208 tables are not carried
        iso2022jp ->
            [case C < 128 of
                 true -> C;
                 false -> clj2_jvm:throw_new('java.lang.UnsupportedOperationException',
                                             [<<"ISO-2022-JP: only ASCII is supported">>])
             end || C <- Cps]
    end.

%% @doc a charset name (any case, the JVM's aliases) → its decoder
canonical(Cs) ->
    Name = string:uppercase(to_name(Cs)),
    case Name of
        _ when Name =:= <<"UTF-8">>; Name =:= <<"UTF8">> -> utf8;
        _ when Name =:= <<"ISO-8859-1">>; Name =:= <<"ISO8859-1">>; Name =:= <<"ISO_8859_1">>;
               Name =:= <<"LATIN1">>; Name =:= <<"ISO-LATIN-1">>; Name =:= <<"8859_1">> -> latin1;
        _ when Name =:= <<"US-ASCII">>; Name =:= <<"ASCII">> -> ascii;
        _ when Name =:= <<"WINDOWS-1252">>; Name =:= <<"CP1252">> -> cp1252;
        <<"UTF-16">> -> utf16;
        _ when Name =:= <<"UTF-16BE">>; Name =:= <<"UNICODEBIGUNMARKED">> -> utf16be;
        _ when Name =:= <<"UTF-16LE">>; Name =:= <<"UNICODELITTLEUNMARKED">> -> utf16le;
        _ when Name =:= <<"ISO-2022-JP">>; Name =:= <<"CSISO2022JP">> -> iso2022jp;
        _ -> clj2_jvm:throw_new('java.io.UnsupportedEncodingException', [to_name(Cs)])
    end.

to_name(B) when is_binary(B) -> B;
to_name({'java.nio.charset.Charset', _, Name}) -> Name;
to_name(A) when is_atom(A) -> atom_to_binary(A);
to_name(X) -> clj2_rt:str([X]).

%%--------------------------------------------------------------------
%% UTF-8
%%--------------------------------------------------------------------

utf8([]) -> [];
utf8([B | Rest]) when B < 16#80 -> [B | utf8(Rest)];
utf8([B | Rest]) when B >= 16#C2, B =< 16#DF -> seq(Rest, 1, B band 16#1F, {16#80, 16#BF});
utf8([16#E0 | Rest]) -> seq(Rest, 2, 0, {16#A0, 16#BF});
utf8([16#ED, B2, B3 | Rest]) when B2 >= 16#A0, B2 =< 16#BF, B3 >= 16#80, B3 =< 16#BF ->
    [?REPL | utf8(Rest)];                       % an encoded surrogate: one replacement
utf8([16#ED | Rest]) -> seq(Rest, 2, 16#D, {16#80, 16#9F});
utf8([B | Rest]) when B >= 16#E1, B =< 16#EF -> seq(Rest, 2, B band 16#0F, {16#80, 16#BF});
utf8([16#F0 | Rest]) -> seq(Rest, 3, 0, {16#90, 16#BF});
utf8([B | Rest]) when B >= 16#F1, B =< 16#F3 -> seq(Rest, 3, B band 16#07, {16#80, 16#BF});
utf8([16#F4 | Rest]) -> seq(Rest, 3, 4, {16#80, 16#8F});
utf8([_ | Rest]) -> [?REPL | utf8(Rest)].       % a stray continuation, C0, C1, F5..FF

%% N continuation bytes to come, the first within {Lo, Hi}; a sequence cut
%% short is one replacement and decoding resumes at the offending byte
seq([B | Rest], N, Acc, {Lo, Hi}) when B >= Lo, B =< Hi ->
    case N of
        1 -> [(Acc bsl 6) bor (B band 16#3F) | utf8(Rest)];
        _ -> seq(Rest, N - 1, (Acc bsl 6) bor (B band 16#3F), {16#80, 16#BF})
    end;
seq(Rest, _, _, _) -> [?REPL | utf8(Rest)].

%%--------------------------------------------------------------------
%% UTF-16
%%--------------------------------------------------------------------

utf16([16#FE, 16#FF | Rest], _, true) -> utf16(Rest, be, false);
utf16([16#FF, 16#FE | Rest], _, true) -> utf16(Rest, le, false);
utf16(Bs, Order, _) -> units(pairs(Bs, Order)).

pairs([A, B | Rest], be) -> [(A bsl 8) bor B | pairs(Rest, be)];
pairs([A, B | Rest], le) -> [(B bsl 8) bor A | pairs(Rest, le)];
pairs([_], _) -> [bad];
pairs([], _) -> [].

units([H, L | Rest]) when H >= 16#D800, H =< 16#DBFF, L >= 16#DC00, L =< 16#DFFF ->
    [16#10000 + ((H - 16#D800) bsl 10) + (L - 16#DC00) | units(Rest)];
units([U | Rest]) when is_integer(U), (U < 16#D800 orelse U > 16#DFFF) -> [U | units(Rest)];
units([_ | Rest]) -> [?REPL | units(Rest)];
units([]) -> [].

%%--------------------------------------------------------------------
%% windows-1252
%%--------------------------------------------------------------------

cp1252(B) when B < 16#80; B > 16#9F -> B;
cp1252(B) -> element(B - 16#80 + 1, cp1252_high()).

cp1252_high() ->
    {16#20AC, ?REPL, 16#201A, 16#0192, 16#201E, 16#2026, 16#2020, 16#2021,
     16#02C6, 16#2030, 16#0160, 16#2039, 16#0152, ?REPL, 16#017D, ?REPL,
     ?REPL, 16#2018, 16#2019, 16#201C, 16#201D, 16#2022, 16#2013, 16#2014,
     16#02DC, 16#2122, 16#0161, 16#203A, 16#0153, ?REPL, 16#017E, 16#0178}.

cp1252_byte(C) when C < 16#80; C >= 16#A0, C < 16#100 -> C;
cp1252_byte(C) ->
    case [I || {I, X} <- lists:zip(lists:seq(16#80, 16#9F), tuple_to_list(cp1252_high())), X =:= C] of
        [B | _] when C =/= ?REPL -> B;
        _ -> $?
    end.
