%%%-------------------------------------------------------------------
%%% @doc Evidence for every registered divergence (test/known-divergences.edn,
%%% clojerl2-025): one test per id, named after it (`:lazy-seq/no-chunking'
%%% → lazy_seq__no_chunking_test). Each shows clojerl2 doing what the
%%% registry says, where JVM Clojure does otherwise — so a divergence that
%%% quietly goes away fails here and the registry must be updated, as a
%%% stale corpus entry fails `make certify'. clj2_divergences_tests checks
%%% that the ids and these tests match one for one.
%%%-------------------------------------------------------------------
-module(clj2_divergence_evidence_tests).

-include_lib("eunit/include/eunit.hrl").

ev(Src) ->
    {ok, _} = clj2_core:ensure(),
    clj2_compiler:eval(unicode:characters_to_binary(Src), #{ns => 't.evidence'}).

setup_ns() ->
    {ok, _} = clj2_core:ensure(),
    clj2_ns:ensure('t.evidence').

%% JVM: a lazy seq is realized once, whichever thread walks it.
lazy_seq__per_process_realization_test() ->
    setup_ns(),
    Counter = counters:new(1, []),
    persistent_term:put(clj2_evidence_counter, Counter),
    S = ev("(map (fn [x] (counters/add (persistent_term/get 'clj2_evidence_counter) 1 1) x) (list 1 2 3))"),
    Walk = fun() -> clj2_coll:to_list(S) end,
    Walk(), Walk(),
    ?assertEqual(3, counters:get(Counter, 1)),          % memoized within this process
    Self = self(),
    spawn(fun() -> Walk(), Self ! done end),
    receive done -> ok end,
    ?assertEqual(6, counters:get(Counter, 1)).          % realized again in another

%% JVM: memoization is unbounded.
lazy_seq__bounded_memo_test() ->
    setup_ns(),
    Old = clj2_lazy:memo_limit(),
    try
        clj2_lazy:set_memo_limit(4),
        Counter = counters:new(1, []),
        persistent_term:put(clj2_evidence_counter, Counter),
        S = ev("(map (fn [x] (counters/add (persistent_term/get 'clj2_evidence_counter) 1 1) x) (range 10))"),
        clj2_coll:to_list(S),
        clj2_coll:to_list(S),
        ?assert(counters:get(Counter, 1) > 10)          % the cleared memo realized again
    after
        clj2_lazy:set_memo_limit(Old)
    end.

%% JVM: map over a vector realizes a chunk of 32 for the first element.
lazy_seq__no_chunking_test() ->
    setup_ns(),
    Counter = counters:new(1, []),
    persistent_term:put(clj2_evidence_counter, Counter),
    ev("(first (map (fn [x] (counters/add (persistent_term/get 'clj2_evidence_counter) 1 1) x) (vec (range 100))))"),
    ?assertEqual(1, counters:get(Counter, 1)).

%% JVM: metadata on a def name reaches the var also through macros
%% (defn- is private). clojerl2: only when written on `def' itself.
symbol__no_metadata_test() ->
    setup_ns(),
    ev("(defn- via-macro [] 1)"),
    ev("(def ^:private direct 1)"),
    {ok, #{vars := #{'via-macro' := V1, direct := V2}}} = clj2_ns:info('t.evidence'),
    ?assertEqual(false, maps:get(private, V1)),
    ?assertEqual(true, maps:get(private, V2)).

%% JVM: \a is a java.lang.Character.
char__integer_test() ->
    setup_ns(),
    ?assertEqual(97, ev("\\a")),
    ?assertEqual(true, ev("(integer? \\a)")).

%% JVM: (count "😀") is 2 (UTF-16 units) and nth is O(1).
string__code_point_indexing_test() ->
    setup_ns(),
    ?assertEqual(1, ev("(count \"😀\")")),
    ?assertEqual(16#1F600, ev("(nth \"a😀b\" 1)")),
    ?assertEqual(<<"文"/utf8>>, ev("(subs \"中文字\" 1 2)")).

%% JVM: (/ 1 2) is the ratio 1/2.
number__no_ratio_arithmetic_test() ->
    setup_ns(),
    ?assertEqual(0.5, ev("(/ 1 2)")).

%% JVM: Long overflow throws, 0.0 = -0.0, comparisons type-check.
number__beam_semantics_test() ->
    setup_ns(),
    ?assertEqual(9223372036854775808, ev("(+ 9223372036854775807 1)")),
    ?assertEqual(false, ev("(= 0.0 -0.0)")),
    ?assertError(badarith, ev("(/ 1.0 0)")),
    %% no type check: Erlang term order (numbers before atoms), no throw
    ?assertEqual(false, ev("(< nil 1)")).

%% JVM: an ArityException when the call runs.
fn__arity_at_compile_time_test() ->
    setup_ns(),
    ev("(defn one-arg [x] x)"),
    ?assertError({clj2_compile, _, {link, {arity, _, 'one-arg', 2}}}, ev("(fn [] (one-arg 1 2))")).

%% JVM: each evaluation of a fn form is a distinct object.
fn__structural_identity_test() ->
    setup_ns(),
    ?assertEqual(true, ev("(let [mk (fn [] (fn [x] x))] (identical? (mk) (mk)))")).

%% JVM: catch names a Throwable class.
exceptions__erlang_classes_test() ->
    setup_ns(),
    ?assertEqual(':caught', ev("(try (erlang/exit :bye) (catch :exit e :caught))")),
    ?assertEqual(':any', ev("(try (/ 1 0) (catch Exception e :any))")),
    ?assertError({clj2_compile, _, {syntax, {bad_catch_class, 'ArithmeticException'}}},
                 ev("(try (/ 1 0) (catch ArithmeticException e :x))")),
    %% a future's exception comes back as itself, not wrapped
    ?assertEqual(<<"inner">>, ev("(try @(future (throw (ex-info \"inner\" {}))) (catch Exception e (ex-message e)))")).

%% JVM: extend-type takes classes and interfaces; reify exists.
protocols__type_designators_test() ->
    setup_ns(),
    ev("(defprotocol Kind (kind [x]))"),
    ev("(extend-type integer Kind (kind [_] :int))"),
    ?assertEqual(':int', ev("(kind 1)")),
    ?assertError({clj2_compile, _, {resolve, {unresolved_symbol, reify}}},
                 ev("(reify Kind (kind [_] :r))")).

%% JVM: redefinition is seen by every holder of the var's value at once.
namespaces__hot_code_two_versions_test() ->
    setup_ns(),
    ev("(defn hv [] 1)"),
    ev("(def held hv)"),
    ev("(defn hv [] 2)"),
    ?assertEqual(1, ev("(held)")),                       % the old version's code
    ?assertEqual(2, ev("(hv)")).

%% JVM: *ns* is a clojure.lang.Namespace object, printed #namespace[...].
namespaces__symbols_test() ->
    setup_ns(),
    in_ns('t.evidence', fun() ->
                                ?assertEqual('t.evidence', ev("*ns*")),
                                ?assertEqual(true, ev("(symbol? *ns*)"))
                        end).

%% switch this process's *ns* for the duration of F (tests share a process)
in_ns(Ns, F) ->
    Saved = clj2_rt_eval:save_ns(),
    clj2_rt_eval:in_ns(Ns),
    try F() after clj2_rt_eval:restore_ns(Saved) end.

%% JVM: binding conveyance to future/agent threads; root changes are
%% global. clojerl2: a dynamic binding is this process's only.
dynamic__per_process_bindings_test() ->
    setup_ns(),
    Self = self(),
    in_ns('t.evidence', fun() ->
                                spawn(fun() -> Self ! {ns, clj2_rt_eval:current_ns()} end),
                                receive {ns, Other} -> ?assertEqual(user, Other) end
                        end).

%% JVM: refs and dosync work.
refs__no_stm_test() ->
    setup_ns(),
    ?assertError({'clojure.lang.ExceptionInfo', _, #{':message' := <<"dosync: ", _/binary>>}},
                 ev("(dosync 1)")),
    ?assertError({'clojure.lang.ExceptionInfo', _, _}, ev("(ref 1)")).

%% JVM: an unreachable atom is garbage collected.
state__explicit_lifetime_test() ->
    setup_ns(),
    Before = ets:info(clj2_atom, size),
    Self = self(),
    spawn(fun() -> ev("(swap! (atom 0) inc)"), Self ! done end),
    receive done -> ok end,
    erlang:garbage_collect(),
    ?assertEqual(Before + 1, ets:info(clj2_atom, size)),       % the row outlives every reference
    V = ev("(volatile! 1)"),
    spawn(fun() -> Self ! {other, catch clj2_ref:deref(V)} end),
    receive {other, R} -> ?assertMatch({'EXIT', {{clj2_volatile_of_another_process, _}, _}}, R) end.

%% JVM: shutdown-agents makes later sends throw.
agents__process_per_agent_test() ->
    setup_ns(),
    ?assertEqual(2, ev("(let [g (agent 1)] (shutdown-agents) (send g inc) (await g) @g)")).

%% JVM: identical? and compare-and-set! compare object identity.
values__no_identity_test() ->
    setup_ns(),
    ?assertEqual(true, ev("(identical? [1 2] (vector 1 2))")),
    ?assertEqual(true, ev("(compare-and-set! (atom [1]) [1] [2])")).

