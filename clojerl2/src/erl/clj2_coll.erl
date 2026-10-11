%%%-------------------------------------------------------------------
%%% @doc clj2_coll — collection values (designs/03 §1, D8), provisional.
%%%
%%%   vector  {vector, Meta, Data}   Data is a tuple for now; the 32-way
%%%                                  trie replaces it behind this API
%%%   map     {map, Meta, Map}       wraps a native Erlang map (03 §1.3)
%%%   set     {set, Meta, Map}       values are `nil'
%%%
%%% Meta is `nil' or a map. Lists are Erlang lists, `nil' is the empty seq.
%%% This module is the only code that knows these shapes: literal
%%% construction, syntax-quote helpers, and the layer-0 primitives
%%% clojure.core's kernel is written on (designs/03 §8).
%%%
%%% Seqs: nil, Erlang lists, lazy seqs ({@link clj2_lazy}), and cons
%%% cells whose tail is lazy (`[X | LazySeq]', an improper list). seq/1
%%% realizes at most the first element; to_list/1 realizes everything.
%%%-------------------------------------------------------------------
-module(clj2_coll).

-export([ vector/1
        , hash_map_kv/1
        , hash_set/1
        , vec_to_list/1
        , is_vector/1
        , is_hash_map/1
        , is_hash_set/1
        , to_list/1
        , concat/1
          %% layer-0 collection primitives used by clojure.core (00-kernel)
        , seq/1
        , is_seq/1
        , cons/2
        , count/1
        , nth/2, nth/3
        , get/2, get/3
        , assoc/3
        , dissoc/2
        , conj/2
        , contains/2
        , keys/1
        , vals/1
        , equals/2
        ]).

%% @doc A vector of the elements of an Erlang list.
vector(L) when is_list(L) -> {vector, nil, list_to_tuple(L)}.

%% @doc A map from a flat `[K1, V1, K2, V2, ...]' list; later keys win.
hash_map_kv(KVs) -> {map, nil, kv(KVs, #{})}.

kv([], M) -> M;
kv([K, V | Rest], M) -> kv(Rest, M#{K => V});
kv([_], _) -> erlang:error({clj2_odd_map_literal}).

hash_set(L) when is_list(L) -> {set, nil, maps:from_keys(L, nil)}.

vec_to_list({vector, _, T}) -> tuple_to_list(T).

is_vector({vector, _, T}) when is_tuple(T) -> true;
is_vector(_) -> false.

%% @doc Elements of a seqable as an Erlang list (nil, lists, vectors,
%% sets, maps as `[K, V]' vectors).
to_list(nil) -> [];
to_list(L) when is_list(L) ->
    try length(L) of
        _ -> L                                  % proper: as is
    catch
        error:badarg -> walk(L, [])             % a lazy tail somewhere
    end;
to_list({lazy_seq, _, _} = L) -> walk(L, []);
to_list(B) when is_binary(B) -> unicode:characters_to_list(B);   % a string is a seq of chars
to_list({vector, _, T}) when is_tuple(T) -> tuple_to_list(T);
to_list({set, _, M}) -> maps:keys(M);
to_list({map, _, M}) -> [vector([K, V]) || {K, V} <- maps:to_list(M)];
to_list({Tag, _, M}) when is_atom(Tag), is_map(M) -> [vector([K, V]) || {K, V} <- maps:to_list(M)];
to_list(X) -> erlang:error({clj2_not_seqable, X}).

%% @doc Concatenate seqables into a list (syntax-quote's `~@').
concat(Parts) -> lists:append([to_list(P) || P <- Parts]).

is_hash_map({map, _, M}) when is_map(M) -> true;
is_hash_map(_) -> false.

is_hash_set({set, _, M}) when is_map(M) -> true;
is_hash_set(_) -> false.

%%====================================================================
%% Layer-0 primitives
%%====================================================================

%% realize a seq with lazy parts into a proper list
walk(S, Acc) ->
    case clj2_lazy:seq(S) of
        nil -> lists:reverse(Acc);
        [H | T] when is_list(T) ->
            try length(T) of
                _ -> lists:reverse(Acc, [H | T])
            catch
                error:badarg -> walk(T, [H | Acc])
            end;
        [H | T] -> walk(T, [H | Acc])
    end.

%% @doc A non-empty seq, or nil: lists and cons cells as they are (a lazy
%% tail stays lazy), a lazy seq realized to its first cell, other
%% collections as a list.
seq(nil) -> nil;
seq([]) -> nil;
seq([_ | _] = L) -> L;
seq({lazy_seq, _, _} = L) -> clj2_lazy:seq(L);
seq(X) ->
    case to_list(X) of
        [] -> nil;
        L -> L
    end.

is_seq(L) when is_list(L) -> true;
is_seq({lazy_seq, _, _}) -> true;
is_seq(_) -> false.

%% @doc (cons x coll): a list, O(1) on lists.
cons(X, L) when is_list(L) -> [X | L];
cons(X, nil) -> [X];
cons(X, {lazy_seq, _, _} = L) -> [X | L];       % stays lazy
cons(X, Coll) -> [X | to_list(Coll)].

count(nil) -> 0;
count(L) when is_list(L) -> length(to_list(L));
count({lazy_seq, _, _} = L) -> length(to_list(L));
count({vector, _, T}) -> tuple_size(T);
count({map, _, M}) -> map_size(M);
count({set, _, M}) -> map_size(M);
count(B) when is_binary(B) -> string:length(B);
count({Tag, _, M}) when is_atom(Tag), is_map(M) -> map_size(M);
count(X) -> erlang:error({clj2_not_countable, X}).

nth(Coll, I) ->
    case nth(Coll, I, '$clj2_none') of
        '$clj2_none' -> erlang:error({clj2_index_out_of_bounds, I});
        V -> V
    end.

nth({vector, _, T}, I, _) when is_integer(I), I >= 0, I < tuple_size(T) -> element(I + 1, T);
nth(L, I, NotFound) when (is_list(L) orelse element(1, L) =:= lazy_seq), is_integer(I), I >= 0 ->
    nth_seq(seq(L), I, NotFound);
%% a string is indexed by code point, walking the UTF-8 binary: O(n)
%% (JVM: UTF-16 units, O(1); known divergence :string/code-point-indexing)
nth(B, I, NotFound) when is_binary(B), is_integer(I), I >= 0 -> nth_utf8(B, I, NotFound);
nth(nil, _, NotFound) -> NotFound;
nth(_, _, NotFound) -> NotFound.

nth_utf8(<<C/utf8, _/binary>>, 0, _) -> C;
nth_utf8(<<_/utf8, Rest/binary>>, I, NotFound) -> nth_utf8(Rest, I - 1, NotFound);
nth_utf8(_, _, NotFound) -> NotFound.

nth_seq(nil, _, NotFound) -> NotFound;
nth_seq([H | _], 0, _) -> H;
nth_seq([_ | T], I, NotFound) -> nth_seq(seq(T), I - 1, NotFound).

get(Coll, K) -> get(Coll, K, nil).

get({map, _, M}, K, NotFound) -> maps:get(K, M, NotFound);
get({set, _, M}, K, NotFound) ->
    case is_map_key(K, M) of
        true -> K;
        false -> NotFound
    end;
get({vector, _, T}, I, NotFound) when is_integer(I) ->
    case I >= 0 andalso I < tuple_size(T) of
        true -> element(I + 1, T);
        false -> NotFound
    end;
get({Tag, _, M}, K, NotFound) when is_atom(Tag), is_map(M) -> maps:get(K, M, NotFound);  % record
get(_, _, NotFound) -> NotFound.

assoc(nil, K, V) -> {map, nil, #{K => V}};
assoc({map, Meta, M}, K, V) -> {map, Meta, M#{K => V}};
assoc({vector, Meta, T}, I, V) when is_integer(I), I >= 0, I < tuple_size(T) ->
    {vector, Meta, setelement(I + 1, T, V)};
assoc({vector, Meta, T}, I, V) when I =:= tuple_size(T) ->
    {vector, Meta, erlang:append_element(T, V)};
assoc({Tag, Meta, M}, K, V) when is_atom(Tag), is_map(M) -> {Tag, Meta, M#{K => V}};   % record
assoc(X, K, _) -> erlang:error({clj2_cannot_assoc, X, K}).

dissoc(nil, _) -> nil;
dissoc({map, Meta, M}, K) -> {map, Meta, maps:remove(K, M)}.

%% @doc conj: lists grow at the front, vectors at the end, maps take a
%% [k v] vector, sets add; nil conj is a list.
conj(nil, X) -> [X];
conj(L, X) when is_list(L) -> [X | L];
conj({lazy_seq, _, _} = L, X) -> [X | L];
conj({vector, Meta, T}, X) -> {vector, Meta, erlang:append_element(T, X)};
conj({set, Meta, M}, X) -> {set, Meta, M#{X => nil}};
conj({map, Meta, M}, {vector, _, {K, V}}) -> {map, Meta, M#{K => V}};
conj({map, Meta, M}, {map, _, M2}) -> {map, Meta, maps:merge(M, M2)};
conj(C, X) -> erlang:error({clj2_cannot_conj, C, X}).

contains({map, _, M}, K) -> is_map_key(K, M);
contains({set, _, M}, K) -> is_map_key(K, M);
contains({vector, _, T}, I) when is_integer(I) -> I >= 0 andalso I < tuple_size(T);
contains({Tag, _, M}, K) when is_atom(Tag), is_map(M) -> is_map_key(K, M);
contains(_, _) -> false.

keys({map, _, M}) -> seq(maps:keys(M));
keys({Tag, _, M}) when is_atom(Tag), is_map(M) -> seq(maps:keys(M));
keys(nil) -> nil.

vals({map, _, M}) -> seq(maps:values(M));
vals({Tag, _, M}) when is_atom(Tag), is_map(M) -> seq(maps:values(M));
vals(nil) -> nil.

%% @doc Clojure `=': sequential collections (lists, vectors) equal when
%% their elements are; maps and sets by content; metadata ignored;
%% everything else by `=:=' (so 1 and 1.0 differ, as in Clojure).
equals(A, B) when A =:= B -> true;
equals({map, _, A}, {map, _, B}) when map_size(A) =:= map_size(B) ->
    lists:all(fun({K, V}) -> is_map_key(K, B) andalso equals(V, maps:get(K, B)) end,
              maps:to_list(A));
equals({set, _, A}, {set, _, B}) -> maps:keys(A) =:= maps:keys(B);
%% records: same type, equal fields (metadata ignored)
equals({Tag, _, A}, {Tag, _, B}) when is_atom(Tag), is_map(A), is_map(B) ->
    equals({map, nil, A}, {map, nil, B});
equals(A, B) ->
    case is_sequential(A) andalso is_sequential(B) of
        true -> seq_equals(to_list(A), to_list(B));
        false -> false
    end.

is_sequential(L) when is_list(L) -> true;
is_sequential({lazy_seq, _, _}) -> true;
is_sequential({vector, _, T}) when is_tuple(T) -> true;
is_sequential(_) -> false.

seq_equals([], []) -> true;
seq_equals([X | Xs], [Y | Ys]) -> equals(X, Y) andalso seq_equals(Xs, Ys);
seq_equals(_, _) -> false.
