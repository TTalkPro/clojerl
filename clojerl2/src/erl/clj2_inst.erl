%%%-------------------------------------------------------------------
%%% @doc clj2_inst — #inst values (clojerl2-039, 053): Erlang time,
%%% an integer of milliseconds since the epoch (UTC), as
%%% erlang:system_time(millisecond) gives it.
%%%
%%% #inst "..." reads RFC 3339 as clojure.instant does:
%%% yyyy[-MM[-dd[THH[:mm[:ss[.fraction]]]]]][Z|(+|-)hh:mm], each field
%%% checked (a February 29 that is not a leap day, hour 24 ... throw).
%%% to_string/1 writes yyyy-MM-ddTHH:mm:ss.SSS-00:00 (it prints as the integer).
%%%-------------------------------------------------------------------
-module(clj2_inst).

-export([parse/1, from_millis/1, millis/1, is_inst/1, to_string/1, now/0]).

-define(EPOCH, 62167219200).          % calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}})

is_inst(Ms) when is_integer(Ms) -> true;
is_inst(_) -> false.

from_millis(Ms) when is_integer(Ms) -> Ms.
millis(Ms) when is_integer(Ms) -> Ms.
now() -> from_millis(erlang:system_time(millisecond)).

%% @doc #inst "2020-01-01T00:00:00Z" → 1577836800000
parse(S) when is_binary(S) ->
    Re = "^([0-9]{4})(?:-([0-9]{2})(?:-([0-9]{2})(?:[Tt]([0-9]{2})(?::([0-9]{2})(?::([0-9]{2})(?:[.]([0-9]+))?)?)?)?)?)?"
         "(?:([Zz])|([-+])([0-9]{2}):([0-9]{2}))?$",
    case re:run(S, Re, [{capture, all_but_first, list}]) of
        {match, G0} ->
            G = G0 ++ lists:duplicate(11 - length(G0), ""),
            [Y, Mo, D, H, Mi, Se, Frac, _Z, OSign, OH, OM] = G,
            Int = fun("", Default) -> Default; (X, _) -> list_to_integer(X) end,
            Year = Int(Y, 0), Month = Int(Mo, 1), Day = Int(D, 1),
            Hour = Int(H, 0), Min = Int(Mi, 0), Sec = Int(Se, 0),
            check(Month >= 1 andalso Month =< 12, S),
            check(calendar:valid_date(Year, Month, Day), S),
            check(Hour =< 23 andalso Min =< 59 andalso Sec =< 59, S),
            Offset = case OSign of
                         "" -> 0;
                         _ ->
                             OffH = Int(OH, 0), OffM = Int(OM, 0),
                             check(OffH =< 23 andalso OffM =< 59, S),
                             Sign = case OSign of "-" -> -1; _ -> 1 end,
                             Sign * (OffH * 3600 + OffM * 60)
                     end,
            Ms = case Frac of
                     "" -> 0;
                     _ -> list_to_integer(string:slice(Frac ++ "00", 0, 3))
                 end,
            Secs = calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {Hour, Min, Sec}}) - ?EPOCH - Offset,
            from_millis(Secs * 1000 + Ms);
        nomatch -> bad(S)
    end;
parse(X) ->
    erlang:error(clj2_rt:ex_info(<<"#inst takes a string">>,
                                 clj2_coll:hash_map_kv([':type', ':RuntimeException', ':value', X]), nil)).

check(true, _) -> ok;
check(false, S) -> bad(S).

bad(S) ->
    erlang:error(clj2_rt:ex_info(<<"Unrecognized date/time syntax: ", S/binary>>,
                                 clj2_coll:hash_map_kv([':type', ':RuntimeException']), nil)).

%% @doc yyyy-MM-ddTHH:mm:ss.SSS-00:00, of an instant
to_string(Ms) when is_integer(Ms) ->
    Secs = Ms div 1000, Rem = Ms rem 1000,
    {S1, R1} = case Rem < 0 of true -> {Secs - 1, Rem + 1000}; false -> {Secs, Rem} end,
    {{Y, Mo, D}, {H, Mi, Se}} = calendar:gregorian_seconds_to_datetime(S1 + ?EPOCH),
    iolist_to_binary(io_lib:format("~4..0b-~2..0b-~2..0bT~2..0b:~2..0b:~2..0b.~3..0b-00:00",
                                   [Y, Mo, D, H, Mi, Se, R1])).
