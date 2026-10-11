%%%-------------------------------------------------------------------
%%% @doc Lazy seqs and delays (clojerl2-019, designs/03 §5.3 §6).
%%%-------------------------------------------------------------------
-module(clj2_lazy_tests).

-include_lib("eunit/include/eunit.hrl").

%% results are realized (lazy seqs → lists) before comparing
ev(Src) -> clj2_form:from_value(clj2_compiler:eval(list_to_binary(Src))).

lazy_test_() ->
    {setup,
     fun() -> {ok, _} = clj2_core:boot() end,
     fun(_) -> clj2_lazy:set_memo(pdict), clj2_lazy:set_memo_limit(100000) end,
     [ {"infinite seqs", fun infinite/0}
     , {"laziness: nothing beyond what is asked", fun only_what_is_asked/0}
     , {"at most once per process (pdict)", fun at_most_once/0}
     , {"realized? / doall / dorun", fun realized/0}
     , {"delay / force / deref", fun delays/0}
     , {"self-referential lazy-cat", fun fibs/0}
     , {"long chains use constant stack", fun long_chains/0}
     , {"seqs with lazy tails everywhere", fun mixed/0}
     , {"across processes (pdict): once per process", fun cross_process_pdict/0}
     , {"ets memo: exactly once under contention", fun ets_once/0}
     , {"memo store is bounded", fun bounded/0}
     ]}.

infinite() ->
    ?assertEqual([0, 1, 2, 3, 4], ev("(take 5 (range))")),
    ?assertEqual(2, ev("(first (map inc (range 1 1000000000)))")),
    ?assertEqual([1, 2, 4, 8], ev("(take 4 (iterate #(* 2 %) 1))")),
    ?assertEqual([1, 2, 1, 2, 1], ev("(take 5 (cycle [1 2]))")),
    ?assertEqual([x, x, x], ev("(take 3 (repeat 'x))")),
    ?assertEqual([3, 4], ev("(take 2 (drop 3 (range)))")),
    ?assertEqual([0, 1, 2], ev("(take-while #(< % 3) (range))")),
    ?assertEqual([5, 6], ev("(take 2 (drop-while #(< % 5) (range)))")),
    ?assertEqual([1, 2, 3, 4], ev("(take 4 (concat [1 2] (range 3 100) (range)))")),
    ?assertEqual([0, 0, 1, 1], ev("(take 4 (mapcat #(list % %) (range)))")),
    ?assertEqual(true, ev("(= (map inc [1 2]) [2 3])")),
    ?assertEqual({vector, nil, {0, 1, 2}}, ev("(let [[a b & r] (range)] [a b (first r)])")).

only_what_is_asked() ->
    %% a side-effecting producer runs only for the elements taken
    ?assertEqual(3, ev("(do (erlang/put :n 0)
                            (doall (take 3 (map (fn [x] (erlang/put :n (inc (erlang/get :n))) x) (range))))
                            (erlang/get :n))")),
    %% creating a lazy seq runs nothing
    ?assertEqual(0, ev("(do (erlang/put :n 0)
                            (lazy-seq (erlang/put :n 1) nil)
                            (erlang/get :n))")).

at_most_once() ->
    ?assertEqual(1, ev("(do (erlang/put :n 0)
                            (let [s (lazy-seq (erlang/put :n (inc (erlang/get :n))) [1 2])]
                              (doall s) (doall s) (first s) (count s))
                            (erlang/get :n))")),
    %% the elements of a mapped seq are computed once however often it is walked
    ?assertEqual(3, ev("(do (erlang/put :n 0)
                            (let [s (map (fn [x] (erlang/put :n (inc (erlang/get :n))) x) [1 2 3])]
                              (reduce + s) (reduce + s) (vec s))
                            (erlang/get :n))")).

realized() ->
    ?assertEqual({vector, nil, {false, true, nil}}, ev("(let [s (lazy-seq [1])] [(realized? s) (do (doall s) (realized? s)) (dorun s)])")),
    ?assertEqual(3, ev("(count (doall (map inc [1 2 3])))")).

delays() ->
    ?assertEqual({vector, nil, {1, 42, 42, true}}, ev("(do (erlang/put :n 0)
                                          (let [d (delay (erlang/put :n (inc (erlang/get :n))) 42)
                                                a (force d) b @d]
                                            [(erlang/get :n) a b (realized? d)]))")),
    ?assertEqual(7, ev("(force 7)")).

fibs() ->
    {ok, Ns} = clj2_compiler:load_ns(<<"(ns t.fib) (def fibs (lazy-cat [0 1] (map + fibs (rest fibs))))">>),
    try
        ?assertEqual([0, 1, 1, 2, 3, 5, 8, 13, 21, 34], clj2_form:from_value(clj2_compiler:eval(<<"(take 10 t.fib/fibs)">>))),
        %% memoized: linear, so a large index is cheap
        ?assert(is_integer(clj2_compiler:eval(<<"(nth t.fib/fibs 2000)">>)))
    after
        clj2_ns:remove(Ns), code:purge(Ns), code:delete(Ns), code:purge(Ns)
    end.

long_chains() ->
    %% filter skipping a million elements: a chain of lazy seqs realized
    %% iteratively, not by recursion
    {_, Stack0} = erlang:process_info(self(), stack_size),
    ?assertEqual(1000001, ev("(first (filter #(> % 1000000) (range)))")),
    ?assertEqual(500000500000, ev("(reduce + (range 1000001))")),
    {_, Stack1} = erlang:process_info(self(), stack_size),
    ?assert(Stack1 - Stack0 < 1000).

mixed() ->
    ?assertEqual([0, 1, 2], ev("(cons 0 (map inc (range 2)))")),
    ?assertEqual(3, ev("(count (cons 0 (lazy-seq [1 2])))")),
    ?assertEqual(2, ev("(nth (map inc (range)) 1)")),
    ?assertEqual(2, ev("(second (concat (lazy-seq nil) [1 2]))")),
    ?assertEqual([3, 2, 1], ev("(reverse (map inc (range 3)))")),
    ?assertEqual(true, ev("(seq? (map inc [1]))")),
    ?assertEqual(true, ev("(empty? (filter neg? [1 2]))")),
    ?assertEqual({vector, nil, {1, 2}}, ev("(vec (take 2 (iterate inc 1)))")),
    %% a macro returning a lazy seq still yields a proper form
    ?assertEqual(6, ev("(-> 1 (+ 2) (+ 3))")).

%% the registered divergence: pdict memo is per process
cross_process_pdict() ->
    clj2_lazy:set_memo(pdict),
    Self = self(),
    L = clj2_lazy:lazy_seq(fun() -> Self ! ran, [1, 2] end),
    Pids = [spawn(fun() -> Self ! {val, clj2_coll:to_list(L)} end) || _ <- [1, 2, 3]],
    Vals = [receive {val, V} -> V after 5000 -> timeout end || _ <- Pids],
    ?assertEqual([[1, 2], [1, 2], [1, 2]], Vals),          % same value everywhere
    ?assertEqual(3, count_msgs(ran)).                       % realized once per process

%% ets memo: one realization for all processes, even racing
ets_once() ->
    clj2_lazy:set_memo(ets),
    try
        Self = self(),
        L = clj2_lazy:lazy_seq(fun() -> Self ! ran, timer:sleep(20), [1, 2] end),
        _ = [spawn(fun() -> Self ! {val, clj2_coll:to_list(L)} end) || _ <- lists:seq(1, 8)],
        Vals = [receive {val, V} -> V after 5000 -> timeout end || _ <- lists:seq(1, 8)],
        ?assertEqual(lists:duplicate(8, [1, 2]), Vals),
        ?assertEqual(1, count_msgs(ran))
    after
        clj2_lazy:set_memo(pdict)
    end.

%% beyond the limit the store is cleared: memory stays bounded, and a
%% seq walked again after a clear is realized again (registered divergence)
bounded() ->
    clj2_lazy:set_memo(pdict),
    clj2_lazy:set_memo_limit(10),
    try
        Self = self(),
        First = clj2_lazy:lazy_seq(fun() -> Self ! first_ran, [0] end),
        _ = clj2_coll:to_list(First),
        _ = clj2_coll:to_list(clj2_compiler:eval(<<"(doall (map inc (range 50)))">>)),
        Entries = length([K || {{clj2_lazy, _} = K, _} <- get()]),
        ?assert(Entries =< 10),
        _ = clj2_coll:to_list(First),
        ?assertEqual(2, count_msgs(first_ran))
    after
        clj2_lazy:set_memo_limit(100000)
    end.

count_msgs(Tag) ->
    receive Tag -> 1 + count_msgs(Tag) after 100 -> 0 end.
