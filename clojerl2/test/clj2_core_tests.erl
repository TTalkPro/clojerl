%%%-------------------------------------------------------------------
%%% @doc clojure.core layer 00-kernel and its loader (clojerl2-014).
%%%-------------------------------------------------------------------
-module(clj2_core_tests).

-include_lib("eunit/include/eunit.hrl").

%% results are realized (lazy seqs → lists) before comparing
ev(Src) -> clj2_form:from_value(clj2_compiler:eval(list_to_binary(Src))).

load(Src) ->
    {ok, Ns} = clj2_compiler:load_ns(list_to_binary(Src)),
    Ns.

unload(Ns) ->
    clj2_ns:remove(Ns),
    code:purge(Ns), code:delete(Ns), code:purge(Ns).

kernel_test_() ->
    {setup,
     fun() -> {ok, 'clojure.core'} = clj2_core:boot(#{upto => '00-kernel'}) end,
     fun(_) -> ok end,
     [ {"layers are declared", ?_assertEqual(['00-kernel', '01-core', '02-protocols', '03-print', '04-repl'], clj2_core:layers())}
     , {"macros are registered as such",
        ?_assertMatch({ok, #{vars := #{defn := #{macro := true}, 'let' := #{macro := true},
                                       map := #{macro := false, kind := fn}}}},
                      clj2_ns:info('clojure.core'))}
     , {"seqs and colls", fun seqs/0}
     , {"numbers and equality", fun numbers/0}
     , {"strings, symbols, keywords", fun strings/0}
     , {"macros and destructuring", fun macros/0}
     , {"user namespaces refer clojure.core", fun refer/0}
     , {"syntax-quote qualifies core symbols", fun syntax_quote/0}
     ]}.

seqs() ->
    ?assertEqual([2, 3, 4], ev("(map inc [1 2 3])")),
    ?assertEqual([5, 7, 9], ev("(map + [1 2 3] [4 5 6])")),
    ?assertEqual([0, 2, 4], ev("(filter even? (range 6))")),
    ?assertEqual(25, ev("(->> (range 10) (filter odd?) (reduce +))")),
    ?assertEqual(nil, ev("(seq [])")),
    ?assertEqual([], ev("(rest nil)")),
    ?assertEqual(3, ev("(last '(1 2 3))")),
    ?assertEqual({vector, nil, {1, 2, 3}}, ev("(conj [1 2] 3)")),
    ?assertEqual([0, 1, 2], ev("(conj '(1 2) 0)")),
    ?assertEqual({vector, nil, {1, 2}}, ev("(into [] '(1 2))")),
    ?assertEqual(#{':a' => 1, ':b' => 2}, ev("(assoc {:a 1} :b 2)")),
    ?assertEqual(1, ev("(get {:a 1} :a)")),
    ?assertEqual(':none', ev("(get {} :a :none)")),
    ?assertEqual(true, ev("(contains? #{1} 1)")),
    ?assertEqual(3, ev("(count [1 2 3])")),
    ?assertEqual([1, 2, 3], ev("(concat [1] '(2) [3])")),
    ?assertEqual(6, ev("(apply + 1 [2 3])")),
    ?assertEqual(3, ev("((comp inc inc) 1)")),
    ?assertEqual(6, ev("((partial + 1 2) 3)")),
    ?assertEqual(true, ev("(every? pos? [1 2])")),
    ?assertEqual(2, ev("(some #(if (even? %1) %1 nil) [1 2 3])")).

numbers() ->
    ?assertEqual(3628800, ev("(reduce * (range 1 11))")),
    ?assertEqual(-1, ev("(- 1)")),
    ?assertEqual(2, ev("(/ 4 2)")),
    ?assertEqual(0.5, ev("(/ 1 2)")),
    ?assertEqual(true, ev("(< 1 2 3)")),
    ?assertEqual(false, ev("(< 1 3 2)")),
    ?assertEqual(2, ev("(mod -1 3)")),
    ?assertEqual(5, ev("(max 1 5 3)")),
    ?assertEqual(true, ev("(= [1 2] '(1 2))")),
    ?assertEqual(true, ev("(= {:a [1]} {:a '(1)})")),
    ?assertEqual(false, ev("(= 1 1.0)")),
    ?assertEqual(true, ev("(== 1 1.0)")),
    ?assertEqual(true, ev("(not= 1 2)")).

strings() ->
    ?assertEqual(<<"x1:ksym2.5">>, ev("(str \"x\" 1 :k nil 'sym 2.5)")),
    ?assertEqual(':a', ev("(keyword \"a\")")),
    ?assertEqual(<<"b">>, ev("(name :a/b)")),
    ?assertEqual(<<"a">>, ev("(namespace :a/b)")),
    ?assertEqual('x/y', ev("(symbol \"x\" \"y\")")),
    ?assertEqual(true, ev("(symbol? (gensym))")).

macros() ->
    Src = "(ns t.k)
(defn fact [n] (if (zero? n) 1 (* n (fact (dec n)))))
(defn sum [& xs] (apply + xs))
(defn d [[a b & more :as all] {:keys [x y] :or {y 10} :as m}] [a b more x y (count all) (get m :x)])
(defn cls [n] (cond (neg? n) :neg (zero? n) :zero :else :pos))
(defn lp [] (loop [[x & xs] [1 2 3] acc 0] (if x (recur xs (+ acc x)) acc)))
(defn lf [] (letfn [(ev? [n] (if (zero? n) true (od? (dec n)))) (od? [n] (if (zero? n) false (ev? (dec n))))] (ev? 10)))
(defn il [m] (if-let [v (get m :a)] [:found v] :none))
(defn wl [] (when-let [[a] [1]] (str \"a=\" a)))
(defn cs [x] (case x 1 :one (2 3) :few :many))
(defn dt [] (let [k (erlang/make_ref)] (dotimes [i 3] (erlang/put k i)) (erlang/get k)))
(defn ds [] (doseq [[k v] {:a 1}] (erlang/put :ds [k v])) (erlang/get :ds))
(defn th [] (-> {} (assoc :a 1) (assoc :b 2) (dissoc :a)))
(defn strs [{:strs [a] :syms [b]}] [a b])
(defn nested [{[x y] :pt}] (+ x y))
(defn documented \"doc\" [] :doc)
",
    load(Src),
    try
        ?assertEqual(3628800, 't.k':fact(10)),
        ?assertEqual(6, 't.k':sum([1, 2, 3])),
        ?assertEqual({vector, nil, {1, 2, [3, 4], 5, 10, 4, 5}},
                     't.k':d(clj2_coll:vector([1, 2, 3, 4]), clj2_coll:hash_map_kv([':x', 5]))),
        ?assertEqual([':neg', ':zero', ':pos'], [ 't.k':cls(N) || N <- [-1, 0, 5]]),
        ?assertEqual(6, 't.k':lp()),
        ?assertEqual(true, 't.k':lf()),
        ?assertEqual({vector, nil, {':found', 1}}, 't.k':il(clj2_coll:hash_map_kv([':a', 1]))),
        ?assertEqual(':none', 't.k':il(clj2_coll:hash_map_kv([]))),
        ?assertEqual(<<"a=1">>, 't.k':wl()),
        ?assertEqual([':few', ':many'], ['t.k':cs(3), 't.k':cs(9)]),
        ?assertEqual(2, 't.k':dt()),
        ?assertEqual([':a', 1], 't.k':ds()),        % a vector handed to Erlang is a list
        ?assertEqual(#{':b' => 2}, 't.k':th()),
        ?assertEqual({vector, nil, {1, 2}},
                     't.k':strs(clj2_coll:hash_map_kv([<<"a">>, 1, b, 2]))),
        ?assertEqual(3, 't.k':nested(clj2_coll:hash_map_kv([':pt', clj2_coll:vector([1, 2])]))),
        ?assertEqual(':doc', 't.k':documented())
    after
        unload('t.k')
    end.

refer() ->
    %% an own definition shadows the referred core var
    load("(ns t.sh) (defn first [x] :mine) (defn g [] (first [1]))"),
    %% :exclude
    load("(ns t.ex (:refer-clojure :exclude [inc])) (defn inc [x] (- x 1)) (defn g [] (inc 5))"),
    try
        ?assertEqual(':mine', 't.sh':g()),
        ?assertEqual(4, 't.ex':g()),
        %% core vars are directly linked (call_ext to clojure.core)
        {ok, _, _, Bin} = clj2_compiler:compile_ns(<<"(ns t.dl) (defn g [x] (inc x))">>),
        {beam_file, _, _, _, _, Funs} = beam_disasm:file(Bin),
        Code = lists:append([Is || {function, _, _, _, Is} <- Funs]),
        ?assert(lists:any(fun({I, _, {extfunc, 'clojure.core', inc, 1}})
                                when I =:= call_ext; I =:= call_ext_only; I =:= call_ext_last -> true;
                             (_) -> false end, Code))
    after
        unload('t.sh'), unload('t.ex')
    end.

syntax_quote() ->
    ?assertEqual(['clojure.core/map', 'user/x'], ev("`(map x)")),
    ?assertEqual(['clojure.core/let', 'if'], ev("`(let if)")),
    %% macro arguments: #() and syntax-quote are expanded before the macro sees them
    ?assertEqual(2, ev("(when true (#(+ %1 1) 1))")),
    ?assertEqual(['user/a', 1], ev("(let [x 1] (when true `(a ~x)))")).

%%====================================================================
%% Loader and lint (acceptance: lint failures are compile errors)
%%====================================================================

with_fake_core(Edn, Kernel, Fun) ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "clj2_core_tests_" ++ os:getpid()),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "boot-order.edn"), Edn),
    ok = file:write_file(filename:join(Dir, "00-kernel.clj"), Kernel),
    try Fun(Dir)
    after file:del_dir_r(Dir)
    end.

kernel_lint_test() ->
    load("(ns t.lintdep) (def g (fn* [] 1))"),
    try
        Edn = <<"{:ns t.fakecore :layers [{:name :00-kernel :files [\"00-kernel.clj\"] :deps [] :allowed-ns []}]}">>,
        %% referring to another Clojure namespace is rejected...
        with_fake_core(Edn, <<"(ns t.fakecore) (def f (fn* [] (t.lintdep/g)))">>,
                       fun(Dir) ->
                               ?assertError({clj2_compile, _, {lint, {namespace_not_allowed, 't.lintdep'}}},
                                            clj2_core:boot(#{dir => Dir}))
                       end),
        %% ...Erlang modules are fine
        with_fake_core(Edn, <<"(ns t.fakecore) (def f (fn* [] (lists/reverse '(1 2))))">>,
                       fun(Dir) ->
                               ?assertEqual({ok, 't.fakecore'}, clj2_core:boot(#{dir => Dir})),
                               ?assertEqual([2, 1], 't.fakecore':f())
                       end)
    after
        unload('t.lintdep'), unload('t.fakecore')
    end.

boot_order_test() ->
    Edn = <<"{:ns t.fakecore :layers [{:name :00-kernel :files [\"00-kernel.clj\"] :deps [:01-core]}"
            " {:name :01-core :files [] :deps [:00-kernel]}]}">>,
    with_fake_core(Edn, <<"(ns t.fakecore)">>,
                   fun(Dir) ->
                           ?assertError({clj2_boot_order, {'00-kernel', depends_on_later_or_unknown, '01-core'}},
                                        clj2_core:boot(#{dir => Dir}))
                   end).

%% Docstrings become EEP-48 docs in the beam (OTP 27+ -moduledoc/-doc,
%% wild attributes in absform)
docs_chunk_test() ->
    {ok, 'clojure.core'} = clj2_core:boot(),
    {ok, _, _, Bin} = clj2_compiler:compile_ns(
                        <<"(ns t.doc \"A namespace.\") (defn f \"Adds one.\" [x] (inc x)) (def g 1)">>),
    {ok, {_, [{"Docs", D}]}} = beam_lib:chunks(Bin, ["Docs"]),
    {docs_v1, _, _, _, ModDoc, _, Entries} = binary_to_term(D),
    ?assertEqual(#{<<"en">> => <<"A namespace.">>}, ModDoc),
    ?assertMatch([{_, _, _, #{<<"en">> := <<"Adds one.">>}, _}],
                 [E || E = {{function, f, 1}, _, _, _, _} <- Entries]),
    ?assertMatch([{_, _, _, hidden, _}],
                 [E || E = {{function, '__ns_init__', 0}, _, _, _, _} <- Entries]),
    %% and the var keeps it in the registry
    {ok, Ns} = clj2_compiler:load_ns(<<"(ns t.doc2) (defn f \"Adds one.\" [x] (inc x))">>),
    ?assertMatch({ok, #{vars := #{f := #{doc := <<"Adds one.">>}}}}, clj2_ns:info(Ns)),
    clj2_ns:remove(Ns), code:purge(Ns), code:delete(Ns), code:purge(Ns).
