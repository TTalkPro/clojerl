%%%-------------------------------------------------------------------
%%% @doc Multimethods and hierarchies (clojerl2-017, designs/03 §5.1).
%%%-------------------------------------------------------------------
-module(clj2_multi_tests).

-include_lib("eunit/include/eunit.hrl").

ev(Src) ->
    {ok, _} = clj2_core:ensure(),
    clj2_compiler:eval(unicode:characters_to_binary(Src), #{ns => 't.multi'}).

setup() -> {ok, _} = clj2_core:ensure(), clj2_ns:ensure('t.multi').

plain(X) ->
    case clj2_coll:is_vector(X) orelse is_list(X) orelse (is_tuple(X) andalso element(1, X) =:= lazy_seq) of
        true -> [plain(Y) || Y <- clj2_coll:to_list(X)];
        false -> X
    end.

%% acceptance: a defmethod is seen by the next call
incremental_test() ->
    setup(),
    ev("(defmulti inc-area :shape)"),
    ev("(defmethod inc-area :square [s] (* (:side s) (:side s)))"),
    ?assertEqual(9, ev("(inc-area {:shape :square :side 3})")),
    ?assertError({'clojure.lang.ExceptionInfo', _, #{':message' := <<"No method in multimethod 'inc-area' for dispatch value: :circle">>}},
                 ev("(inc-area {:shape :circle :r 1})")),
    ev("(defmethod inc-area :circle [c] (* 3 (:r c) (:r c)))"),
    ?assertEqual(3, ev("(inc-area {:shape :circle :r 1})")),
    ev("(defmethod inc-area :default [_] :other)"),
    ?assertEqual(':other', ev("(inc-area {:shape :tri})")),
    %% a second defmulti keeps the methods (reloading a namespace)
    ev("(defmulti inc-area :shape)"),
    ?assertEqual(9, ev("(inc-area {:shape :square :side 3})")),
    ?assertEqual([':circle', ':default', ':square'], lists:sort(plain(ev("(keys (methods inc-area))")))),
    ev("(remove-method inc-area :default)"),
    ?assertEqual(nil, ev("(get-method inc-area :tri)")).

%% acceptance: a call already running keeps its method; the next one runs
%% the redefinition
two_versions_test() ->
    setup(),
    ev("(defmulti slow identity)"),
    ev("(defmethod slow :x [_] (clj2_proc/receive_any) :old)"),
    MF = ev("slow"),
    Self = self(),
    P = spawn(fun() -> Self ! {done, clj2_rt:invoke(MF, [':x'])} end),
    timer:sleep(30),                                  % P is inside the old method
    ev("(defmethod slow :x [_] :new)"),
    ?assertEqual(':new', ev("(slow :x)")),
    P ! go,
    receive {done, R} -> ?assertEqual(':old', R) end,
    ?assertEqual(':new', ev("(slow :x)")).

%% acceptance: multi-level derive, isa?, prefer-method
hierarchy_test() ->
    setup(),
    ev("(derive ::rect ::shape)"),
    ev("(derive ::square ::rect)"),
    ?assertEqual(true, ev("(isa? ::square ::shape)")),
    ?assertEqual(false, ev("(isa? ::shape ::square)")),
    ?assertEqual(true, ev("(isa? [::square ::rect] [::shape ::shape])")),
    ?assertEqual(lists:sort([':t.multi/rect', ':t.multi/shape']), lists:sort(plain(ev("(seq (ancestors ::square))")))),
    ?assertEqual([':t.multi/rect'], plain(ev("(seq (parents ::square))"))),
    ?assertEqual(lists:sort([':t.multi/rect', ':t.multi/square']), lists:sort(plain(ev("(seq (descendants ::shape))")))),
    ev("(defmulti kind identity)"),
    ev("(defmethod kind ::shape [_] :shape)"),
    ?assertEqual(':shape', ev("(kind ::square)")),
    ev("(defmethod kind ::rect [_] :rect)"),                 % more specific wins
    ?assertEqual(':rect', ev("(kind ::square)")),
    %% two unrelated parents: ambiguous until one is preferred
    ev("(derive ::both ::p1)"), ev("(derive ::both ::p2)"),
    ev("(defmulti amb identity)"),
    ev("(defmethod amb ::p1 [_] :p1)"), ev("(defmethod amb ::p2 [_] :p2)"),
    ?assertError({'clojure.lang.ExceptionInfo', _, #{':message' := <<"Multiple methods in multimethod 'amb'", _/binary>>}},
                 ev("(amb ::both)")),
    ev("(prefer-method amb ::p2 ::p1)"),
    ?assertEqual(':p2', ev("(amb ::both)")),
    ?assertError({'clojure.lang.ExceptionInfo', _, #{':message' := <<"Preference conflict", _/binary>>}},
                 ev("(prefer-method amb ::p1 ::p2)")),
    %% a derive after a call: the cached choice is dropped
    ev("(defmulti late identity)"),
    ev("(defmethod late ::late-parent [_] :parent)"),
    ev("(defmethod late :default [_] :default)"),
    ?assertEqual(':default', ev("(late ::late-child)")),
    ev("(derive ::late-child ::late-parent)"),
    ?assertEqual(':parent', ev("(late ::late-child)")),
    ev("(underive ::late-child ::late-parent)"),
    ?assertEqual(':default', ev("(late ::late-child)")),
    %% derive's contracts
    ?assertError({'clojure.lang.ExceptionInfo', _, #{':message' := <<"Assert failed: (namespace parent)">>}},
                 ev("(derive ::x :unqualified)")),
    ?assertError({'clojure.lang.ExceptionInfo', _, #{':message' := <<"Cyclic derivation", _/binary>>}},
                 ev("(derive ::shape ::square)")).

options_test() ->
    setup(),
    %% a pure hierarchy, through :hierarchy
    ev("(def local-h (-> (make-hierarchy) (derive :dog :animal)))"),
    ev("(defmulti speak identity :hierarchy #'local-h)"),
    ev("(defmethod speak :animal [_] :generic)"),
    ?assertEqual(':generic', ev("(speak :dog)")),
    ?assertEqual(false, ev("(isa? :dog :animal)")),           % not in the global one
    %% a :default dispatch value of one's own
    ev("(defmulti fallback identity :default ::none)"),
    ev("(defmethod fallback ::none [_] :fell-back)"),
    ?assertEqual(':fell-back', ev("(fallback 42)")),
    %% multiple arities, vector dispatch values, multifns as values
    ev("(defmulti pair (fn [a b] [a b]))"),
    ev("(defmethod pair [:x :y] ([a b] :xy))"),
    ?assertEqual(':xy', ev("(pair :x :y)")),
    ?assertEqual([':xy'], plain(ev("(map pair [:x] [:y])"))),
    ?assertEqual(<<"#object[clojure.lang.MultiFn t.multi/pair]">>, ev("(pr-str pair)")).
