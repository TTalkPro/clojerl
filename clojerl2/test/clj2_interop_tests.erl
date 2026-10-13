%%%-------------------------------------------------------------------
%%% Erlang concurrency and data (designs/10, clojerl2-050..052):
%%% receive, vectors handed to Erlang as lists, maps as Erlang maps.
%%%-------------------------------------------------------------------
-module(clj2_interop_tests).

-include_lib("eunit/include/eunit.hrl").

ev(Src) -> {ok, V} = clj2:eval(Src), V.

setup() -> ok = clj2:ensure().

maps_are_erlang_maps_test() ->
    setup(),
    ?assertEqual(#{':a' => 1, <<"b">> => [1, 2]}, ev(<<"{:a 1 \"b\" (list 1 2)}">>)),
    ?assertEqual(#{':a' => 2}, ev(<<"(update {:a 1} :a inc)">>)),
    %% metadata wraps it; without metadata it is plain again
    ?assertEqual(#{':a' => 1}, ev(<<"(with-meta (with-meta {:a 1} {:m 1}) nil)">>)),
    ?assertEqual(true, ev(<<"(= {:a 1} (with-meta {:a 1} {:m 1}))">>)),
    ?assertEqual(<<"b">>, ev(<<"(maps/get :a {:a \"b\"})">>)).

vectors_become_lists_test() ->
    setup(),
    ?assertEqual([3, 2, 1], ev(<<"(lists/reverse [1 2 3])">>)),
    ?assertEqual(2, ev(<<"(erlang/length [1 2])">>)),
    %% deeply, inside maps and lists; a map with metadata is plain
    ?assertEqual(#{<<"k">> => [[1, 2]]}, ev(<<"(maps/merge {} (with-meta {\"k\" [[1 2]]} {:m 1}))">>)),
    %% the standard library keeps its own values
    ?assertEqual(true, ev(<<"(vector? (first (reverse [[1 2]])))">>)).

receive_test() ->
    setup(),
    Self = self(),
    %% tuples from Erlang, vectors from Clojure: a vector pattern takes both
    Self ! {ok, 1},
    ?assertEqual([':got', 1], clj2_coll:to_list(ev(<<"(receive ['ok x] [:got x] (after 100 :timeout))">>))),
    ?assertEqual([':greeted', <<"w">>],
                 clj2_coll:to_list(ev(<<"(do (erlang/send (erlang/self) [:hello \"w\"]) (receive [:hello who] [:greeted who] (after 100 :timeout)))">>))),
    %% selective: a message no pattern takes stays
    Self ! noise,
    Self ! {data, 7},
    ?assertEqual(7, ev(<<"(receive ['data n] n (after 100 :timeout))">>)),
    ?assertEqual(':left', ev(<<"(receive 'noise :left (after 100 :timeout))">>)),
    %% maps, repeated variables, pins, wildcard, timeout
    Self ! #{<<"type">> => <<"e">>, <<"n">> => 3},
    ?assertEqual(30, ev(<<"(receive {\"type\" \"e\" \"n\" n} (* n 10) _ :other (after 100 :timeout))">>)),
    Self ! {1, 1},
    ?assertEqual(':same', ev(<<"(receive [a a] :same [a b] :diff (after 100 :timeout))">>)),
    Self ! {n, 8}, Self ! {n, 7},
    ?assertEqual(':seven', ev(<<"(let [want 7] (receive ['n ~want] :seven (after 100 :timeout)))">>)),
    ?assertEqual(8, ev(<<"(receive ['n x] x (after 100 :timeout))">>)),
    ?assertEqual(':empty', ev(<<"(receive (after 10 :empty))">>)).

receive_server_test() ->
    setup(),
    {ok, _} = clj2:load(<<"(ns interop.counter)
(defn counter [n]
  (receive ['inc] (recur (inc n))
           ['get from] (do (erlang/send from n) (recur n))
           ['stop] n))">>),
    ?assertEqual(2, ev(<<"(let [me (erlang/self) pid (erlang/spawn (fn [] (interop.counter/counter 0)))]
  (erlang/send pid ['inc]) (erlang/send pid ['inc]) (erlang/send pid ['get me])
  (receive x x (after 1000 :timeout)))">>)).
