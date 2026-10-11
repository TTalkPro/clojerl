%%%-------------------------------------------------------------------
%%% @doc clj2_print — Clojure printing of values (layer 0 for 03-print,
%%% clojerl2-021).
%%%
%%% pr_str(X)    readably, as `pr' (strings quoted and escaped)
%%% print_str(X) as `print' (top-level strings raw; inside collections
%%%              values are still printed readably, as in Clojure)
%%%
%%% Doubles follow Java's Double.toString: plain between 1e-3 and 1e7,
%%% else d.dddEn; always a fraction digit (1.0, 1.0E10).
%%%-------------------------------------------------------------------
-module(clj2_print).

-export([pr_str/1, print_str/1, float_str/1]).

pr_str(X) -> iolist_to_binary(pr(X)).

print_str(B) when is_binary(B) -> B;
print_str(X) -> pr_str(X).

pr(nil) -> <<"nil">>;
pr(true) -> <<"true">>;
pr(false) -> <<"false">>;
pr(A) when is_atom(A) -> atom_to_binary(A);                  % symbols, keywords
pr(I) when is_integer(I) -> integer_to_binary(I);
pr(F) when is_float(F) -> float_str(F);
pr(B) when is_binary(B) -> [$", escape(B), $"];
pr({ratio, N, D}) -> [integer_to_binary(N), $/, integer_to_binary(D)];
pr([]) -> <<"()">>;
pr(L) when is_list(L) -> seq_str(L);
pr({lazy_seq, _, _} = L) -> seq_str(L);
pr({vector, _, T}) when is_tuple(T) -> [$[, join([pr(X) || X <- tuple_to_list(T)], " "), $]];
pr({map, _, M}) when is_map(M) -> map_str(M);
pr({set, _, M}) when is_map(M) -> [<<"#{">>, join([pr(X) || X <- lists:sort(maps:keys(M))], " "), $}];
pr({delay, _, _}) -> <<"#object[clojure.lang.Delay]">>;
pr({clj2_fn, _, _}) -> <<"#object[clojure.lang.AFunction]">>;
pr(F) when is_function(F) -> [<<"#object[">>, io_lib:format("~p", [F]), $]];
pr({Tag, _, M}) when is_atom(Tag), is_map(M) ->              % record
    [$#, atom_to_binary(Tag), map_str(M)];
pr({Tag, _, T}) when is_atom(Tag), is_tuple(T) ->            % deftype
    [<<"#object[">>, atom_to_binary(Tag), $]];
pr(P) when is_pid(P) -> [<<"#object[pid ">>, pid_to_list(P), $]];
pr(X) -> io_lib:format("~p", [X]).

seq_str(L) -> [$(, join([pr(X) || X <- clj2_coll:to_list(L)], " "), $)].

map_str(M) ->
    %% hash maps print in key order: deterministic output
    [${, join([[pr(K), $\s, pr(V)] || {K, V} <- lists:sort(maps:to_list(M))], ", "), $}].

join([], _) -> [];
join([X], _) -> [X];
join([X | Xs], Sep) -> [X, Sep | join(Xs, Sep)].

escape(B) ->
    << <<(case C of
              $" -> <<"\\\"">>;
              $\\ -> <<"\\\\">>;
              $\n -> <<"\\n">>;
              $\t -> <<"\\t">>;
              $\r -> <<"\\r">>;
              _ -> <<C>>
          end)/binary>> || <<C>> <= B >>.

%% Java Double.toString
float_str(F) when F == 0.0 ->
    case <<F/float>> of
        <<1:1, _/bitstring>> -> <<"-0.0">>;
        _ -> <<"0.0">>
    end;
float_str(F) ->
    {Digits, Exp} = shortest(abs(F)),                       % 0.Digits × 10^Exp
    Sign = case F < 0 of true -> <<"-">>; false -> <<>> end,
    A = abs(F),
    Body = case A >= 1.0e-3 andalso A < 1.0e7 of
               true -> plain(Digits, Exp);
               false -> sci(Digits, Exp - 1)
           end,
    iolist_to_binary([Sign, Body]).

%% shortest round-trip digits of a positive float, as {"d1d2...", E}
%% meaning 0.d1d2... × 10^E
shortest(A) ->
    S = float_to_list(A, [short]),
    {Mant, E0} = case string:split(S, "e") of
                     [M, E] -> {M, list_to_integer(E)};
                     [M] -> {M, 0}
                 end,
    {IntPart, FracPart} = case string:split(Mant, ".") of
                              [I, Fr] -> {I, Fr};
                              [I] -> {I, ""}
                          end,
    All = IntPart ++ FracPart,
    Lead = length(IntPart),
    Trimmed = string:trim(All, leading, "0"),
    Shift = length(All) - length(Trimmed),
    D = case string:trim(Trimmed, trailing, "0") of "" -> "0"; T -> T end,
    {D, E0 + Lead - Shift}.

plain(D, E) when E =< 0 -> ["0.", lists:duplicate(-E, $0), D];
plain(D, E) when length(D) =< E -> [D, lists:duplicate(E - length(D), $0), ".0"];
plain(D, E) ->
    {I, Fr} = lists:split(E, D),
    [I, ".", Fr].

sci([D1 | Rest], E) ->
    Frac = case Rest of [] -> "0"; _ -> Rest end,
    [D1, ".", Frac, "E", integer_to_list(E)].
