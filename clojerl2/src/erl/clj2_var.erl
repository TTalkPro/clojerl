%%%-------------------------------------------------------------------
%%% @doc clj2_var — var roots and dynamic bindings (designs/03 §2.3, §3).
%%%
%%% Only vars that are not plain functions or constants have a root
%%% here (computed values, `^:dynamic', `^:redef'). Roots live in one
%%% public ETS table `clj2_var' keyed `{Module, Name}', owned by the
%%% {@link clj2_ns} server (ETS, not persistent_term: REPL redefinition
%%% is write-heavy, 03 §2.3).
%%%
%%% Dynamic bindings are a per-process stack in the process dictionary
%%% under `{clj2_dyn, Module, Name}' (03 §3); they do not cross process
%%% boundaries (documented divergence; `bound-fn' will snapshot them).
%%%-------------------------------------------------------------------
-module(clj2_var).

-export([ new_table/0
        , root/2
        , set_root/3
        , deref/2
        , push_binding/3
        , pop_binding/2
        , delete_roots/1
        ]).

-define(TAB, clj2_var).

%% @private called by the clj2_ns server, which owns the table
new_table() ->
    ?TAB = ets:new(?TAB, [named_table, public, set,
                          {read_concurrency, true}, {write_concurrency, true}]).

%% @doc Root value of a var; unbound vars raise.
root(M, Name) ->
    try ets:lookup_element(?TAB, {M, Name}, 2)
    catch error:badarg -> erlang:error({clj2_unbound_var, M, Name})
    end.

set_root(M, Name, V) ->
    clj2_ns:ensure_started(),
    true = ets:insert(?TAB, {{M, Name}, V}),
    V.

%% @doc Value of a dynamic var: innermost binding of this process,
%% else the root.
deref(M, Name) ->
    case get({clj2_dyn, M, Name}) of
        [V | _] -> V;
        _ -> root(M, Name)
    end.

push_binding(M, Name, V) ->
    K = {clj2_dyn, M, Name},
    put(K, [V | case get(K) of undefined -> []; L -> L end]),
    ok.

pop_binding(M, Name) ->
    K = {clj2_dyn, M, Name},
    case get(K) of
        [_] -> erase(K);
        [_ | Rest] -> put(K, Rest);
        _ -> erlang:error({clj2_no_binding, M, Name})
    end,
    ok.

delete_roots(M) ->
    ets:match_delete(?TAB, {{M, '_'}, '_'}).
