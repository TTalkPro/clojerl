%%%-------------------------------------------------------------------
%%% @doc Reference types (clojerl2-018, designs/03 §5.2): the internal
%%% cell under concurrent updates, the removed reference types, bindings across
%%% processes, binding conveyance, the STM refusal.
%%%-------------------------------------------------------------------
-module(clj2_ref_tests).

-include_lib("eunit/include/eunit.hrl").

ev(Src) ->
    {ok, _} = clj2_core:ensure(),
    clj2_compiler:eval(unicode:characters_to_binary(Src), #{ns => 't.refs'}).

setup() -> {ok, _} = clj2_core:ensure(), clj2_ns:ensure('t.refs').

%% Clojure sequential values as (nested) Erlang lists, for comparing
plain(X) ->
    case clj2_coll:is_vector(X) orelse is_list(X) orelse (is_tuple(X) andalso element(1, X) =:= lazy_seq) of
        true -> [plain(Y) || Y <- clj2_coll:to_list(X)];
        false -> X
    end.

%% the runtime's internal cell (no Clojure atom): many processes update
%% one cell; no update is lost
cell_concurrent_swap_test() ->
    setup(),
    C = clj2_ref:cell(0),
    Inc = fun(X) -> X + 1 end,
    Procs = 50, Each = 200,
    Self = self(),
    [spawn(fun() -> [clj2_ref:swap(C, Inc, nil) || _ <- lists:seq(1, Each)], Self ! done end)
     || _ <- lists:seq(1, Procs)],
    [receive done -> ok end || _ <- lists:seq(1, Procs)],
    ?assertEqual(Procs * Each, clj2_ref:deref(C)).

%% Clojure's atom is gone (designs/10): state lives in processes
no_atom_test() ->
    setup(),
    {'EXIT', {{clj2_compile, _, {resolve, {unresolved_symbol, atom}}}, _}} = (catch ev("(atom 0)")),
    {'EXIT', {{clj2_compile, _, {resolve, {unresolved_symbol, 'swap!'}}}, _}} = (catch ev("(swap! x inc)")).

%% no future or promise (designs/10): concurrency is Erlang processes
no_future_promise_test() ->
    setup(),
    [?assertMatch({'EXIT', {{clj2_compile, _, {resolve, {unresolved_symbol, S}}}, _}}, (catch ev(Src)))
     || {S, Src} <- [{future, "(future 1)"}, {promise, "(promise)"}, {deliver, "(deliver p 1)"},
                     {'future-call', "(future-call f)"}]],
    %% pmap still runs in parallel processes
    ?assertEqual([2, 3, 4], plain(ev("(pmap inc [1 2 3])"))).

binding_test() ->
    setup(),
    ev("(def ^:dynamic *d* 1)"),
    ?assertEqual([2, 1], plain(ev("[(binding [*d* 2] *d*) *d*]"))),
    ?assertEqual(1, ev("(try (binding [*d* 2] (throw (ex-info \"x\" {}))) (catch Exception e *d*))")),
    ?assertEqual(3, ev("(let [f (binding [*d* 3] (bound-fn [] *d*))] (f))")),
    ?assertEqual(4, ev("(binding [*d* 4] (let [me (erlang/self)] (erlang/spawn (bound-fn [] (erlang/send me *d*))) (clj2_proc/receive_any 1000 :timeout)))")),
    ev("(def plain 1)"),
    ?assertError({'clojure.lang.ExceptionInfo', _, #{':message' := <<"Can't dynamically bind non-dynamic var: t.refs/plain">>}},
                 ev("(binding [plain 2] plain)")).

%% no STM, agents or volatiles either
no_stm_agent_volatile_test() ->
    setup(),
    [?assertMatch({'EXIT', {{clj2_compile, _, {resolve, {unresolved_symbol, S}}}, _}}, (catch ev(Src)))
     || {S, Src} <- [{dosync, "(dosync 1)"}, {ref, "(ref 1)"}, {agent, "(agent 1)"}, {'volatile!', "(volatile! 1)"}]].

%% bugs the corpus showed once side effects could observe them
doseq_bindings_test() ->
    setup(),
    ?assertEqual(4, ev("(let [c (clj2_ref/cell 0)] (doseq [x [1 2] y [10 20]] (clj2_ref/swap c inc nil)) @c)")),
    ?assertEqual([1, 3], plain(ev("(let [a (clj2_ref/cell [])] (doseq [x [1 2 3] :when (odd? x)] (clj2_ref/swap a conj (list x))) @a)"))),
    ?assertEqual(6, ev("(let [a (clj2_ref/cell 0)] (doseq [x (range 10) :while (< x 4)] (clj2_ref/swap a + (list x))) @a)")),
    ?assertEqual([10, 11, 20, 21],
                 plain(ev("(let [a (clj2_ref/cell [])] (doseq [x [1 2] :let [y (* x 10)] z [y (inc y)]] (clj2_ref/swap a conj (list z))) @a)"))),
    ?assertEqual(nil, ev("(doseq [x []] (throw (ex-info \"never\" {})))")).

delay_raises_once_test() ->
    setup(),
    ?assertEqual([1, true], plain(ev("(let [n (clj2_ref/cell 0) d (delay (clj2_ref/swap n inc nil) (throw (ex-info \"e\" {})))] "
                                     "(dotimes [_ 3] (try (deref d) (catch Exception _ nil))) [(deref n) (realized? d)])"))).

