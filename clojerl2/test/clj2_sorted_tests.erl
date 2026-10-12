%%%-------------------------------------------------------------------
%%% @doc Sorted maps and sets (clj2_sorted).
%%%-------------------------------------------------------------------
-module(clj2_sorted_tests).

-include_lib("eunit/include/eunit.hrl").

ev(Src) ->
    {ok, _} = clj2_core:ensure(),
    clj2_compiler:eval(unicode:characters_to_binary(Src), #{ns => 't.sorted'}).

pr(Src) -> clj2_print:pr_str(ev(Src)).

setup() -> {ok, _} = clj2_core:ensure(), clj2_ns:ensure('t.sorted').

order_test() ->
    setup(),
    ?assertEqual(<<"{:a 1, :b 2, :c 3}">>, pr("(sorted-map :b 2 :a 1 :c 3)")),
    ?assertEqual(<<"#{1 2 3}">>, pr("(sorted-set 3 1 2 1)")),
    ?assertEqual(<<"{3 :c, 2 :b, 1 :a}">>, pr("(sorted-map-by > 1 :a 3 :c 2 :b)")),
    ?assertEqual(<<"#{3 2 1}">>, pr("(sorted-set-by (fn [a b] (compare b a)) 1 3 2)")),
    ?assertEqual(<<"[1 1]">>, pr("(first (sorted-set [2 1] [1 2] [1 1]))")),
    %% keys that compare equal are one key
    ?assertEqual(<<":x">>, pr("(get (sorted-map 1 :x) 1.0)")).

ops_test() ->
    setup(),
    ?assertEqual(<<"(:a :c)">>, pr("(keys (dissoc (sorted-map :a 1 :b 2 :c 3) :b))")),
    ?assertEqual(<<"#{1 3}">>, pr("(disj (sorted-set 1 2 3) 2)")),
    ?assertEqual(<<"(3 4 5)">>, pr("(subseq (sorted-set 1 2 3 4 5) >= 3)")),
    ?assertEqual(<<"(4 3 2)">>, pr("(rsubseq (sorted-set 1 2 3 4 5) > 1 <= 4)")),
    ?assertEqual(<<"([:b 2] [:a 1])">>, pr("(rseq (sorted-map :a 1 :b 2))")),
    ?assertEqual(true, ev("(= (sorted-map :a 1) {:a 1})")),
    ?assertEqual(true, ev("(= (hash (sorted-set 1 2)) (hash #{1 2}))")),
    ?assertEqual(<<"{}">>, pr("(empty (sorted-map-by > 1 1))")),
    ?assertEqual(<<"(3 2)">>, pr("(keys (assoc (empty (sorted-map-by > 1 1)) 2 2 3 3))")),   % empty keeps the comparator
    %% a larger tree stays ordered and balanced through adds and removes
    ?assertEqual(lists:seq(1, 500, 2),
                 clj2_coll:to_list(ev("(keys (reduce dissoc (into (sorted-map) (map (fn [i] [i i]) (shuffle (range 1 501)))) (range 2 501 2)))"))).
