%%%-------------------------------------------------------------------
%%% @doc Protocols, deftype, defrecord (clojerl2-016, designs/03 §4).
%%%-------------------------------------------------------------------
-module(clj2_proto_tests).

-include_lib("eunit/include/eunit.hrl").

load(Src) ->
    {ok, Ns} = clj2_compiler:load_ns(list_to_binary(Src)),
    Ns.

unload(Ns) ->
    clj2_ns:remove(Ns),
    code:purge(Ns), code:delete(Ns), code:purge(Ns).

unload_impl(Mod) -> code:purge(Mod), code:delete(Mod), code:purge(Mod).

ev(Src, Ns) -> clj2_compiler:eval(list_to_binary(Src), #{ns => Ns}).

-define(SHAPES,
        "(ns t.shapes)
(defprotocol Shape \"shapes\" (area [s]) (scale [s k]))
(deftype Sq [side] Shape (area [_] (* side side)) (scale [this k] (->Sq (* side k))))
(defrecord Circle [r] Shape (area [c] (* 3 r r)) (scale [c k] (assoc c :r (* r k))))
(extend-type vector Shape (area [v] (count v)) (scale [v k] (vec (map #(* k %) v))))
(extend-protocol Shape
  nil (area [_] 0) (scale [_ _] nil)
  string (area [s] (count s)) (scale [s _] s))
(defn total [shapes] (reduce + (map area shapes)))
;; a param shadows a field of the same name
(deftype Shadow [x] Shape (area [_] x) (scale [_ x] x))
").

setup() ->
    {ok, _} = clj2_core:boot(),
    load(?SHAPES).

cleanup(_) ->
    unload('t.shapes'),
    [unload_impl(M) || M <- ['t.shapes.Shape__t.shapes.Sq', 't.shapes.Shape__t.shapes.Circle',
                             't.shapes.Shape__vector', 't.shapes.Shape__nil',
                             't.shapes.Shape__string', 't.shapes.Shape__t.shapes.Shadow']].

protocols_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [ {"deftype / defrecord / built-in types",
        fun() ->
                E = fun(S) -> ev(S, 't.shapes') end,
                ?assertEqual(9, E("(area (->Sq 3))")),
                ?assertEqual(36, E("(area (scale (->Sq 3) 2))")),
                ?assertEqual(12, E("(area (->Circle 2))")),
                ?assertEqual(10, E("(:r (scale (->Circle 2) 5))")),
                ?assertEqual(3, E("(area [1 2 3])")),
                ?assertEqual({vector, nil, {10, 20}}, E("(scale [1 2] 10)")),
                ?assertEqual(0, E("(area nil)")),
                ?assertEqual(5, E("(area \"hello\")")),
                ?assertEqual(9, E("(total [(->Sq 2) [1 1] nil (->Circle 1)])")),
                ?assertEqual(7, E("(scale (->Shadow 1) 7)")),
                ?assertEqual(1, E("(area (->Shadow 1))"))
        end}
     , {"records are maps",
        fun() ->
                E = fun(S) -> ev(S, 't.shapes') end,
                ?assertEqual(true, E("(= (->Circle 1) (map->Circle {:r 1}))")),
                ?assertEqual(1, E("(get (->Circle 1) :r)")),
                ?assertEqual(2, E("(:x (assoc (->Circle 1) :x 2))")),
                ?assertEqual(true, E("(record? (->Circle 1))")),
                ?assertEqual(false, E("(record? (->Sq 1))"))
        end}
     , {"type predicates",
        fun() ->
                E = fun(S) -> ev(S, 't.shapes') end,
                ?assertEqual('t.shapes.Sq', E("(type (->Sq 1))")),
                ?assertEqual(true, E("(instance? Sq (->Sq 1))")),
                ?assertEqual(true, E("(satisfies? Shape (->Sq 1))")),
                ?assertEqual(false, E("(satisfies? Shape 1)")),
                ?assertEqual(true, E("(extends? Shape 'vector)")),
                ?assertEqual(false, E("(extends? Shape 'map)"))
        end}
       %% acceptance: no default → error; with a default → fallback
     , {"default fallback",
        fun() ->
                ?assertEqual(<<"No implementation of method: :area of protocol: #'t.shapes/Shape found for class: java.lang.Long">>,
                             ev("(try (area 1) (catch IllegalArgumentException e (ex-message e)))", 't.shapes')),
                ev("(extend-type default Shape (area [_] -1) (scale [x _] x))", 't.shapes'),
                ?assertEqual(-1, ev("(area 1)", 't.shapes')),
                ?assertEqual(true, ev("(satisfies? Shape :kw)", 't.shapes')),
                unload_impl('t.shapes.Shape__default'),
                ets:delete(clj2_proto, {'t.shapes.Shape', default})
        end}
       %% acceptance (REPL interleaving): a negative cache entry is replaced
       %% as soon as the impl module loads
     , {"negative cache then extend",
        fun() ->
                ?assertEqual(false, ev("(satisfies? Shape {:a 1})", 't.shapes')),
                ?assertEqual([{{'t.shapes.Shape', map}, none}],
                             ets:lookup(clj2_proto, {'t.shapes.Shape', map})),
                ev("(extend-type map Shape (area [m] (count m)) (scale [m _] m))", 't.shapes'),
                ?assertEqual(true, ev("(satisfies? Shape {:a 1})", 't.shapes')),
                ?assertEqual(1, ev("(area {:a 1})", 't.shapes')),
                unload_impl('t.shapes.Shape__map'),
                ets:delete(clj2_proto, {'t.shapes.Shape', map})
        end}
       %% acceptance: extending compiles only the new impl module; the
       %% protocol's namespace and the other impl modules are untouched
     , {"extend recompiles nothing else",
        fun() ->
                Watched = ['t.shapes', 't.shapes.Shape__vector', 't.shapes.Shape__t.shapes.Sq'],
                Before = [{M, M:module_info(md5)} || M <- Watched],
                Nss = [load(lists:flatten(io_lib:format(
                          "(ns t.ext~b (:require [t.shapes :refer [Shape]]))"
                          " (deftype T~b [] Shape (area [_] ~b) (scale [x _] x))", [I, I, I])))
                       || I <- lists:seq(1, 20)],
                ?assertEqual(Before, [{M, M:module_info(md5)} || M <- Watched]),
                ?assertEqual(lists:seq(1, 20),
                             [ev(lists:flatten(io_lib:format("(t.shapes/area (t.ext~b/->T~b))", [I, I])), user)
                              || I <- lists:seq(1, 20)]),
                [begin
                     unload(Ns),
                     unload_impl(clj2_proto:impl_module('t.shapes.Shape', list_to_atom(atom_to_list(Ns) ++ ".T" ++ integer_to_list(I))))
                 end || {I, Ns} <- lists:zip(lists:seq(1, 20), Nss)]
        end}
       %% an impl module on the code path is found by the cache probe
     , {"impl module from the code path",
        fun() ->
                {ok, _, Mods} = clj2_compiler:compile_ns_modules(
                                  <<"(ns t.cp (:require [t.shapes :refer [Shape]])) (extend-type float Shape (area [x] x) (scale [x _] x))">>, #{}),
                [{Impl, Bin}, {NsMod, NsBin}] = Mods,
                Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "clj2_proto_tests_" ++ os:getpid()),
                ok = filelib:ensure_path(Dir),
                ok = file:write_file(filename:join(Dir, atom_to_list(Impl) ++ ".beam"), Bin),
                ok = file:write_file(filename:join(Dir, atom_to_list(NsMod) ++ ".beam"), NsBin),
                true = code:add_patha(Dir),
                try
                    ?assertEqual(false, code:is_loaded(Impl)),
                    ?assertEqual(2.5, ev("(area 2.5)", 't.shapes'))
                after
                    unload_impl(Impl), unload('t.cp'),
                    ets:delete(clj2_proto, {'t.shapes.Shape', float}),
                    code:del_path(Dir), file:del_dir_r(Dir)
                end
        end}
     , {"errors",
        fun() ->
                Err = fun(S) -> try clj2_compiler:compile_ns(list_to_binary(S)), no_error
                                catch error:{clj2_compile, _, Why} -> Why end
                      end,
                ?assertEqual({driver, {unresolved_protocol, 'Nope'}},
                             Err("(ns t.e) (extend-type nil Nope (m [_] 1))")),
                %% inside an expression extend-type is a run-time extend: the
                %% protocol is then an ordinary symbol to resolve
                ?assertEqual({resolve, {unresolved_symbol, 'P'}},
                             Err("(ns t.e) (def x (fn* [] (extend-type nil P (m [_] 1))))")),
                ?assertEqual({syntax, {variadic_protocol_method, m}},
                             Err("(ns t.e) (defprotocol P (m [this & more]))"))
        end}
     ]}.

%% IFn of data (clj2_rt:invoke)
ifn_test_() ->
    E = fun(S) -> clj2_compiler:eval(list_to_binary(S)) end,
    [ ?_assertEqual(1, E("(:a {:a 1})"))
    , ?_assertEqual(':d', E("(:b {:a 1} :d)"))
    , ?_assertEqual(1, E("({:a 1} :a)"))
    , ?_assertEqual(1, E("(#{1} 1)"))
    , ?_assertEqual(6, E("([5 6] 1)"))
    , ?_assertEqual(1, E("(let* [k :a] (k {:a 1}))"))
    ].
