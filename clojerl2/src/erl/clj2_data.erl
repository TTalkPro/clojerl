%%%-------------------------------------------------------------------
%%% @doc clj2_data — Clojure values ↔ plain Erlang terms (designs/10,
%%% clojerl2-046).
%%%
%%% Clojure code can work on a host's Erlang maps, lists and binaries in
%%% place (clj2_coll treats an Erlang map as a map). What it builds with
%%% its own literals and functions is Clojure data ({vector, ...},
%%% {map, ...}, keywords ...); `to_erl' turns a value into plain terms a
%%% host can store or encode, `from_erl' the other way.
%%%
%%%   to_erl(X)  vector, list, lazy seq, set → list; Clojure map → map;
%%%              keyword :k → <<"k">> (:a/b → <<"a/b">>); nil stays nil;
%%%              records → maps; anything else as it is
%%%   to_erl(X, #{nil => null, keywords => binary | atom | keep,
%%%               sets => list | map})
%%%   from_erl(X) Erlang map → Clojure map (deeply), lists stay lists
%%%   from_erl(X, #{null => nil, keys => keyword | keep, lists => vector | list})
%%%              (keys => keyword: binary and atom keys become keywords)
%%%
%%% Both walk the whole value: use them at the edge, once per value.
%%%-------------------------------------------------------------------
-module(clj2_data).

-export([to_erl/1, to_erl/2, from_erl/1, from_erl/2, clj_opts/1]).

-spec to_erl(term()) -> term().
to_erl(X) -> to_erl(X, #{}).

-spec to_erl(term(), map()) -> term().
to_erl(X, Opts) -> te(X, opts_to(Opts)).

opts_to(Opts) ->
    {maps:get(nil, Opts, nil), maps:get(keywords, Opts, binary), maps:get(sets, Opts, list)}.

te(nil, {Nil, _, _}) -> Nil;
te(A, {_, Kw, _} = O) when is_atom(A), A =/= true, A =/= false ->
    case clj2_rt:is_keyword(A) andalso Kw of
        false -> A;
        keep -> A;
        binary -> keyword_name(A);
        atom -> binary_to_atom(keyword_name(A));
        _ -> te_kw_default(A, O)
    end;
te(M, O) when is_map(M) -> maps:from_list([{te(K, O), te(V, O)} || {K, V} <- maps:to_list(M)]);
te(L, O) when is_list(L) -> [te(X, O) || X <- clj2_coll:to_list(L)];
te({lazy_seq, _, _} = L, O) -> [te(X, O) || X <- clj2_coll:to_list(L)];
te({vector, _, T} = V, O) when is_tuple(T) -> [te(X, O) || X <- clj2_coll:vec_to_list(V)];
te({map, _, M}, O) when is_map(M) -> te(M, O);
te({set, _, M}, {_, _, Sets} = O) when is_map(M) ->
    case Sets of
        map -> maps:from_list([{te(X, O), true} || X <- maps:keys(M)]);
        _ -> [te(X, O) || X <- lists:sort(maps:keys(M))]
    end;
te({Tag, _, {_, _, _}} = S, O) when Tag =:= sorted_map ->
    maps:from_list([{te(K, O), te(V, O)} || {vector, _, {K, V}} <- clj2_coll:to_list(S)]);
te({Tag, _, {_, _, _}} = S, O) when Tag =:= sorted_set -> [te(X, O) || X <- clj2_coll:to_list(S)];
te({Tag, _, M}, O) when is_atom(Tag), is_map(M), Tag =/= 'clojure.lang.ExceptionInfo' -> te(M, O);   % a record
te({transient, _, C}, O) -> te(C, O);
te(X, _) -> X.

te_kw_default(A, _) -> keyword_name(A).

keyword_name(K) ->
    case clj2_rt:namespace(K) of
        nil -> clj2_rt:name(K);
        Ns -> <<Ns/binary, $/, (clj2_rt:name(K))/binary>>
    end.

-spec from_erl(term()) -> term().
from_erl(X) -> from_erl(X, #{}).

-spec from_erl(term(), map()) -> term().
from_erl(X, Opts) ->
    fe(X, {maps:get(null, Opts, null), maps:get(keys, Opts, keep), maps:get(lists, Opts, list)}).

fe(null, {nil, _, _}) -> nil;
fe(M, {_, Keys, _} = O) when is_map(M) ->
    clj2_coll:hash_map_kv(lists:append([[fe_key(K, Keys), fe(V, O)] || {K, V} <- maps:to_list(M)]));
fe(L, {_, _, Lists} = O) when is_list(L) ->
    Xs = [fe(X, O) || X <- L],
    case Lists of
        vector -> clj2_coll:vector(Xs);
        _ -> Xs
    end;
fe(X, _) -> X.

fe_key(K, keyword) when is_binary(K) -> clj2_rt:keyword(K);
%% an atom key (an Erlang record-ish map: #{route => .., format => ..}) too
fe_key(K, keyword) when is_atom(K), K =/= nil, K =/= true, K =/= false ->
    case clj2_rt:is_keyword(K) of
        true -> K;
        false -> clj2_rt:keyword(atom_to_binary(K))
    end;
fe_key(K, _) -> K.

%% @doc Options written in Clojure ({:nil :null, :keys :keyword}) as the
%% Erlang options map above
clj_opts(nil) -> #{};
clj_opts(Opts) ->
    maps:from_list([{plain(K), plain(V)} || {vector, _, {K, V}} <- clj2_coll:to_list(Opts)]).

plain(nil) -> nil;
plain(A) when is_atom(A) ->
    case clj2_rt:is_keyword(A) of
        true -> binary_to_atom(clj2_rt:name(A));
        false -> A
    end;
plain(X) -> X.
