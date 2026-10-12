%%%-------------------------------------------------------------------
%%% @doc BigDecimal (clj2_decimal, clojerl2-037): the module, and the
%%% language through it (literals, contagion, with-precision, printing).
%%%-------------------------------------------------------------------
-module(clj2_decimal_tests).

-include_lib("eunit/include/eunit.hrl").

ev(Src) ->
    {ok, _} = clj2_core:ensure(),
    clj2_compiler:eval(unicode:characters_to_binary(Src), #{ns => 't.decimal'}).

s(B) -> clj2_decimal:to_string(clj2_decimal:parse(B)).
d(B) -> clj2_decimal:parse(B).

to_string_test() ->
    ?assertEqual([<<"1.5">>, <<"1.50">>, <<"1E+3">>, <<"-0.000001">>, <<"1E-7">>, <<"1.23456E-8">>, <<"100">>, <<"0.5">>],
                 [s(X) || X <- [<<"1.5">>, <<"1.50">>, <<"1e3">>, <<"-0.000001">>, <<"0.0000001">>,
                                <<"123.456e-10">>, <<"100">>, <<".5">>]]),
    ?assertEqual(<<"1000">>, clj2_decimal:to_plain_string(d(<<"1e3">>))).

division_test() ->
    D = fun(A, B, MC) -> clj2_decimal:to_string(clj2_decimal:divide(d(A), d(B), MC)) end,
    ?assertEqual(<<"0.125">>, D(<<"1">>, <<"8">>, nil)),
    ?assertEqual(<<"1.00">>, D(<<"1.00">>, <<"1">>, nil)),
    ?assertError({'clojure.lang.ExceptionInfo', _, _}, D(<<"1">>, <<"3">>, nil)),
    ?assertEqual(<<"0.3333333333">>, D(<<"1">>, <<"3">>, {math_context, 10, half_up})),
    ?assertEqual(<<"0.66667">>, D(<<"2">>, <<"3">>, {math_context, 5, half_up})),
    ?assertEqual(<<"3">>, D(<<"6">>, <<"2">>, {math_context, 5, half_up})),
    ?assertEqual(<<"1.0E+3">>, D(<<"999">>, <<"1">>, {math_context, 2, half_up})).

rounding_test() ->
    S = fun(B, N, M) -> clj2_decimal:to_string(clj2_decimal:set_scale(d(B), N, M)) end,
    ?assertEqual([<<"1.00">>, <<"1.01">>, <<"1.00">>, <<"-1.01">>, <<"-1.00">>],
                 [S(<<"1.005">>, 2, 'HALF_EVEN'), S(<<"1.005">>, 2, 'HALF_UP'), S(<<"1.005">>, 2, 'HALF_DOWN'),
                  S(<<"-1.001">>, 2, 'FLOOR'), S(<<"-1.001">>, 2, 'CEILING')]).

language_test() ->
    ?assertEqual(<<"[3.5M 1.50M \"1.5\" 3.75M -3M 2.5 0.125M 0.3333333333M true false true true 1.5M 0.5M]">>,
                 ev("(pr-str [(+ 1.5M 2) 1.50M (str 1.5M) (* 1.5M 2.5M) (- 3M) (+ 1.5M 1.0) (/ 1M 8)"
                    " (with-precision 10 (/ 1M 3)) (= 1.0M 1.00M) (= 1M 1) (== 1M 1) (< 1 1.5M 2)"
                    " (bigdec \"1.5\") (mod -7.5M 2)])")),
    ?assertEqual(':ae', ev("(try (/ 1M 3) (catch ArithmeticException _ :ae))")),
    ?assertEqual(true, ev("(= (hash 1.0M) (hash 1.00M))")),
    ?assertEqual(<<"1.01">>, ev("(format \"%.2f\" 1.005M)")),
    ?assertEqual(<<"1.01M">>, ev("(pr-str (.setScale 1.005M 2 java.math.RoundingMode/HALF_UP))")),
    ?assertEqual(<<"3/2">>, ev("(pr-str (rationalize 1.5M))")).
