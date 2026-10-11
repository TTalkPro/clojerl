%%%-------------------------------------------------------------------
%%% @doc clj2_form — forms as values (the macro boundary).
%%%
%%% The compiler sees reader output: `clj2_loc'-wrapped data in reader
%%% shapes (`{vector, [], Items}' ...). A macro sees, and returns,
%%% runtime values (D8 shapes from {@link clj2_coll}). `to_data/1' is the
%%% one-way conversion; parse accepts both shapes, so macro output is
%%% parsed directly (it carries no positions: nodes inherit the position
%%% of the macro call).
%%%-------------------------------------------------------------------
-module(clj2_form).

-include("clojerl2.hrl").

-export([to_data/1, from_value/1, vector_items/1, map_pairs/1, set_items/1]).

%% @doc Reader form → runtime value (positions stripped).
to_data(W) when ?CLJ2_IS_LOC(W) -> to_data(?CLJ2_LOC_FORM(W));
to_data(L) when is_list(L) -> [to_data(X) || X <- L];
to_data({vector, [], Items}) when is_list(Items) ->
    clj2_coll:vector([to_data(X) || X <- Items]);
to_data({map, [], Pairs}) when is_list(Pairs) ->
    clj2_coll:hash_map_kv(lists:append([[to_data(K), to_data(V)] || {K, V} <- Pairs]));
to_data({set, [], Items}) when is_list(Items) ->
    clj2_coll:hash_set([to_data(X) || X <- Items]);
to_data(X) when is_atom(X); is_number(X); is_binary(X) -> X;
to_data({ratio, _, _} = X) -> X;
to_data({vector, _, T} = X) when is_tuple(T) -> X;           % already a value
to_data({map, _, M} = X) when is_map(M) -> X;
to_data({set, _, M} = X) when is_map(M) -> X;
to_data({var, [], X}) -> [var, to_data(X)];                 % #'x is (var x)
to_data({regex, [], Src}) -> {regex, nil, Src};              % a pattern value
to_data({tagged, [], uuid, S}) when is_binary(S) -> clj2_string:uuid(S);
to_data({Tag, _, B} = X) when (Tag =:= regex orelse Tag =:= uuid), is_binary(B) -> X;
to_data(X) -> erlang:error({clj2_form, {no_data_form, element(1, X)}}).

%% @doc A macro's result → a form: lazy seqs and lazy-tailed lists are
%% realized into proper lists, inside collections too.
from_value(L) when is_list(L) -> [from_value(X) || X <- clj2_coll:to_list(L)];
from_value({lazy_seq, _, _} = L) -> [from_value(X) || X <- clj2_coll:to_list(L)];
from_value({vector, _, T} = V) when is_tuple(T) ->
    clj2_coll:vector([from_value(X) || X <- clj2_coll:vec_to_list(V)]);
from_value({map, _, M}) when is_map(M) ->
    clj2_coll:hash_map_kv(lists:append([[from_value(K), from_value(V)] || {K, V} <- maps:to_list(M)]));
from_value({set, _, M}) when is_map(M) ->
    clj2_coll:hash_set([from_value(X) || X <- maps:keys(M)]);
from_value(X) -> X.

%% Collection views over both shapes (reader or value); `false' otherwise.
vector_items({vector, [], Items}) when is_list(Items) -> Items;
vector_items({vector, _, T}) when is_tuple(T) -> tuple_to_list(T);
vector_items(_) -> false.

map_pairs({map, [], Pairs}) when is_list(Pairs) -> Pairs;
map_pairs({map, _, M}) when is_map(M) -> maps:to_list(M);
map_pairs(_) -> false.

set_items({set, [], Items}) when is_list(Items) -> Items;
set_items({set, _, M}) when is_map(M) -> maps:keys(M);
set_items(_) -> false.
