%%%-------------------------------------------------------------------
%%% @doc Namespaces and vars (clojerl2-015, designs/03 §2).
%%%-------------------------------------------------------------------
-module(clj2_ns_tests).

-include_lib("eunit/include/eunit.hrl").

load(Src) ->
    {ok, Ns} = clj2_compiler:load_ns(list_to_binary(Src)),
    Ns.

ev(Src) -> clj2_compiler:eval(list_to_binary(Src)).
ev(Src, Ns) -> clj2_compiler:eval(list_to_binary(Src), #{ns => Ns}).

unload(Ns) ->
    clj2_ns:remove(Ns),
    M = clj2_ns:module(Ns),
    code:purge(M),
    code:delete(M),
    code:purge(M).

with_ns(Srcs, Tests) ->
    {setup,
     fun() -> [load(S) || S <- Srcs] end,
     fun(Nss) -> [unload(N) || N <- lists:reverse(Nss)] end,
     Tests}.

cerr(Src) ->
    try clj2_compiler:compile_ns(list_to_binary(Src)), no_error
    catch error:{clj2_compile, _, Why} -> Why
    end.

-define(BASIC,
        "(ns t.basic)\n"
        "(def x 42)\n"
        "(def f (fn* [a] (erlang/+ a x)))\n"
        "(def g (fn* ([] (g 1)) ([a] (f a))))\n"
        "(def a (fn* [] (b)))\n"                   %% forward reference
        "(def b (fn* [] :b))\n"
        "(def v (fn* [a & r] r))\n"
        "(def two (erlang/+ 1 1))\n"
        "(def twenty (erlang/* two 10))\n"          %% init order, own var in init
        "(def u (erlang/unique_integer))\n"
        "(def fact (fn* fact [n] (if (erlang/== n 0) 1 (erlang/* n (fact (erlang/- n 1))))))\n"
        "(def cnt (fn* [n acc] (if (erlang/== n 0) acc (recur (erlang/- n 1) (erlang/+ acc 1)))))\n"
        "(def ^:dynamic *d* 1)\n"
        "(def rd (fn* [] *d*))\n"
        "(def unbound)\n").

-define(REQ,
        "(ns t.req (:require [t.basic :as b :refer [x]]))\n"
        "(def y (fn* [] (erlang/+ x (b/f 0))))\n"
        "(def z (fn* [n] (y)))\n").

%%====================================================================
%% Vars inside one namespace
%%====================================================================

basic_test_() ->
    with_ns([?BASIC],
            [ ?_assertEqual(42, 't.basic':x())
            , ?_assertEqual(43, 't.basic':f(1))                 % var fn = module function
            , ?_assertEqual(43, 't.basic':g())
            , ?_assertEqual(':b', 't.basic':a())
            , ?_assertEqual(20, 't.basic':twenty())
            , ?_assertEqual('t.basic':u(), 't.basic':u())     % init ran once
            , ?_assertEqual(720, 't.basic':fact(6))
            , ?_assertEqual(1000000, 't.basic':cnt(1000000, 0))  % recur → local tail call
            , ?_assertEqual(nil, 't.basic':v(1, nil))
            , ?_assertError({clj2_unbound_var, 't.basic', unbound}, 't.basic':unbound())
              %% registry
            , ?_assertMatch({ok, #{module := 't.basic',
                                   vars := #{f := #{kind := fn, arities := [1]},
                                             g := #{kind := fn, arities := [0, 1]},
                                             v := #{kind := fn, variadic := 1},
                                             x := #{kind := const},
                                             two := #{kind := cell},
                                             '*d*' := #{kind := indirect, dynamic := true}}}},
                            clj2_ns:info('t.basic'))
            ]).

calls_from_eval_test_() ->
    with_ns([?BASIC],
            [ ?_assertEqual(43, ev("(t.basic/g)"))
            , ?_assertEqual(nil, ev("(t.basic/v 1)"))
            , ?_assertEqual([2, 3], ev("(t.basic/v 1 2 3)"))
              %% fn vars as values: Erlang funs (single arity) / clj2_fn (multi)
            , ?_assertEqual([43, 44], ev("(lists/map t.basic/f '(1 2))"))
            , ?_assertEqual(43, ev("(let* [h t.basic/g] (h))"))
            , ?_assertEqual([2], ev("(let* [h t.basic/v] (h 1 2))"))
              %% resolving in a namespace
            , ?_assertEqual(43, ev("(f 1)", 't.basic'))
            , ?_assertEqual(42, ev("x", 't.basic'))
            ]).

dynamic_test_() ->
    with_ns([?BASIC],
            fun() ->
                    ?assertEqual(1, 't.basic':rd()),
                    clj2_var:push_binding('t.basic', '*d*', 2),
                    ?assertEqual(2, 't.basic':rd()),
                    %% bindings are per process
                    Self = self(),
                    spawn(fun() -> Self ! {other, 't.basic':rd()} end),
                    receive {other, V} -> ?assertEqual(1, V) end,
                    clj2_var:pop_binding('t.basic', '*d*'),
                    ?assertEqual(1, 't.basic':rd())
            end).

%%====================================================================
%% Between namespaces
%%====================================================================

require_test_() ->
    with_ns([?BASIC, ?REQ],
            [ ?_assertEqual(84, 't.req':y())
            , ?_assertEqual(84, 't.req':z(0))
            ]).

%% Acceptance: static var calls are direct M:F/N calls — external for
%% another namespace, local inside one — with no apply, no accessor,
%% no fake_fun.
direct_link_test_() ->
    with_ns([?BASIC],
            fun() ->
                    {ok, _, _, Bin} = clj2_compiler:compile_ns(list_to_binary(?REQ)),
                    Code = disasm(Bin),
                    ?assert(has(Code, fun({I, _, {extfunc, 't.basic', f, 1}})
                                            when I =:= call_ext; I =:= call_ext_last;
                                                 I =:= call_ext_only -> true end)),
                    ?assert(has(Code, fun({I, _, {'t.req', y, 0}})
                                            when I =:= call; I =:= call_last;
                                                 I =:= call_only -> true end)),
                    ?assertNot(has(Code, fun({_, _, {extfunc, erlang, apply, _}}) -> true end)),
                    ?assertNot(has(Code, fun({_, _, {extfunc, clj2_rt, invoke, 2}}) -> true end))
            end).

disasm(Bin) ->
    {beam_file, _, _, _, _, Funs} = beam_disasm:file(Bin),
    lists:append([Is || {function, _, _, _, Is} <- Funs]).

has(Code, Pred) ->
    lists:any(fun(I) -> try Pred(I) catch error:function_clause -> false end end, Code).

%% A compiled namespace on the code path registers itself when loaded
%% (on_load), without going through the compiler.
code_path_load_test() ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "clj2_ns_tests_" ++ os:getpid()),
    ok = filelib:ensure_path(Dir),
    {ok, Ns, M, Bin} = clj2_compiler:compile_ns(<<"(ns t.path) (def k 7)">>),
    ok = file:write_file(filename:join(Dir, atom_to_list(M) ++ ".beam"), Bin),
    true = code:add_patha(Dir),
    try
        ?assertEqual(error, maybe_registered(Ns)),
        ?assertMatch({ok, #{vars := #{k := _}}}, clj2_ns:info(Ns)),
        ?assertEqual(7, ev("t.path/k"))
    after
        unload(Ns),
        code:del_path(Dir),
        file:del_dir_r(Dir)
    end.

maybe_registered(Ns) ->
    case lists:member(Ns, clj2_ns:all()) of
        true -> {ok, registered};
        false -> error
    end.

%%====================================================================
%% Redefinition (acceptance): new calls see the new code, closures made
%% by the old version keep running it (BEAM two-version semantics).
%%====================================================================

redefinition_test() ->
    %% mk's closure sleeps in a non-tail position, so a process calling it
    %% has a return address inside that version's code
    V = fun(Tag) ->
                "(ns t.redef) (def mk (fn* [] (fn* [ms] (do (timer/sleep ms) " ++ Tag ++ "))))"
                " (def v (fn* [] " ++ Tag ++ "))"
        end,
    load(V(":old")),
    try
        Old = 't.redef':mk(),
        load(V(":new")),
        ?assertEqual(':new', 't.redef':v()),
        ?assertEqual(':new', ('t.redef':mk())(0)),
        ?assertEqual(':old', Old(0)),
        %% a process still running the old version blocks a further reload
        %% (it is not killed)...
        P = spawn(fun() -> Old(60000) end),
        timer:sleep(50),
        ?assertEqual({error, {old_code_in_use, 't.redef'}},
                     clj2_compiler:load_ns(list_to_binary(V(":third")))),
        ?assert(is_process_alive(P)),
        %% ...until it is gone
        exit(P, kill),
        timer:sleep(10),
        ?assertEqual({ok, 't.redef'}, clj2_compiler:load_ns(list_to_binary(V(":third")))),
        ?assertEqual(':third', 't.redef':v())
    after
        unload('t.redef')
    end.

%%====================================================================
%% Registry concurrency (acceptance)
%%====================================================================

registry_concurrency_test() ->
    Self = self(),
    N = 20,
    Writers = [spawn_link(fun() ->
                                  Ns = list_to_atom("t.conc" ++ integer_to_list(I)),
                                  [begin
                                       ok = clj2_ns:register(Ns, Ns, #{a => #{kind => const}}),
                                       {ok, _} = clj2_ns:info(Ns),
                                       ok = clj2_ns:remove(Ns)
                                   end || _ <- lists:seq(1, 50)],
                                  Self ! {done, I}
                          end) || I <- lists:seq(1, N)],
    Readers = [spawn_link(fun() ->
                                  [_ = clj2_ns:all() || _ <- lists:seq(1, 200)],
                                  Self ! {done, reader}
                          end) || _ <- lists:seq(1, 5)],
    [receive {done, _} -> ok after 10000 -> error(timeout) end
     || _ <- Writers ++ Readers],
    ?assertEqual([], [Ns || Ns <- clj2_ns:all(),
                            lists:prefix("t.conc", atom_to_list(Ns))]).

%%====================================================================
%% Errors
%%====================================================================

errors_test_() ->
    with_ns([?BASIC],
            [ ?_assertEqual({link, {arity, 't.basic', f, 2}},
                            cerr("(ns t.e) (def h (fn* [] (t.basic/f 1 2)))"))
            , ?_assertEqual({resolve, {no_such_var, 't.basic', nope}},
                            cerr("(ns t.e) (def h (fn* [] (t.basic/nope)))"))
            , ?_assertEqual({ns_not_found, 't.nowhere'},
                            cerr("(ns t.e (:require [t.nowhere :as n]))"))
            , ?_assertEqual({declare, {duplicate_def, h}},
                            cerr("(ns t.e) (def h 1) (def h 2)"))
            , ?_assertEqual({declare, {reserved_var_name, module_info}},
                            cerr("(ns t.e) (def module_info 1)"))
            , ?_assertEqual({syntax, ns_must_be_first_form},
                            cerr("(def h 1) (ns t.e)"))
            , ?_assertEqual({resolve, {unresolved_symbol, y}},
                            cerr("(ns t.e) (def h (fn* [] y))"))
            , ?_assertMatch({error, {ns_init_failed, 't.bad', {error, ':boom', _}}},
                            clj2_compiler:load_ns(<<"(ns t.bad) (def ok 1) (throw :boom)">>))
            , ?_assertEqual(error, clj2_ns:info('t.bad'))
            ]).
