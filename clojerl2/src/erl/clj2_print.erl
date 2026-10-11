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

%% pr/2 mixes UTF-8 binaries with code-point lists (io_lib output):
%% only unicode:characters_to_binary/1 joins those correctly. A string
%% that is not valid UTF-8 (bytes from outside) is kept byte for byte.
pr_str(X) -> chars(pr(X, true)).

%% print/println: like pr, but strings (at any depth) print bare, as JVM
%% Clojure does with *print-readably* false: (print ["a"]) shows [a].
print_str(X) -> chars(pr(X, false)).

chars(P) ->
    case unicode:characters_to_binary(P) of
        B when is_binary(B) -> B;
        _ -> iolist_to_binary(P)
    end.

%% R: readably (pr) or not (print)
pr(nil, _) -> <<"nil">>;
pr(true, _) -> <<"true">>;
pr(false, _) -> <<"false">>;
pr(A, _) when is_atom(A) -> atom_to_binary(A);               % symbols, keywords
pr(I, _) when is_integer(I) -> integer_to_binary(I);
pr(F, _) when is_float(F) -> float_str(F);
pr(B, true) when is_binary(B) -> [$", escape(B), $"];
pr(B, false) when is_binary(B) -> B;
pr({ratio, N, D}, _) -> [integer_to_binary(N), $/, integer_to_binary(D)];
pr([], _) -> <<"()">>;
pr(L, R) when is_list(L) -> seq_str(L, R);
pr({lazy_seq, _, _} = L, R) -> seq_str(L, R);
pr({vector, _, T}, R) when is_tuple(T) -> [$[, join([pr(X, R) || X <- tuple_to_list(T)], " "), $]];
pr({map, _, M}, R) when is_map(M) -> map_str(M, R);
pr({set, _, M}, R) when is_map(M) -> [<<"#{">>, join([pr(X, R) || X <- lists:sort(maps:keys(M))], " "), $}];
pr({delay, _, _}, _) -> <<"#object[clojure.lang.Delay]">>;
pr({var, _, {Ns, Name}}, _) when is_atom(Ns), is_atom(Name) ->
    [<<"#'">>, atom_to_binary(Ns), $/, atom_to_binary(Name)];
pr({clj2_fn, _, _}, _) -> <<"#object[clojure.lang.AFunction]">>;
pr(F, _) when is_function(F) -> [<<"#object[">>, io_lib:format("~tp", [F]), $]];
pr({Tag, _, M}, R) when is_atom(Tag), is_map(M) ->           % record
    [$#, atom_to_binary(Tag), map_str(M, R)];
pr({Tag, _, T}, _) when is_atom(Tag), is_tuple(T) ->         % deftype
    [<<"#object[">>, atom_to_binary(Tag), $]];
pr(P, _) when is_pid(P) -> [<<"#object[pid ">>, pid_to_list(P), $]];
pr(X, _) -> io_lib:format("~tp", [X]).

seq_str(L, R) -> [$(, join([pr(X, R) || X <- clj2_coll:to_list(L)], " "), $)].

map_str(M, R) ->
    %% hash maps print in key order: deterministic output
    [${, join([[pr(K, R), $\s, pr(V, R)] || {K, V} <- lists:sort(maps:to_list(M))], ", "), $}].

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
