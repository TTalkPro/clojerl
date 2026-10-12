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
        , take_root/2
        , deref/2
        , push_binding/3
        , pop_binding/2
        , set_binding/3
        , with_bindings/2
        , frame/0
        , with_frame/2
        , bound_fn/1
        , delete_roots/1
        , push_frame/1
        , pop_frame/0
        , var_set/2
        , is_thread_bound/1
        , thread_bindings/0
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

%% @doc Root value of a var, removed from the table (an interned var's
%% init takes its value this way).
take_root(M, Name) ->
    case ets:take(?TAB, {M, Name}) of
        [{_, V}] -> V;
        [] -> erlang:error({clj2_unbound_var, M, Name})
    end.

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

%% @doc Replace this process's innermost binding (establish one if
%% none): what the REPL does to *1, *2, *3 and *e.
set_binding(M, Name, V) ->
    K = {clj2_dyn, M, Name},
    put(K, [V | case get(K) of [_ | Outer] -> Outer; _ -> [] end]),
    ok.

%% @doc (binding [v1 e1 ...] body): `Pairs' alternates vars (#'ns/name)
%% and values, all evaluated before any is bound (as on the JVM); F runs
%% with them bound in this process and they are unbound however it ends.
with_bindings(Pairs, F) ->
    Bs = pairs(clj2_coll:to_list(Pairs)),
    [push_binding(M, N, V) || {M, N, V} <- Bs],
    try clj2_rt:invoke(F, [])
    after [pop_binding(M, N) || {M, N, _} <- lists:reverse(Bs)]
    end.

pairs([{var, _, {Ns, Name}}, V | Rest]) ->
    [{dynamic_module(Ns, Name), Name, V} | pairs(Rest)];
pairs([]) -> [].

%% the module a dynamic var's bindings are keyed by (its accessor's)
dynamic_module(Ns, Name) ->
    case clj2_ns:info(Ns) of
        {ok, #{module := M, vars := #{Name := #{dynamic := true} = I}}} -> maps:get(module, I, M);
        {ok, #{vars := #{Name := _}}} ->
            erlang:error(clj2_rt:ex_info(
                           iolist_to_binary(["Can't dynamically bind non-dynamic var: ",
                                             atom_to_binary(Ns), "/", atom_to_binary(Name)]),
                           clj2_coll:hash_map_kv([]), nil));
        _ -> erlang:error({clj2_no_such_var, Ns, Name})
    end.

%% @doc This process's dynamic bindings (innermost value of each), to be
%% re-established elsewhere with with_frame/2: bound-fn, future and agent
%% actions carry them across processes (designs/03 §3).
frame() ->
    [{M, N, V} || {{clj2_dyn, M, N}, [V | _]} <- get()].

with_frame([], F) -> F();
with_frame(Frame, F) ->
    [push_binding(M, N, V) || {M, N, V} <- Frame],
    try F()
    after [pop_binding(M, N) || {M, N, _} <- Frame]
    end.

%% @doc (bound-fn* f): f, called with the bindings in effect now, in
%% whatever process calls it. A variadic fn value of any arity.
bound_fn(F) ->
    Frame = frame(),
    {clj2_fn, #{}, {0, fun(Rest) ->
                               Args = case Rest of
                                          nil -> [];
                                          _ -> clj2_coll:to_list(Rest)
                                      end,
                               with_frame(Frame, fun() -> clj2_rt:invoke(F, Args) end)
                       end}}.

%% @doc (push-thread-bindings {#'v 1 ...}): bind as binding does, until
%% the matching pop-thread-bindings (a frame stack in the process)
push_frame(Map) ->
    Bs = pairs(lists:append([[K, V] || {vector, _, {K, V}} <- clj2_coll:to_list(Map)])),
    [push_binding(M, N, V) || {M, N, V} <- Bs],
    put(clj2_binding_frames, [Bs | case get(clj2_binding_frames) of undefined -> []; Fs -> Fs end]),
    nil.

pop_frame() ->
    case get(clj2_binding_frames) of
        [Bs | Rest] ->
            [pop_binding(M, N) || {M, N, _} <- lists:reverse(Bs)],
            put(clj2_binding_frames, Rest),
            nil;
        _ -> erlang:error(clj2_rt:ex_info(<<"Pop without matching push">>,
                                          clj2_coll:hash_map_kv([':type', ':IllegalStateException']), nil))
    end.

%% @doc (var-set v x): a with-local-vars var, or a dynamic var's binding
var_set({local_var, _, Cell}, X) -> clj2_ref:reset(Cell, X);
var_set({var, _, {Ns, Name}}, X) ->
    {ok, #{module := NsMod, vars := #{Name := I}}} = clj2_ns:info(Ns),
    M = maps:get(module, I, NsMod),
    %% the validator runs before the binding check, as on the JVM
    case I of
        #{validator := F} when F =/= nil ->
            case clj2_rt:invoke(F, [X]) of
                R when R =:= false; R =:= nil ->
                    erlang:error(clj2_rt:ex_info(<<"Invalid reference state">>,
                                                 clj2_coll:hash_map_kv([':type', ':IllegalStateException']), nil));
                _ -> ok
            end;
        _ -> ok
    end,
    case get({clj2_dyn, M, Name}) of
        [_ | _] -> set_binding(M, Name, X), X;
        %% bound while a file loads and at the REPL on the JVM, so set! of
        %% them always works: this process gets a binding
        _ when Ns =:= 'clojure.core', (Name =:= '*warn-on-reflection*' orelse
                                       Name =:= '*unchecked-math*') ->
            push_binding(M, Name, X), X;
        _ -> erlang:error(clj2_rt:ex_info(
                            iolist_to_binary(["Can't change/establish root binding of: ", atom_to_binary(Name),
                                              " with set"]),
                            clj2_coll:hash_map_kv([':type', ':IllegalStateException']), nil))
    end.

%% @doc (thread-bound? v): a binding of v in this process
is_thread_bound({var, _, {Ns, Name}}) ->
    case clj2_ns:info(Ns) of
        {ok, #{module := NsMod, vars := #{Name := I}}} ->
            case get({clj2_dyn, maps:get(module, I, NsMod), Name}) of
                [_ | _] -> true;
                _ -> false
            end;
        _ -> false
    end;
is_thread_bound(_) -> false.

%% @doc (get-thread-bindings): {var value} of every binding in this process
thread_bindings() ->
    Bound = maps:from_list([{{M, N}, V} || {{clj2_dyn, M, N}, [V | _]} <- get()]),
    Pairs = lists:append(
              [[{var, nil, {Ns, Name}}, maps:get({maps:get(module, I, NsMod), Name}, Bound)]
               || Ns <- clj2_ns:all(),
                  {ok, #{module := NsMod, vars := Vars}} <- [clj2_ns:info(Ns)],
                  {Name, I} <- maps:to_list(Vars),
                  is_map_key({maps:get(module, I, NsMod), Name}, Bound)]),
    clj2_coll:hash_map_kv(Pairs).

delete_roots(M) ->
    ets:match_delete(?TAB, {{M, '_'}, '_'}).
