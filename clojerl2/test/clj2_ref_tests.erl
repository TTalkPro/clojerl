%%%-------------------------------------------------------------------
%%% @doc Reference types (clojerl2-018, designs/03 §5.2): atoms under
%%% concurrent swap!, agent ordering, promises and futures across
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

%% acceptance: many processes swap! one atom; no update is lost
atom_concurrent_swap_test() ->
    setup(),
    A = ev("(atom 0)"),
    Inc = ev("(fn [a] (swap! a inc))"),
    Procs = 50, Each = 200,
    Self = self(),
    [spawn(fun() -> [clj2_rt:invoke(Inc, [A]) || _ <- lists:seq(1, Each)], Self ! done end)
     || _ <- lists:seq(1, Procs)],
    [receive done -> ok end || _ <- lists:seq(1, Procs)],
    ?assertEqual(Procs * Each, clj2_ref:deref(A)).

atom_concurrent_maps_test() ->
    setup(),
    %% values that are themselves large: CAS compares versions, not values
    A = ev("(atom {})"),
    Put = ev("(fn [a i] (swap! a assoc i (vec (range 50))))"),
    Self = self(),
    [spawn(fun() -> [clj2_rt:invoke(Put, [A, P * 1000 + I]) || I <- lists:seq(1, 50)], Self ! done end)
     || P <- lists:seq(1, 20)],
    [receive done -> ok end || _ <- lists:seq(1, 20)],
    ?assertEqual(1000, clj2_coll:count(clj2_ref:deref(A))).

atom_ops_test() ->
    setup(),
    ?assertEqual([[1, 2], [2, 9], true, false, 10],
                 plain(ev(
                    "(let [a (atom 1)] [(swap-vals! a inc) (reset-vals! a 9) "
                    "(compare-and-set! a 9 10) (compare-and-set! a 9 11) @a])"))),
    ?assertEqual(':invalid', ev("(let [a (atom 1 :validator pos?)] (try (reset! a -1) (catch Exception e :invalid)))")),
    ?assertEqual(1, ev("(let [a (atom 1 :validator pos?)] (try (swap! a dec) (catch Exception e nil)) @a)")),
    ?assertEqual([[':k', 0, 1], [':k', 1, 5]],
                 plain(ev("(let [log (atom []) a (atom 0)] "
                                         "(add-watch a :k (fn [k r o n] (swap! log conj [k o n]))) "
                                         "(swap! a inc) (reset! a 5) (remove-watch a :k) (reset! a 6) @log)"))),
    %% an atom only read has no row; identity survives copies
    ?assertEqual(true, ev("(let [a (atom 1) b a] (= a b))")),
    ?assertEqual(false, ev("(= (atom 1) (atom 1))")).

%% acceptance: actions run in the order they were sent
agent_order_test() ->
    setup(),
    ?assertEqual(lists:seq(0, 199),
                 plain(ev("(let [g (agent [])] (doseq [i (range 200)] (send g conj i)) (await g) @g)"))),
    %% from several processes: each sender's actions stay in its order
    G = ev("(agent [])"),
    Send = ev("(fn [g p i] (send g conj [p i]))"),
    Self = self(),
    [spawn(fun() -> [clj2_rt:invoke(Send, [G, P, I]) || I <- lists:seq(1, 50)], Self ! done end)
     || P <- lists:seq(1, 5)],
    [receive done -> ok end || _ <- lists:seq(1, 5)],
    true = clj2_ref:await([G], 5000),
    Got = [clj2_coll:vec_to_list(X) || X <- clj2_coll:vec_to_list(clj2_ref:deref(G))],
    ?assertEqual(250, length(Got)),
    [?assertEqual(lists:seq(1, 50), [I || [Q, I] <- Got, Q =:= P]) || P <- lists:seq(1, 5)].

agent_errors_test() ->
    setup(),
    ?assertEqual([true, 5, 5, nil],
                 plain(ev("(let [g (agent 1)] (send g (fn [_] (throw (ex-info \"bad\" {})))) (await g) "
                                         "[(some? (agent-error g)) (restart-agent g 5) @g (agent-error g)])"))),
    %% a failed agent refuses sends
    ?assertEqual(':refused', ev("(let [g (agent 1)] (send g (fn [_] (throw (ex-info \"bad\" {})))) (await g) "
                                "(try (send g inc) :sent (catch Exception e :refused)))")),
    %% :continue mode with a handler keeps going
    ?assertEqual(2, ev("(let [seen (atom 0) g (agent 1 :error-handler (fn [a e] (swap! seen inc)))] "
                       "(send g (fn [_] (throw (ex-info \"bad\" {})))) (send g inc) (await g) (+ @g (dec @seen)))")).

promise_waiters_test() ->
    setup(),
    P = ev("(promise)"),
    Self = self(),
    [spawn(fun() -> Self ! {got, clj2_ref:deref(P)} end) || _ <- lists:seq(1, 10)],
    timer:sleep(20),
    ?assertEqual(P, clj2_ref:deliver(P, 42)),
    ?assertEqual(nil, clj2_ref:deliver(P, 43)),          % delivered once
    ?assertEqual(lists:duplicate(10, 42), [receive {got, V} -> V end || _ <- lists:seq(1, 10)]),
    ?assertEqual(':timeout', ev("(deref (promise) 20 :timeout)")).

future_test() ->
    setup(),
    ?assertEqual(3, ev("@(future (+ 1 2))")),
    ?assertEqual(<<"in future">>, ev("(let [f (future (throw (ex-info \"in future\" {})))] "
                                     "(try @f (catch Exception e (ex-message e))))")),
    ?assertEqual([true, true, true], plain(ev(
        "(let [f (future (clj2_proc/receive_any))] [(future-cancel f) (future-cancelled? f) (future-done? f)])"))),
    ?assertEqual(':slow', ev("(deref (future (clj2_proc/receive_any)) 20 :slow)")).

binding_test() ->
    setup(),
    ev("(def ^:dynamic *d* 1)"),
    ?assertEqual([2, 1], plain(ev("[(binding [*d* 2] *d*) *d*]"))),
    ?assertEqual(1, ev("(try (binding [*d* 2] (throw (ex-info \"x\" {}))) (catch Exception e *d*))")),
    ?assertEqual(2, ev("(binding [*d* 2] @(future *d*))")),             % conveyed to the future
    ?assertEqual(3, ev("(let [f (binding [*d* 3] (bound-fn [] *d*))] (f))")),
    ?assertEqual(4, ev("(let [g (agent 0)] (binding [*d* 4] (send g (fn [_] *d*))) (await g) @g)")),
    ev("(def plain 1)"),
    ?assertError({'clojure.lang.ExceptionInfo', _, #{':message' := <<"Can't dynamically bind non-dynamic var: t.refs/plain">>}},
                 ev("(binding [plain 2] plain)")).

%% acceptance: STM raises, naming the registered divergence
stm_refused_test() ->
    setup(),
    {'EXIT', {{'clojure.lang.ExceptionInfo', _, #{':message' := Msg}}, _}} = (catch ev("(dosync 1)")),
    ?assertNotEqual(nomatch, binary:match(Msg, <<":refs/no-stm">>)).

%% bugs the corpus showed once atoms could observe them
doseq_bindings_test() ->
    setup(),
    ?assertEqual(4, ev("(let [c (atom 0)] (doseq [x [1 2] y [10 20]] (swap! c inc)) @c)")),
    ?assertEqual([1, 3], plain(ev("(let [a (atom [])] (doseq [x [1 2 3] :when (odd? x)] (swap! a conj x)) @a)"))),
    ?assertEqual(6, ev("(let [a (atom 0)] (doseq [x (range 10) :while (< x 4)] (swap! a + x)) @a)")),
    ?assertEqual([10, 11, 20, 21],
                 plain(ev("(let [a (atom [])] (doseq [x [1 2] :let [y (* x 10)] z [y (inc y)]] (swap! a conj z)) @a)"))),
    ?assertEqual(nil, ev("(doseq [x []] (throw (ex-info \"never\" {})))")).

delay_raises_once_test() ->
    setup(),
    ?assertEqual([1, true], plain(ev("(let [n (atom 0) d (delay (swap! n inc) (throw (ex-info \"e\" {})))] "
                                     "(dotimes [_ 3] (try (deref d) (catch Exception _ nil))) [(deref n) (realized? d)])"))).

