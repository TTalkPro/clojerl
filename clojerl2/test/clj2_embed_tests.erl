%%%-------------------------------------------------------------------
%%% Embedding (designs/10): the clj2 API, Erlang maps as Clojure maps,
%%% clj2_data conversion, versioned reload (clojerl2-044..047).
%%%-------------------------------------------------------------------
-module(clj2_embed_tests).

-include_lib("eunit/include/eunit.hrl").

load_call_test() ->
    ok = clj2:ensure(),
    ?assertEqual({ok, 'emb.t1'}, clj2:load(<<"(ns emb.t1) (defn f [x] (* 2 x))">>)),
    ?assertEqual({ok, 42}, clj2:call('emb.t1', f, [21])),
    ?assertEqual({ok, 42}, clj2:call('emb.t1', <<"f">>, [21])),
    %% loading again replaces it
    {ok, _} = clj2:load(<<"(ns emb.t1) (defn f [x] (* 3 x))">>),
    ?assertEqual({ok, 63}, clj2:call('emb.t1', f, [21])),
    ?assertEqual({ok, 3}, clj2:eval(<<"(+ 1 2)">>)),
    ok = clj2:unload('emb.t1'),
    ?assertEqual(false, clj2:is_loaded('emb.t1')).

errors_are_data_test() ->
    ok = clj2:ensure(),
    {error, #{kind := syntax, line := 2, column := 1, message := M1}} =
        clj2:load(<<"(ns emb.t2)\n(defn f [x] (undefined-thing x))">>),
    ?assertNotEqual(nomatch, binary:match(M1, <<"undefined-thing">>)),
    ?assertMatch({error, #{kind := read, line := 1}}, clj2:load(<<"(ns emb.t3) (defn f [x] (+ x">>)),
    ?assertMatch({error, #{kind := runtime}}, clj2:load(<<"(ns emb.t4) (throw (ex-info \"boom\" {}))">>)),
    {ok, _} = clj2:load(<<"(ns emb.t5) (defn f [x] (+ x 1))">>),
    ?assertMatch({error, #{kind := runtime, message := _}}, clj2:call('emb.t5', f, [<<"a">>])).

erlang_maps_test() ->
    ok = clj2:ensure(),
    {ok, _} = clj2:load(<<"(ns emb.t6)
(defn edit [body]
  (cond-> body
    (= (get body \"model\") \"gpt-4\") (assoc \"model\" \"gpt-4o\")
    (get-in body [\"messages\" 0 \"content\"]) (assoc \"first\" (get-in body [\"messages\" 0 \"content\"]))))
(defn info [m] [(count m) (sort (keys m)) (contains? m \"model\") (m \"model\") (= m {\"model\" \"x\" \"messages\" []})
                (reduce-kv (fn [n _ _] (inc n)) 0 m) (map? m)])">>),
    Body = #{<<"model">> => <<"gpt-4">>, <<"messages">> => [#{<<"content">> => <<"hi">>}]},
    %% an Erlang map in, an Erlang map out
    ?assertEqual({ok, Body#{<<"model">> => <<"gpt-4o">>, <<"first">> => <<"hi">>}}, clj2:call('emb.t6', edit, [Body])),
    {ok, Info} = clj2:call('emb.t6', info, [#{<<"model">> => <<"x">>, <<"messages">> => []}]),
    ?assertEqual([2, [<<"messages">>, <<"model">>], true, <<"x">>, true, 2, true], clj2_coll:to_list(Info)).

data_conversion_test() ->
    ok = clj2:ensure(),
    {ok, V} = clj2:eval(<<"{:a [1 #{2} (list 3)] \"b\" nil :c/d {:e :f}}">>),
    ?assertEqual(#{<<"a">> => [1, [2], [3]], <<"b">> => null, <<"c/d">> => #{<<"e">> => <<"f">>}},
                 clj2_data:to_erl(V, #{nil => null})),
    {ok, C} = clj2:eval(<<"(erl->clj (clj->erl {:k [1 nil]} {:nil :null}) {:keys :keyword :null :nil :lists :vector})">>),
    ?assertEqual(true, clj2_coll:equals(C, element(2, clj2:eval(<<"{:k [1 nil]}">>)))).

versioned_reload_test() ->
    ok = clj2:ensure(),
    Src = fun(N) -> iolist_to_binary(["(ns emb.v) (defn ver [] ", integer_to_list(N),
                                      ") (defn hold [] (clj2_proc/receive_any) (ver))"]) end,
    {ok, _} = clj2:load(Src(1), #{versioned => true}),
    Self = self(),
    H = spawn(fun() -> {ok, V} = clj2:call('emb.v', hold, []), Self ! {held, V} end),
    timer:sleep(50),
    %% a process still in v1 blocks no later load
    [?assertEqual({ok, 'emb.v'}, clj2:load(Src(N), #{versioned => true})) || N <- [2, 3, 4]],
    ?assertEqual({ok, 4}, clj2:call('emb.v', ver, [])),
    Kept = clj2:gc('emb.v'),
    ?assertEqual(1, length(Kept)),                 % v1: still running
    H ! go,
    receive {held, Held} -> ?assertEqual(1, Held) after 2000 -> error(timeout) end,
    timer:sleep(20),
    ?assertEqual([], clj2:gc('emb.v')),
    ok = clj2:unload('emb.v').
