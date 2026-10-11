%%%-------------------------------------------------------------------
%%% @doc Project builds and the compile cache (clojerl2-024, designs/02 §6):
%%% what a change recompiles.
%%%-------------------------------------------------------------------
-module(clj2_build_tests).

-include_lib("eunit/include/eunit.hrl").

-define(UTIL(Body, Doc, Macro),
        ["(ns bt.util)\n"
         "(defn twice \"", Doc, "\" [x] ", Body, ")\n"
         "(defmacro unless [c & body] ", Macro, ")\n"]).
-define(MACRO, "`(if ~c nil (do ~@body))").

cache_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) -> {inorder, [fun() -> scenario(Dir) end]} end}.

setup() ->
    {ok, _} = clj2_core:ensure(),
    Dir = filename:join([os:getenv("TMPDIR", "/tmp"), "clj2_build_tests_" ++ os:getpid()]),
    _ = file:del_dir_r(Dir),
    write(Dir, "bt/proto.clj", "(ns bt.proto)\n(defprotocol Greet (greet [x]))\n"),
    write(Dir, "bt/util.clj", ?UTIL("(* 2 x)", "doubles", ?MACRO)),
    write(Dir, "bt/core.clj",
          "(ns bt.core (:require [bt.util :as u] [bt.proto :as p]))\n"
          "(defn run [] (u/unless false (u/twice 21)))\n"),
    Dir.

cleanup(Dir) -> file:del_dir_r(Dir).

write(Dir, Rel, Src) ->
    F = filename:join([Dir, "src", Rel]),
    ok = filelib:ensure_dir(F),
    ok = file:write_file(F, unicode:characters_to_binary(Src)).

build(Dir) ->
    clj2_build:build(#{src_dirs => [filename:join(Dir, "src")],
                       ebin_dir => filename:join(Dir, "ebin"),
                       cache_dir => filename:join(Dir, "cache")}).

compiled(Dir) -> lists:sort(maps:get(compiled, build(Dir))).

scenario(Dir) ->
    %% first build: everything, in dependency order
    R1 = build(Dir),
    ?assertEqual(['bt.core', 'bt.proto', 'bt.util'], lists:sort(maps:get(compiled, R1))),
    ?assertEqual(42, 'bt.core':run()),
    ?assert(filelib:is_regular(filename:join([Dir, "ebin", "bt.core.beam"]))),

    %% unchanged: all from the cache
    R2 = build(Dir),
    ?assertEqual([], maps:get(compiled, R2)),
    ?assertEqual(3, length(maps:get(cached, R2))),

    %% a fn body: that namespace only; its dependent runs the new code
    write(Dir, "bt/util.clj", ?UTIL("(* 3 x)", "doubles", ?MACRO)),
    ?assertEqual(['bt.util'], compiled(Dir)),
    ?assertEqual(63, 'bt.core':run()),

    %% a docstring: that namespace only
    write(Dir, "bt/util.clj", ?UTIL("(* 3 x)", "triples", ?MACRO)),
    ?assertEqual(['bt.util'], compiled(Dir)),

    %% a macro body: its users are recompiled (they expanded it)
    write(Dir, "bt/util.clj", ?UTIL("(* 3 x)", "triples", "`(if ~c :skipped (do ~@body))")),
    ?assertEqual(['bt.core', 'bt.util'], compiled(Dir)),

    %% an arity: dependents are linked against arities, so they recompile
    write(Dir, "bt/util.clj",
          ["(ns bt.util)\n(defn twice ([x] (* 3 x)) ([x y] (+ x y)))\n"
           "(defmacro unless [c & body] `(if ~c :skipped (do ~@body)))\n"]),
    ?assertEqual(['bt.core', 'bt.util'], compiled(Dir)),
    ?assertEqual(63, 'bt.core':run()),

    %% extending a protocol to a new type: only the new namespace (D9)
    write(Dir, "bt/dog.clj",
          "(ns bt.dog (:require [bt.proto :as p]))\n"
          "(deftype Dog [])\n"
          "(extend-type Dog p/Greet (greet [_] \"woof\"))\n"
          "(defn speak [] (p/greet (->Dog)))\n"),
    ?assertEqual(['bt.dog'], compiled(Dir)),
    ?assertEqual(<<"woof">>, 'bt.dog':speak()),
    Impls = [M || {M, _} <- code:all_loaded(), lists:prefix("bt.proto.Greet__", atom_to_list(M))],
    ?assertMatch([_], Impls),
    [Impl] = Impls,
    ?assert(filelib:is_regular(filename:join([Dir, "ebin", atom_to_list(Impl) ++ ".beam"]))),

    %% a namespace removed: its modules leave ebin
    ok = file:delete(filename:join([Dir, "src", "bt", "dog.clj"])),
    R3 = build(Dir),
    ?assertEqual([], maps:get(compiled, R3)),
    ?assertEqual(lists:sort(['bt.dog', Impl]), lists:sort(maps:get(removed, R3))),
    ?assertNot(filelib:is_regular(filename:join([Dir, "ebin", "bt.dog.beam"]))),

    %% clean: everything compiles again
    ok = clj2_build:clean(filename:join(Dir, "cache")),
    ?assertEqual(['bt.core', 'bt.proto', 'bt.util'], compiled(Dir)).

order_test() ->
    {ok, _} = clj2_core:ensure(),
    Dir = filename:join([os:getenv("TMPDIR", "/tmp"), "clj2_build_order_" ++ os:getpid()]),
    _ = file:del_dir_r(Dir),
    try
        write(Dir, "c/a.clj", "(ns c.a (:require [c.b]))\n"),
        write(Dir, "c/b.clj", "(ns c.b (:require c.a))\n"),
        write(Dir, "c/script.clj", "(println :not-a-namespace)\n"),
        Scanned = clj2_build:scan([filename:join(Dir, "src")]),
        ?assertEqual(['c.a', 'c.b'], lists:sort([Ns || #{ns := Ns} <- Scanned])),
        ?assertError({clj2_build, {cyclic_requires, _}}, build(Dir))
    after
        file:del_dir_r(Dir)
    end.
