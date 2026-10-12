%%%-------------------------------------------------------------------
%%% @doc clj2_sorted — sorted maps and sets (clojure.core/sorted-map,
%%% sorted-set, ...-by, subseq, rsubseq).
%%%
%%% `{sorted_map, Meta, {Cmp, Tree, Count}}' and `{sorted_set, Meta, ...}':
%%% Tree is a persistent AVL tree ordered by Cmp — `default' (Clojure's
%%% compare) or a Clojure fn: a comparator returning a number, or a
%%% predicate like < (true means "before", as Clojure's AFunction/compare
%%% treats a boolean). Keys that compare 0 are the same key, so a sorted
%%% collection, unlike a hash one, finds a key by comparison.
%%% Node: {Key, Val, Left, Right, Height} | nil (a set's Val is nil).
%%%-------------------------------------------------------------------
-module(clj2_sorted).

-export([new/2, from_list/3, count/1, get/3, contains/2, assoc/3, dissoc/2, conj/2, disj/2,
         to_list/1, rseq/1, keys/1, vals/1, empty/1, subseq/5, compare_with/3, is_sorted/1]).

new(Kind, Cmp) -> {Kind, nil, {Cmp, nil, 0}}.

%% Pairs: [{K, V}] (a set's V is nil)
from_list(Kind, Cmp, Pairs) ->
    lists:foldl(fun({K, V}, Acc) -> put(Acc, K, V) end, new(Kind, Cmp), clj2_coll:to_list(Pairs)).

is_sorted({Kind, _, {_, _, _}}) when Kind =:= sorted_map; Kind =:= sorted_set -> true;
is_sorted(_) -> false.

count({_, _, {_, _, N}}) -> N.

empty({Kind, Meta, {Cmp, _, _}}) -> {Kind, Meta, {Cmp, nil, 0}}.

%%====================================================================
%% Comparison
%%====================================================================

compare_with(default, A, B) -> clj2_rt:compare(A, B);
compare_with(Cmp, A, B) ->
    case clj2_rt:invoke(Cmp, [A, B]) of
        N when is_integer(N) -> sign(N);
        F when is_float(F) -> sign(F);
        true -> -1;
        _ ->
            case clj2_rt:invoke(Cmp, [B, A]) of
                true -> 1;
                N when is_number(N), N > 0 -> -1;            % a comparator after all
                _ -> 0
            end
    end.

sign(N) when N < 0 -> -1;
sign(N) when N > 0 -> 1;
sign(_) -> 0.

%%====================================================================
%% Lookup and update
%%====================================================================

get({_, _, {Cmp, T, _}}, K, NotFound) ->
    case find(Cmp, T, K) of
        {ok, _, V} -> V;
        error -> NotFound
    end.

contains({_, _, {Cmp, T, _}}, K) -> find(Cmp, T, K) =/= error.

find(_, nil, _) -> error;
find(Cmp, {NK, NV, L, R, _}, K) ->
    case compare_with(Cmp, K, NK) of
        0 -> {ok, NK, NV};
        C when C < 0 -> find(Cmp, L, K);
        _ -> find(Cmp, R, K)
    end.

assoc({sorted_map, _, _} = S, K, V) -> put(S, K, V).

%% the stored key stays when a key that compares equal is put again (as
%% the JVM's TreeMap keeps it); the value is replaced
put({Kind, Meta, {Cmp, T, N}}, K, V) ->
    {T1, Added} = insert(Cmp, T, K, V),
    {Kind, Meta, {Cmp, T1, N + Added}}.

conj({sorted_set, _, _} = S, X) -> put(S, X, nil);
conj({sorted_map, _, _} = S, {vector, _, {K, V}}) -> put(S, K, V);
conj({sorted_map, _, _} = S, M) ->
    lists:foldl(fun(E, Acc) -> conj(Acc, E) end, S, clj2_coll:to_list(M)).

dissoc({sorted_map, _, _} = S, K) -> remove(S, K).
disj({sorted_set, _, _} = S, K) -> remove(S, K).

remove({Kind, Meta, {Cmp, T, N}} = S, K) ->
    case find(Cmp, T, K) of
        error -> S;
        {ok, _, _} -> {Kind, Meta, {Cmp, delete(Cmp, T, K), N - 1}}
    end.

%%====================================================================
%% Traversal
%%====================================================================

%% entries in order: [k v] vectors for a map, the keys for a set
to_list({sorted_map, _, {_, T, _}}) -> [clj2_coll:vector([K, V]) || {K, V} <- in_order(T, [])];
to_list({sorted_set, _, {_, T, _}}) -> [K || {K, _} <- in_order(T, [])].

rseq(S) ->
    case lists:reverse(to_list(S)) of
        [] -> nil;
        L -> L
    end.

keys(S = {sorted_map, _, _}) -> seq([K || {vector, _, {K, _}} <- to_list(S)]).
vals(S = {sorted_map, _, _}) -> seq([V || {vector, _, {_, V}} <- to_list(S)]).

seq([]) -> nil;
seq(L) -> L.

in_order(nil, Acc) -> Acc;
in_order({K, V, L, R, _}, Acc) -> in_order(L, [{K, V} | in_order(R, Acc)]).

%% @doc (subseq sc test key) / (rsubseq ...): the entries for which
%% (test (compare entry-key key) 0) holds, ascending or descending. Tests
%% are the fns < <= > >= (or any fn of the comparison and 0). End: none,
%% or {Test, Key} for the 5-argument forms.
subseq(S = {_, _, {Cmp, _, _}}, Test, Key, End, Dir) ->
    Keep = fun(E) ->
                   K = entry_key(S, E),
                   ok(Test, compare_with(Cmp, K, Key)) andalso
                       case End of
                           none -> true;
                           {ETest, EKey} -> ok(ETest, compare_with(Cmp, K, EKey))
                       end
           end,
    Es = [E || E <- to_list(S), Keep(E)],
    seq(case Dir of asc -> Es; desc -> lists:reverse(Es) end).

entry_key({sorted_map, _, _}, {vector, _, {K, _}}) -> K;
entry_key({sorted_set, _, _}, K) -> K.

ok(Test, C) -> clj2_rt:invoke(Test, [C, 0]) =:= true.

%%====================================================================
%% AVL tree
%%====================================================================

height(nil) -> 0;
height({_, _, _, _, H}) -> H.

node(K, V, L, R) -> {K, V, L, R, max(height(L), height(R)) + 1}.

%% → {Tree, 1 | 0}: 1 when a new key went in
insert(_, nil, K, V) -> {node(K, V, nil, nil), 1};
insert(Cmp, {NK, NV, L, R, _} = N, K, V) ->
    case compare_with(Cmp, K, NK) of
        0 -> {setelement(2, N, V), 0};                           % keep the stored key
        C when C < 0 -> {L1, A} = insert(Cmp, L, K, V), {balance(NK, NV, L1, R), A};
        _ -> {R1, A} = insert(Cmp, R, K, V), {balance(NK, NV, L, R1), A}
    end.

delete(_, nil, _) -> nil;
delete(Cmp, {NK, NV, L, R, _}, K) ->
    case compare_with(Cmp, K, NK) of
        C when C < 0 -> balance(NK, NV, delete(Cmp, L, K), R);
        C when C > 0 -> balance(NK, NV, L, delete(Cmp, R, K));
        0 ->
            case {L, R} of
                {nil, _} -> R;
                {_, nil} -> L;
                _ ->
                    {MK, MV} = min_entry(R),
                    balance(MK, MV, L, delete_min(R))
            end
    end.

min_entry({K, V, nil, _, _}) -> {K, V};
min_entry({_, _, L, _, _}) -> min_entry(L).

delete_min({_, _, nil, R, _}) -> R;
delete_min({K, V, L, R, _}) -> balance(K, V, delete_min(L), R).

balance(K, V, L, R) ->
    HL = height(L), HR = height(R),
    if
        HL > HR + 1 ->
            {LK, LV, LL, LR, _} = L,
            case height(LL) >= height(LR) of
                true -> node(LK, LV, LL, node(K, V, LR, R));
                false ->
                    {MK, MV, ML, MR, _} = LR,
                    node(MK, MV, node(LK, LV, LL, ML), node(K, V, MR, R))
            end;
        HR > HL + 1 ->
            {RK, RV, RL, RR, _} = R,
            case height(RR) >= height(RL) of
                true -> node(RK, RV, node(K, V, L, RL), RR);
                false ->
                    {MK, MV, ML, MR, _} = RL,
                    node(MK, MV, node(K, V, L, ML), node(RK, RV, MR, RR))
            end;
        true -> node(K, V, L, R)
    end.
