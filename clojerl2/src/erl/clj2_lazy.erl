%%%-------------------------------------------------------------------
%%% @doc clj2_lazy — lazy seqs and delays (designs/03 §5.3 §6, clojerl2-019).
%%%
%%% Values:
%%%   lazy seq  {lazy_seq, Meta, {Key, Thunk}}   Thunk() → any seqable
%%%   delay     {delay, Meta, {Key, Thunk}}      Thunk() → any value
%%%
%%% A realized lazy seq is nil or a cons cell `[First | Rest]', where Rest
%%% may itself be lazy (an improper Erlang list), so walking a lazy chain
%%% realizes one element at a time: `first'/`rest' stay hd/tl.
%%%
%%% Memoization (BEAM terms are immutable, so the result lives outside
%%% the value, keyed by the cell's unique Key):
%%%   pdict (default) — per process, ~free; another process holding the
%%%       same lazy seq realizes it again (registered divergence: pure
%%%       thunks cannot tell, side-effecting thunks run once per process).
%%%   ets (switch: set_memo(ets)) — shared; realize-once by claiming the
%%%       cell with ets:update_counter (spike 003: 57 ns, exactly once);
%%%       racers that lose the claim wait for the winner's value.
%%% Both stores are bounded: past `memo_limit()' entries they are cleared
%%% and later walks realize again (registered divergence), so a long-lived
%%% process walking huge seqs does not grow without bound.
%%%
%%% Realizing a chain of lazy seqs that return lazy seqs is iterative
%%% (constant stack), as Clojure's LazySeq.sval loop.
%%%-------------------------------------------------------------------
-module(clj2_lazy).

-export([ new_table/0
        , lazy_seq/1
        , delay/1
        , seq/1
        , force/1
        , deref/1
        , is_realized/1
        , is_lazy/1
        , is_delay/1
        , doall/1
        , dorun/1
        , set_memo/1
        , memo/0
        , memo_limit/0
        , set_memo_limit/1
        ]).

-define(TAB, clj2_lazy).
-define(COUNT, '$clj2_lazy_count').
%% one persistent_term read per realization: {Mode, Limit}
-define(CONF, {?MODULE, conf}).

%% @private created by the clj2_ns server, which owns it
new_table() ->
    ?TAB = ets:new(?TAB, [named_table, public, set,
                          {read_concurrency, true}, {write_concurrency, true}]).

%%====================================================================
%% Construction
%%====================================================================

lazy_seq(Thunk) when is_function(Thunk, 0) -> {lazy_seq, nil, {make_ref(), Thunk}}.

delay(Thunk) when is_function(Thunk, 0) -> {delay, nil, {make_ref(), Thunk}}.

is_lazy({lazy_seq, _, {_, _}}) -> true;
is_lazy(_) -> false.

is_delay({delay, _, {_, _}}) -> true;
is_delay(_) -> false.

%%====================================================================
%% Realization
%%====================================================================

%% @doc The seq of a lazy seq: nil or a cons cell (whose tail may be lazy).
seq({lazy_seq, _, _} = L) -> realize_chain(L, [], conf());
seq(X) -> clj2_coll:seq(X).

realize_chain({lazy_seq, _, {Key, Thunk}}, Pending, Conf) ->
    case lookup(Key, Conf) of
        {ok, S} -> store_all(Pending, S, Conf), S;
        none ->
            case claim(Key, Conf) of
                {done, S} -> store_all(Pending, S, Conf), S;
                won ->
                    case Thunk() of
                        {lazy_seq, _, _} = Next -> realize_chain(Next, [Key | Pending], Conf);
                        V ->
                            S = clj2_coll:seq(V),
                            store_all([Key | Pending], S, Conf),
                            S
                    end
            end
    end.

force({delay, _, {Key, Thunk}}) ->
    Conf = conf(),
    case lookup(Key, Conf) of
        {ok, V} -> V;
        none ->
            case claim(Key, Conf) of
                {done, V} -> V;
                won -> V = Thunk(), store(Key, V, Conf), V
            end
    end;
force(X) -> X.

%% @doc deref of the reference types this layer knows (delay); atoms,
%% agents, futures arrive with clojerl2-018.
deref({delay, _, _} = D) -> force(D);
deref(X) -> erlang:error({clj2_not_derefable, X}).

is_realized({lazy_seq, _, {Key, _}}) -> lookup(Key, conf()) =/= none;
is_realized({delay, _, {Key, _}}) -> lookup(Key, conf()) =/= none;
is_realized(X) -> erlang:error({clj2_not_pending, X}).

%% @doc Realize every element; returns the (now realized) seq.
doall(Coll) -> walk(Coll), Coll.

dorun(Coll) -> walk(Coll), nil.

walk(Coll) ->
    case seq(Coll) of
        nil -> ok;
        [_ | T] -> walk(T)
    end.

%%====================================================================
%% Memo store
%%====================================================================

conf() -> persistent_term:get(?CONF, {pdict, 100000}).

memo() -> element(1, conf()).

%% @doc Switch the memo store for cells realized from now on.
set_memo(Mode) when Mode =:= pdict; Mode =:= ets ->
    clj2_ns:ensure_started(),
    persistent_term:put(?CONF, setelement(1, conf(), Mode)).

memo_limit() -> element(2, conf()).

set_memo_limit(N) when is_integer(N), N > 0 ->
    persistent_term:put(?CONF, setelement(2, conf(), N)).

lookup(Key, {Mode, _}) ->
    case Mode of
        pdict ->
            case get({?MODULE, Key}) of
                undefined -> none;
                {V} -> {ok, V}
            end;
        ets ->
            case ets:lookup(?TAB, Key) of
                [{_, _, {done, V}}] -> {ok, V};
                _ -> none
            end
    end.

%% pdict: the caller always realizes. ets: the first caller to bump the
%% claim counter realizes; the others wait for its value.
claim(Key, {Mode, _}) ->
    case Mode of
        pdict -> won;
        ets ->
            case ets:update_counter(?TAB, Key, {2, 1}, {Key, 0, pending}) of
                1 -> won;
                _ -> wait(Key, 5000)
            end
    end.

wait(Key, Ms) when Ms =< 0 -> erlang:error({clj2_lazy_realize_timeout, Key});
wait(Key, Ms) ->
    case ets:lookup(?TAB, Key) of
        [{_, _, {done, V}}] -> {done, V};
        _ -> receive after 1 -> wait(Key, Ms - 1) end
    end.

store_all([K], V, Conf) -> store(K, V, Conf);
store_all([], _V, _Conf) -> ok;
store_all([K | Ks], V, Conf) -> store(K, V, Conf), store_all(Ks, V, Conf).

store(Key, V, {Mode, Limit}) ->
    case Mode of
        pdict ->
            N = case get(?COUNT) of undefined -> 0; C -> C end,
            case N >= Limit of
                true -> flush_pdict(), put(?COUNT, 1);
                false -> put(?COUNT, N + 1)
            end,
            put({?MODULE, Key}, {V});
        ets ->
            case ets:info(?TAB, size) >= Limit of
                true -> ets:delete_all_objects(?TAB);
                false -> ok
            end,
            ets:insert(?TAB, {Key, 1, {done, V}})
    end.

flush_pdict() ->
    [erase(K) || {{?MODULE, _} = K, _} <- get()],
    ok.
