%%%-------------------------------------------------------------------
%%% @doc clojure.core/hash and Java hashCodes (clj2_hash): every expected
%%% value is what Clojure 1.12 on the JVM gives.
%%%-------------------------------------------------------------------
-module(clj2_hash_tests).

-include_lib("eunit/include/eunit.hrl").

ev(Src) ->
    {ok, _} = clj2_core:ensure(),
    clj2_compiler:eval(unicode:characters_to_binary(Src), #{ns => 't.hash'}).

setup() -> {ok, _} = clj2_core:ensure(), clj2_ns:ensure('t.hash').

hasheq_test() ->
    setup(),
    ?assertEqual([0, -2123407586, -1386151538, -482876059, 254379989, 1871679806, -1703207563,
                  -427027581, 1073217536, -1075838976, 3, 1231, 1237],
                 clj2_coll:to_list(ev("[(hash nil) (hash :a) (hash :foo/bar) (hash 'a) (hash 'foo/bar) (hash 42) (hash -7)"
                                      " (hash 5000000000000000000) (hash 1.5) (hash -0.5) (hash 1/2) (hash true) (hash false)]"))),
    ?assertEqual([736442005, -2017569654, 736442005, 439094965, -15128758, -15128758, 1772842048,
                  -134480633, -781497396, 156247261],
                 clj2_coll:to_list(ev("[(hash [1 2 3]) (hash []) (hash '(1 2 3)) (hash #{1 2 3}) (hash #{}) (hash {})"
                                      " (hash {:a 1}) (hash {:a [1 #{:x}]}) (hash [:a :b]) (hash (seq [1 2]))]"))),
    ?assertEqual([-2147483648, 2147483647],
                 clj2_coll:to_list(ev("[(hash 9223372036854775808N) (hash -9223372036854775809N)]"))),
    ?assertEqual(true, ev("(= (hash (sorted-map :a 1)) (hash {:a 1}))")).

hash_code_test() ->
    setup(),
    ?assertEqual([-1640531430, -626406081, -1640531527],
                 clj2_coll:to_list(ev("[(hash-combine 0 \"a\") (hash-combine 17 :kw) (hash-combine 0 nil)]"))),
    ?assertEqual(<<"17862">>, ev("(format \"%h\" \"abc\")")).
