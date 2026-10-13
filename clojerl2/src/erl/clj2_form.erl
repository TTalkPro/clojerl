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

-export([to_data/1, from_value/1, vector_items/1, map_pairs/1, set_items/1, no_dup/1,
         tag_value/2, record_tag/1, resolve_tags/1]).

%% @doc Reader form → runtime value (positions stripped).
to_data({clj2_loc, _, _, Inner, Meta}) when is_map(Meta), map_size(Meta) > 0,
                                           (is_list(Inner) orelse is_tuple(Inner) andalso
                                            (element(1, Inner) =:= vector orelse element(1, Inner) =:= map
                                             orelse element(1, Inner) =:= set)) ->
    clj2_rt:with_meta(to_data(Inner), clj2_coll:hash_map_kv(lists:append([[K, V] || {K, V} <- maps:to_list(Meta)])));
to_data(W) when ?CLJ2_IS_LOC(W) -> to_data(?CLJ2_LOC_FORM(W));
to_data(L) when is_list(L) -> [to_data(X) || X <- L];
to_data({vector, [], Items}) when is_list(Items) ->
    clj2_coll:vector([to_data(X) || X <- Items]);
to_data({map, [], Pairs}) when is_list(Pairs) ->
    Kvs = [{to_data(K), to_data(V)} || {K, V} <- Pairs],
    no_dup([K || {K, _} <- Kvs]),
    clj2_coll:hash_map_kv(lists:append([[K, V] || {K, V} <- Kvs]));
to_data({set, [], Items}) when is_list(Items) ->
    Xs = [to_data(X) || X <- Items],
    no_dup(Xs),
    clj2_coll:hash_set(Xs);
to_data(X) when is_atom(X); is_number(X); is_binary(X) -> X;
to_data({ratio, _, _} = X) -> X;
to_data({vector, _, T} = X) when is_tuple(T) -> X;           % already a value
to_data({map, _, M} = X) when is_map(M) -> X;
to_data({set, _, M} = X) when is_map(M) -> X;
to_data({var, [], X}) -> [var, to_data(X)];                 % #'x is (var x)
to_data({regex, [], Src}) -> {regex, nil, Src};              % a pattern value
to_data({tagged, [], uuid, S}) when is_binary(S) -> clj2_string:uuid(S);
to_data({tagged, [], inst, S}) when is_binary(S) -> clj2_inst:parse(S);
to_data({'java.util.Date', _, _} = X) -> X;
%% ##NaN, 1.5M, #inst ...: kept as they are read; evaluated, they raise
%% (clj2_p_parse), and as a case constant they match nothing
to_data({tagged, [], Tag, F}) when is_atom(Tag), Tag =/= 'NaN', Tag =/= 'Inf', Tag =/= '-Inf' ->
    tag_value(Tag, to_data(F));
to_data({tagged, [], Tag, F}) when is_atom(Tag) -> {tagged, [], Tag, to_data(F)};
%% #=(...): evaluated when it is read
to_data({read_eval, [], F}) -> read_eval(to_data(F));
to_data({bigdec, [], B}) when is_binary(B) -> clj2_decimal:parse(B);
to_data({decimal, _, _} = X) -> X;
to_data({Tag, _, B} = X) when (Tag =:= regex orelse Tag =:= uuid), is_binary(B) -> X;
to_data(X) -> erlang:error({clj2_form, {no_data_form, element(1, X)}}).

%% @doc A tagged literal's value, as the JVM reader finds a reader
%% function for the tag: *data-readers*, then a record class
%% (#ns.Rec{..} / #ns.Rec[..]), then *default-data-reader-fn*; none: the
%% tagged form is kept (evaluated, it raises: clj2_rt:unsupported_tag/1).
tag_value(Tag, V) ->
    Readers = dyn('*data-readers*'),
    case Readers =/= nil andalso clj2_coll:get(Readers, Tag) of
        F when F =/= false, F =/= nil -> clj2_rt:invoke(F, [V]);
        _ ->
            case record_tag(Tag) of
                {ok, Map, _} when is_tuple(V), element(1, V) =:= map -> clj2_rt:invoke(Map, [V]);
                {ok, _, Pos} -> clj2_rt:invoke(Pos, clj2_coll:to_list(V));
                none ->
                    case dyn('*default-data-reader-fn*') of
                        nil -> {tagged, [], Tag, V};
                        F -> clj2_rt:invoke(F, [Tag, V])
                    end
            end
    end.

%% @doc Tagged literals left in a quoted value (a record literal whose
%% defrecord had not run when it was compiled), resolved now, nested
%% ones first.
resolve_tags({tagged, [], Tag, V}) when Tag =/= 'NaN', Tag =/= 'Inf', Tag =/= '-Inf' ->
    tag_value(Tag, resolve_tags(V));
resolve_tags(L) when is_list(L) -> [resolve_tags(X) || X <- L];
resolve_tags({vector, _, T} = V) when is_tuple(T) ->
    clj2_coll:vector([resolve_tags(X) || X <- clj2_coll:vec_to_list(V)]);
resolve_tags({map, _, M}) when is_map(M) ->
    clj2_coll:hash_map_kv(lists:append([[resolve_tags(K), resolve_tags(V)] || {K, V} <- maps:to_list(M)]));
resolve_tags({set, _, M}) when is_map(M) -> clj2_coll:hash_set([resolve_tags(X) || X <- maps:keys(M)]);
resolve_tags(X) -> X.

%% @doc ns.Rec → the record's map->Rec and ->Rec fns, if it is one
record_tag(Tag) ->
    Name = atom_to_binary(Tag),
    case string:split(Name, <<".">>, trailing) of
        [Ns, Rec] when Ns =/= <<>>, Rec =/= <<>> ->
            NsA = binary_to_atom(Ns),
            try {ok, clj2_ref:deref(clj2_rt:var(NsA, binary_to_atom(<<"map->", Rec/binary>>))),
                 clj2_ref:deref(clj2_rt:var(NsA, binary_to_atom(<<"->", Rec/binary>>)))}
            catch _:_ -> none
            end;
        _ -> none
    end.

read_eval(F) ->
    case dyn('*read-eval*') of
        false -> erlang:error(clj2_rt:ex_info(<<"EvalReader not allowed when *read-eval* is false.">>,
                                              clj2_coll:hash_map_kv([':type', ':RuntimeException']), nil));
        _ -> clj2_rt_eval:eval(F)
    end.

dyn(Name) -> try clj2_var:deref('clojure.core', Name) catch _:_ -> nil end.

%% a literal's keys are distinct, as the JVM reader demands
no_dup([]) -> ok;
no_dup([X | Xs]) ->
    case lists:any(fun(Y) -> clj2_coll:equals(X, Y) end, Xs) of
        true -> erlang:error(clj2_rt:ex_info(<<"Duplicate key: ", (clj2_print:pr_str(X))/binary>>,
                                             clj2_coll:hash_map_kv([':type', ':IllegalArgumentException']), nil));
        false -> no_dup(Xs)
    end.

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
