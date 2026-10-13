%%%-------------------------------------------------------------------
%%% @doc clj2_ref — the runtime's mutable cells and var objects
%%% (designs/03 §5.2, designs/10).
%%%
%%% Clojure's atom, volatile, agent, future, promise and ref are not
%%% provided: state and concurrency are Erlang processes. What is here
%%% serves the runtime itself:
%%%
%%% cell     `{cell, nil, {Key, Init}}': a shared mutable cell (an ETS row
%%%          updated by compare-and-swap): arrays, string builders, deftype
%%%          mutable fields, the global hierarchy, memoize, clojure.test.
%%% volatile `{volatile, nil, Key}': a cell in this process's dictionary:
%%%          the state of the stateful transducers.
%%% future   `{future, nil, {Key, Pid}}': a process running a fn with the
%%%          caller's dynamic bindings, its result in a row: pmap.
%%%
%%% A cell's row is not reclaimed when the value becomes garbage: BEAM has
%%% no finalizers (known divergence :state/explicit-lifetime).
%%%-------------------------------------------------------------------
-module(clj2_ref).

-export([new_tables/0]).
-export([cell/1, swap/3, reset/2,
         set_validator/2, get_validator/1, add_watch/3, remove_watch/2]).
-export([volatile/1, vreset/2]).
-export([future_call/1, future_cancel/1, is_future_done/1, is_future_cancelled/1]).
-export([local_var/1, local_bound/1]).
-export([deref/1, deref/3, is_realized/1, type_of/1, version/1]).

-define(ATOM, clj2_atom).
-define(PROMISE, clj2_promise).
-define(WAIT, clj2_promise_wait).

%% @private called by the clj2_ns server, which owns the tables
new_tables() ->
    ?ATOM = ets:new(?ATOM, [named_table, public, set, {read_concurrency, true}, {write_concurrency, true}]),
    ?PROMISE = ets:new(?PROMISE, [named_table, public, set, {read_concurrency, true}]),
    ?WAIT = ets:new(?WAIT, [named_table, public, bag]),
    ok.

%%====================================================================
%% cell (internal)
%%====================================================================

%% A shared mutable cell for the runtime's own use (arrays, string
%% builders, iterators, deftype mutable fields, the global hierarchy,
%% memoize ...): `{cell, nil, {Key, Init}}', its value an ETS row
%% `{Key, Version, Value}' made by the first write, updated by a
%% compare-and-swap loop on Version. Clojure's atom is not provided
%% (state lives in processes; designs/10).

cell(Init) -> {cell, nil, {make_ref(), Init}}.

current({cell, _, {Key, Init}}) ->
    case ets:lookup(?ATOM, Key) of
        [{_, Ver, Val}] -> {Ver, Val};
        [] -> {0, Init}
    end.

%% → New; Fun(Old) gives New
update(C = {cell, _, {Key, _}}, Fun) ->
    {Ver, Old} = current(C),
    New = Fun(Old),
    case cas(Key, Ver, New) of
        true -> New;
        false -> update(C, Fun)
    end.

%% compare-and-swap on the version: version 0 is "no row yet"
cas(Key, 0, New) ->
    ets:insert_new(?ATOM, {Key, 1, New});
cas(Key, Ver, New) ->
    Spec = [{{Key, Ver, '_'}, [], [{{{const, Key}, Ver + 1, {const, New}}}]}],
    ets:select_replace(?ATOM, Spec) =:= 1.

%% @doc (swap) a cell: its value becomes (apply F value Args)
swap(C, F, Args) -> update(C, fun(Old) -> clj2_rt:invoke(F, [Old | list(Args)]) end).

%% @doc a cell's value becomes New
reset(C, New) -> update(C, fun(_) -> New end).

set_validator(V = {var, _, _}, F) -> clj2_rt:set_var_validator(V, F);
set_validator(G, _) -> not_a_ref(G).

get_validator(V = {var, _, _}) -> clj2_rt:var_validator(V);
get_validator(G) -> not_a_ref(G).

add_watch(V = {var, _, _}, K, F) -> clj2_rt:update_var_watches(V, fun(W) -> W#{K => F} end);
add_watch(X, _, _) -> not_a_ref(X).

remove_watch(V = {var, _, _}, K) -> clj2_rt:update_var_watches(V, fun(W) -> maps:remove(K, W) end);
remove_watch(X, _) -> not_a_ref(X).

not_a_ref(X) ->
    erlang:error(clj2_rt:ex_info(iolist_to_binary(["class ", atom_to_binary(clj2_class:class_of(X)),
                                                   " cannot be cast to class clojure.lang.IRef"]),
                                 clj2_coll:hash_map_kv([':type', ':ClassCastException']), nil)).

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
%% result rows (the runtime's futures: pmap)
%%====================================================================

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
%% deref, realized?
%%====================================================================

deref(C = {cell, _, _}) -> element(2, current(C));
deref(V = {volatile, _, _}) -> vderef(V);
deref({future, _, {Key, Pid}}) -> {ok, R} = await_row(Key, infinity, Pid), future_result(R);
deref({var, _, {Ns, Name}}) -> var_value(Ns, Name);
deref({local_var, _, _} = L) -> local_deref(L);                 % with-local-vars
deref({clj2_reduced, X}) -> X;
deref(X) -> clj2_lazy:deref(X).                              % delay

%% (deref ref timeout-ms timeout-val): the runtime's futures
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

is_realized({future, _, {Key, _}}) -> ets:member(?PROMISE, Key);
is_realized(X) -> clj2_lazy:is_realized(X).

%% for the printer
type_of({Tag, _, _}) when Tag =:= volatile; Tag =:= future -> Tag;
type_of(_) -> none.

%% @doc A with-local-vars var: {local_var, nil, {Key, RootCell}}. Its root
%% starts unbound; with-local-vars binds it in this process for its body
%% (clj2_var bindings under {local_var, Key}), as the JVM's Var.create +
%% pushThreadBindings
local_var(_Init) -> {local_var, nil, {make_ref(), cell('$clj2_unbound')}}.

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

%% @doc A cell's version: it changes with every write (cache stamps).
version(C = {cell, _, _}) -> element(1, current(C)).
