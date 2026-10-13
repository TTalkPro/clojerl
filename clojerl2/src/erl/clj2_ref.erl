%%%-------------------------------------------------------------------
%%% @doc clj2_ref — reference types (designs/03 §5.2, clojerl2-018).
%%%
%%% atom     `{atom, nil, {Key, Init}}'. Its state is an ETS row
%%%          `{Key, Version, Value, Validator, Watches}' in `clj2_atom',
%%%          made by the first write (an atom only read costs nothing,
%%%          as in clojerl 1.0). swap!/reset! are a compare-and-swap loop
%%%          on Version with ets:select_replace (no copy of the old value
%%%          into the match spec); validators run before the swap, watches
%%%          after it, in the swapping process (as on the JVM).
%%% volatile `{volatile, nil, Key}': a cell in this process's dictionary
%%%          (volatiles are for one thread; here, one process).
%%% promise  `{promise, nil, Key}': delivered once into `clj2_promise';
%%%          waiters register in `clj2_promise_wait' and are woken by a
%%%          message; no process per promise.
%%% future   `{future, nil, {Key, Pid}}': a process runs the body with the
%%%          caller's dynamic bindings (bound-fn semantics, designs/03 §3)
%%%          and delivers `{ok, V}' or `{raised, C, R, S}' like a promise.
%%% agent    `{agent, nil, {Key, Pid}}': one process per agent runs its
%%%          actions in send order; the state is an ETS row in `clj2_agent'
%%%          so deref never waits for a running action.
%%%
%%% No row or agent process is reclaimed when the value becomes garbage:
%%% BEAM has no finalizers (known divergence :state/explicit-lifetime).
%%%-------------------------------------------------------------------
-module(clj2_ref).

-export([new_tables/0]).
-export([atom/1, atom/2, swap/3, swap_vals/3, reset/2, reset_vals/2, compare_and_set/3,
         set_validator/2, get_validator/1, add_watch/3, remove_watch/2]).
-export([volatile/1, vreset/2]).
-export([promise/0, deliver/2]).
-export([future_call/1, future_cancel/1, is_future_done/1, is_future_cancelled/1]).
-export([agent/2, send/3, await/2, agent_error/1, restart_agent/3,
         set_error_handler/2, error_handler/1, set_error_mode/2, error_mode/1]).
-export([local_var/1, local_bound/1, ref_meta/1, reset_ref_meta/2]).
-export([deref/1, deref/3, is_realized/1, type_of/1, version/1]).

-define(ATOM, clj2_atom).
-define(PROMISE, clj2_promise).
-define(WAIT, clj2_promise_wait).
-define(AGENT, clj2_agent).

%% @private called by the clj2_ns server, which owns the tables
new_tables() ->
    ?ATOM = ets:new(?ATOM, [named_table, public, set, {read_concurrency, true}, {write_concurrency, true}]),
    ?PROMISE = ets:new(?PROMISE, [named_table, public, set, {read_concurrency, true}]),
    ?WAIT = ets:new(?WAIT, [named_table, public, bag]),
    ?AGENT = ets:new(?AGENT, [named_table, public, set, {read_concurrency, true}]),
    ok.

%%====================================================================
%% atom
%%====================================================================

atom(Init) -> {atom, nil, {make_ref(), Init}}.

%% Opts: the (atom x :validator f) options, as a Clojure map or nil
atom(Init, Opts) ->
    Meta = clj2_coll:get(Opts, ':meta'),
    Meta =:= nil orelse clj2_coll:is_any_map(Meta) orelse
        erlang:error(clj2_rt:ex_info(iolist_to_binary(["class ", atom_to_binary(clj2_class:class_of(Meta)),
                                                       " cannot be cast to class clojure.lang.IPersistentMap"]),
                                     clj2_coll:hash_map_kv([':type', ':ClassCastException']), nil)),
    A = atom(Init),
    case clj2_coll:get(Opts, ':validator') of
        nil -> ok;
        V -> validate(V, Init), set_validator(A, V)
    end,
    Meta =:= nil orelse reset_ref_meta(A, Meta),
    A.

%% @doc An atom's or agent's metadata (alter-meta!/reset-meta!): kept in
%% the atom table under {meta, Key}
ref_meta(R) ->
    case ets:lookup(?ATOM, {meta, ref_key(R)}) of
        [{_, M}] -> M;
        [] -> nil
    end.

reset_ref_meta(R, M) ->
    true = ets:insert(?ATOM, {{meta, ref_key(R)}, M}),
    M.

ref_key({atom, _, {Key, _}}) -> Key;
ref_key({agent, _, {Key, _}}) -> Key.

current({atom, _, {Key, Init}}) ->
    case ets:lookup(?ATOM, Key) of
        [{_, Ver, Val, Validator, Watches}] -> {Ver, Val, Validator, Watches};
        [] -> {0, Init, nil, #{}}
    end.

%% → {Old, New}; Fun(Old) gives New
update(A = {atom, _, {Key, _}}, Fun) ->
    {Ver, Old, Validator, Watches} = current(A),
    New = Fun(Old),
    validate(Validator, New),
    case cas(Key, Ver, New) of
        true -> notify(Watches, A, Old, New), {Old, New};
        false -> update(A, Fun)
    end.

%% compare-and-swap on the version: version 0 is "no row yet"
cas(Key, 0, New) ->
    ets:insert_new(?ATOM, {Key, 1, New, nil, #{}});
cas(Key, Ver, New) ->
    Spec = [{{Key, Ver, '_', '$1', '$2'}, [],
             [{{{const, Key}, Ver + 1, {const, New}, '$1', '$2'}}]}],
    ets:select_replace(?ATOM, Spec) =:= 1.

swap(A, F, Args) ->
    {_, New} = update(A, fun(Old) -> clj2_rt:invoke(F, [Old | list(Args)]) end),
    New.

swap_vals(A, F, Args) ->
    {Old, New} = update(A, fun(Old) -> clj2_rt:invoke(F, [Old | list(Args)]) end),
    clj2_coll:vector([Old, New]).

reset(A, New) -> {_, New} = update(A, fun(_) -> New end), New.

reset_vals(A, New) -> {Old, New} = update(A, fun(_) -> New end), clj2_coll:vector([Old, New]).

%% the swap happens only if the current value is (identical to) Old
compare_and_set(A = {atom, _, {Key, _}}, Old, New) ->
    case current(A) of
        {Ver, Cur, Validator, Watches} when Cur =:= Old ->
            validate(Validator, New),
            case cas(Key, Ver, New) of
                true -> notify(Watches, A, Old, New), true;
                false -> compare_and_set(A, Old, New)
            end;
        _ -> false
    end.

%% validator and watches live in the row: make it, then change them by CAS
set_validator(V = {var, _, _}, F) -> clj2_rt:set_var_validator(V, F);
set_validator(A = {atom, _, _}, F) ->
    {_, Cur, _, _} = current(A),
    F =:= nil orelse validate(F, Cur),
    meta_update(A, fun({Ver, Val, _, W}) -> {Ver, Val, F, W} end),
    nil.

get_validator(V = {var, _, _}) -> clj2_rt:var_validator(V);
get_validator(A = {atom, _, _}) -> element(3, current(A)).

add_watch(V = {var, _, _}, K, F) -> clj2_rt:update_var_watches(V, fun(W) -> W#{K => F} end);
add_watch(A = {atom, _, _}, K, F) ->
    meta_update(A, fun({Ver, Val, V, W}) -> {Ver, Val, V, W#{K => F}} end), A;
add_watch(G = {agent, _, _}, K, F) ->
    agent_update(G, fun(R = #{watches := W}) -> R#{watches := W#{K => F}} end), G.

remove_watch(V = {var, _, _}, K) -> clj2_rt:update_var_watches(V, fun(W) -> maps:remove(K, W) end);
remove_watch(A = {atom, _, _}, K) ->
    meta_update(A, fun({Ver, Val, V, W}) -> {Ver, Val, V, maps:remove(K, W)} end), A;
remove_watch(G = {agent, _, _}, K) ->
    agent_update(G, fun(R = #{watches := W}) -> R#{watches := maps:remove(K, W)} end), G.

%% replace the whole row by CAS on the version (bumped, so a concurrent
%% swap retries)
meta_update(A = {atom, _, {Key, _}}, Fun) ->
    {Ver, Val, V, W} = current(A),
    {_, Val1, V1, W1} = Fun({Ver, Val, V, W}),
    Done = case Ver of
               0 -> ets:insert_new(?ATOM, {Key, 1, Val1, V1, W1});
               _ ->
                   Spec = [{{Key, Ver, '_', '_', '_'}, [],
                            [{{{const, Key}, Ver + 1, {const, Val1}, {const, V1}, {const, W1}}}]}],
                   ets:select_replace(?ATOM, Spec) =:= 1
           end,
    Done orelse meta_update(A, Fun).

validate(nil, _) -> ok;
validate(F, V) ->
    case clj2_rt:invoke(F, [V]) of
        R when R =:= false; R =:= nil ->
            erlang:error(clj2_rt:ex_info(<<"Invalid reference state">>,
                                         clj2_coll:hash_map_kv([':type', ':IllegalStateException', ':value', V]), nil));
        _ -> ok
    end.

%% watches run in the process that made the change, in key order
notify(Watches, Ref, Old, New) ->
    [clj2_rt:invoke(F, [K, Ref, Old, New]) || {K, F} <- lists:sort(maps:to_list(Watches))],
    ok.

list(nil) -> [];
list(L) -> clj2_coll:to_list(L).

%%====================================================================
%% volatile
%%====================================================================

volatile(V) ->
    Key = make_ref(),
    put({clj2_volatile, Key}, V),
    {volatile, nil, Key}.

vreset({volatile, _, Key}, V) -> put({clj2_volatile, Key}, V), V.

vderef({volatile, _, Key}) ->
    case get({clj2_volatile, Key}) of
        undefined -> erlang:error({clj2_volatile_of_another_process, Key});
        V -> V
    end.

%%====================================================================
%% promise
%%====================================================================

promise() -> {promise, nil, make_ref()}.

%% the first delivery wins: → the promise, or nil when already delivered
deliver(P = {promise, _, Key}, V) ->
    case settle(Key, V) of
        true -> P;
        false -> nil
    end.

settle(Key, V) ->
    case ets:insert_new(?PROMISE, {Key, V}) of
        true ->
            [Pid ! {clj2_settled, Key} || {_, Pid} <- ets:take(?WAIT, Key)],
            true;
        false -> false
    end.

%% → {ok, V} | timeout; waits for the row (Pid: a process whose death
%% means the row will never come, or none)
await_row(Key, Timeout, Pid) ->
    case ets:lookup(?PROMISE, Key) of
        [{_, V}] -> {ok, V};
        [] ->
            true = ets:insert(?WAIT, {Key, self()}),
            %% delivered between the lookup and the registration?
            case ets:lookup(?PROMISE, Key) of
                [{_, V}] -> unwait(Key), {ok, V};
                [] ->
                    Mon = case Pid of
                              none -> none;
                              _ -> erlang:monitor(process, Pid)
                          end,
                    R = receive
                            {clj2_settled, Key} -> settled;
                            {'DOWN', Mon, process, _, _} -> down
                        after Timeout -> timeout
                        end,
                    Mon =:= none orelse erlang:demonitor(Mon, [flush]),
                    case {R, ets:lookup(?PROMISE, Key)} of
                        {_, [{_, V}]} -> unwait(Key), {ok, V};
                        {timeout, []} -> unwait(Key), timeout;
                        {down, []} -> unwait(Key), {ok, {raised, error, {clj2_future_died, Pid}, []}}
                    end
            end
    end.

unwait(Key) ->
    ets:delete_object(?WAIT, {Key, self()}),
    receive {clj2_settled, Key} -> ok after 0 -> ok end.

%%====================================================================
%% future
%%====================================================================

%% F: a fn of no arguments, run in a new process with this process's
%% dynamic bindings
future_call(F) ->
    Key = make_ref(),
    Frame = clj2_var:frame(),
    Pid = spawn(fun() ->
                        R = try {ok, clj2_var:with_frame(Frame, fun() -> clj2_rt:invoke(F, []) end)}
                            catch C:E:S -> {raised, C, E, S}
                            end,
                        settle(Key, R)
                end),
    {future, nil, {Key, Pid}}.

future_cancel({future, _, {Key, Pid}}) ->
    case settle(Key, cancelled) of
        true -> exit(Pid, kill), true;
        false -> false
    end.

is_future_done({future, _, {Key, _}}) -> ets:member(?PROMISE, Key).

is_future_cancelled({future, _, {Key, _}}) ->
    ets:lookup(?PROMISE, Key) =:= [{Key, cancelled}].

future_result({ok, V}) -> V;
future_result({raised, C, E, S}) -> erlang:raise(C, E, S);
future_result(cancelled) ->
    erlang:error(clj2_rt:ex_info(<<"future cancelled">>, clj2_coll:hash_map_kv([]), nil)).

%%====================================================================
%% agent
%%====================================================================

%% row: {Key, #{state, error, validator, watches, mode, handler}}
agent(State, Opts) ->
    Key = make_ref(),
    Validator = clj2_coll:get(Opts, ':validator'),
    validate(Validator, State),
    Mode = case clj2_coll:get(Opts, ':error-mode') of
               nil -> case clj2_coll:get(Opts, ':error-handler') of
                          nil -> ':fail';
                          _ -> ':continue'
                      end;
               M -> M
           end,
    true = ets:insert(?AGENT, {Key, #{state => State, error => nil, validator => Validator,
                                      watches => #{}, mode => Mode,
                                      handler => clj2_coll:get(Opts, ':error-handler')}}),
    Pid = spawn(fun() -> agent_loop(Key, []) end),
    {agent, nil, {Key, Pid}}.

agent_row({agent, _, {Key, _}}) -> agent_row(Key);
agent_row(Key) -> [{_, R}] = ets:lookup(?AGENT, Key), R.

agent_update({agent, _, {Key, _}}, Fun) ->
    true = ets:insert(?AGENT, {Key, Fun(agent_row(Key))}), ok.

%% send and send-off: one queue, in order (no separate thread pools)
send(G = {agent, _, {Key, Pid}}, F, Args) ->
    case agent_row(Key) of
        #{error := nil} -> Pid ! {action, F, list(Args), clj2_var:frame()}, G;
        #{error := Err} -> erlang:error(clj2_rt:ex_info(<<"Agent is failed, needs restart">>,
                                                        clj2_coll:hash_map_kv([':error', Err]), nil))
    end.

%% the agent's process; Held: actions that arrived while it was failed
agent_loop(Key, Held) ->
    receive
        {action, F, Args, Frame} = Act ->
            case agent_row(Key) of
                #{error := nil} -> run_action(Key, F, Args, Frame), agent_loop(Key, Held);
                _ -> agent_loop(Key, Held ++ [Act])
            end;
        {await, From, Ref} ->
            From ! {Ref, done},
            agent_loop(Key, Held);
        {restart, From, Ref, Clear} ->
            From ! {Ref, done},
            case Clear of
                true -> agent_loop(Key, []);
                false ->
                    [self() ! A || A <- Held],
                    agent_loop(Key, [])
            end
    end.

run_action(Key, F, Args, Frame) ->
    G = {agent, nil, {Key, self()}},
    try
        clj2_var:with_frame(Frame, fun() ->
            clj2_var:push_binding('clojure.core', '*agent*', G),
            try
                #{state := Old, validator := V, watches := W} = agent_row(Key),
                New = clj2_rt:invoke(F, [Old | Args]),
                validate(V, New),
                agent_update(G, fun(R) -> R#{state := New} end),
                notify(W, G, Old, New)
            after
                clj2_var:pop_binding('clojure.core', '*agent*')
            end
        end)
    catch
        C:E:_S ->
            Err = case C of
                      error -> E;
                      _ -> {C, E}
                  end,
            #{mode := Mode, handler := H} = agent_row(Key),
            H =:= nil orelse (catch clj2_rt:invoke(H, [G, Err])),
            Mode =:= ':continue' orelse agent_update(G, fun(R) -> R#{error := Err} end)
    end.

%% wait until every action sent so far (from this process) has run
await(Agents, Timeout) ->
    Refs = [begin Ref = make_ref(), Pid ! {await, self(), Ref}, Ref end
            || {agent, _, {_, Pid}} <- list(Agents)],
    T0 = erlang:monotonic_time(millisecond),
    lists:all(fun(Ref) ->
                      Left = case Timeout of
                                 infinity -> infinity;
                                 _ -> max(0, Timeout - (erlang:monotonic_time(millisecond) - T0))
                             end,
                      receive {Ref, done} -> true after Left -> false end
              end, Refs).

agent_error(G) -> maps:get(error, agent_row(G)).

%% Opts: :clear-actions true drops what was held while failed
restart_agent(G = {agent, _, {_, Pid}}, State, Opts) ->
    #{error := Err, validator := V} = agent_row(G),
    Err =/= nil orelse erlang:error(clj2_rt:ex_info(<<"Agent does not need a restart">>,
                                                    clj2_coll:hash_map_kv([]), nil)),
    validate(V, State),
    agent_update(G, fun(R) -> R#{state := State, error := nil} end),
    Ref = make_ref(),
    Pid ! {restart, self(), Ref, clj2_coll:get(Opts, ':clear-actions') =:= true},
    receive {Ref, done} -> State end.

set_error_handler(G, F) -> agent_update(G, fun(R) -> R#{handler := F} end), G.
error_handler(G) -> maps:get(handler, agent_row(G)).
set_error_mode(G, M) -> agent_update(G, fun(R) -> R#{mode := M} end), G.
error_mode(G) -> maps:get(mode, agent_row(G)).

%%====================================================================
%% deref, realized?
%%====================================================================

deref(A = {atom, _, _}) -> element(2, current(A));
deref(V = {volatile, _, _}) -> vderef(V);
deref(G = {agent, _, _}) -> maps:get(state, agent_row(G));
deref({promise, _, Key}) -> {ok, V} = await_row(Key, infinity, none), V;
deref({future, _, {Key, Pid}}) -> {ok, R} = await_row(Key, infinity, Pid), future_result(R);
deref({var, _, {Ns, Name}}) -> var_value(Ns, Name);
deref({local_var, _, _} = L) -> local_deref(L);                 % with-local-vars
deref({clj2_reduced, X}) -> X;
deref(X) -> clj2_lazy:deref(X).                              % delay

%% (deref ref timeout-ms timeout-val): promises and futures
deref({promise, _, Key}, Ms, TimeoutVal) ->
    case await_row(Key, Ms, none) of
        {ok, V} -> V;
        timeout -> TimeoutVal
    end;
deref({future, _, {Key, Pid}}, Ms, TimeoutVal) ->
    case await_row(Key, Ms, Pid) of
        {ok, R} -> future_result(R);
        timeout -> TimeoutVal
    end;
deref(X, _, _) -> deref(X).

%% an unbound var's value is a clojure.lang.Var$Unbound, as on the JVM
var_value(Ns, Name) ->
    {ok, #{module := M, vars := #{Name := Info}}} = clj2_ns:info(Ns),
    try clj2_rt:var_value(maps:get(module, Info, M), Name, Info)
    catch error:{clj2_unbound_var, _, _} -> {'clojure.lang.Var$Unbound', nil, {Ns, Name}}
    end.

is_realized({promise, _, Key}) -> ets:member(?PROMISE, Key);
is_realized({future, _, {Key, _}}) -> ets:member(?PROMISE, Key);
is_realized(X) -> clj2_lazy:is_realized(X).

%% for the printer
type_of({Tag, _, _}) when Tag =:= atom; Tag =:= volatile; Tag =:= agent; Tag =:= promise; Tag =:= future -> Tag;
type_of(_) -> none.

%% @doc A with-local-vars var: {local_var, nil, {Key, RootCell}}. Its root
%% starts unbound; with-local-vars binds it in this process for its body
%% (clj2_var bindings under {local_var, Key}), as the JVM's Var.create +
%% pushThreadBindings
local_var(_Init) -> {local_var, nil, {make_ref(), atom('$clj2_unbound')}}.

local_deref({local_var, _, {Key, Cell}}) ->
    case get({clj2_dyn, {local_var, Key}, local}) of
        [V | _] -> V;
        _ ->
            case deref(Cell) of
                '$clj2_unbound' -> erlang:error({clj2_unbound_var, local_var, Key});
                V -> V
            end
    end.

local_bound({local_var, _, {Key, Cell}}) ->
    is_list(get({clj2_dyn, {local_var, Key}, local})) andalso get({clj2_dyn, {local_var, Key}, local}) =/= []
        orelse deref(Cell) =/= '$clj2_unbound'.

%% @doc An atom's version: it changes with every write (cache stamps).
version(A = {atom, _, _}) -> element(1, current(A)).
