%%%-------------------------------------------------------------------
%%% @doc clj2_edn — clojure.edn's reader (clojerl2-039).
%%%
%%% EDN through clj2_reader's EDN mode (a closed dispatch table, no
%%% syntax-quote, ` ~ @ not constituents), then the read form becomes a
%%% value: collections (keeping reader metadata; duplicate keys and set
%%% elements throw), tagged elements through opts — :readers (keyed by
%%% the tag symbol) first, then the built-in #inst and #uuid, then
%%% :default (called with the tag and the value) — an unknown tag throws.
%%% Errors are RuntimeException as on the JVM (a bad number is a
%%% NumberFormatException), with the JVM's messages.
%%%-------------------------------------------------------------------
-module(clj2_edn).

-export([read_string/2]).

%% @doc (clojure.edn/read-string opts s)
read_string(_Opts, nil) -> nil;
read_string(Opts, S) when is_binary(S) ->
    erase(clj2_edn_discards),
    Read = clj2_reader:read(S, #{edn => true}),
    %% what #_ discarded is still read as EDN: an unknown tag in it throws
    [value(D, Opts) || D <- lists:reverse(case erase(clj2_edn_discards) of undefined -> []; L -> L end)],
    case Read of
        {ok, Form, _, _} -> value(Form, Opts);
        {eof, _} ->
            case clj2_coll:contains(Opts, ':eof') of
                true -> clj2_coll:get(Opts, ':eof');
                false -> fail(':RuntimeException', <<"EOF while reading">>)
            end;
        {error, _, Msg} ->
            Type = case Msg of
                       <<"Invalid number", _/binary>> -> ':NumberFormatException';
                       <<"Divide by zero">> -> ':ArithmeticException';
                       <<"Duplicate key", _/binary>> -> ':IllegalArgumentException';
                       _ -> ':RuntimeException'
                   end,
            fail(Type, Msg)
    end;
read_string(_, X) ->
    erlang:error(clj2_rt:ex_info(<<"class ", (atom_to_binary(clj2_class:class_of(X)))/binary,
                                   " cannot be cast to class java.lang.String">>,
                                 clj2_coll:hash_map_kv([':type', ':ClassCastException']), nil)).

%% a read form as the EDN value
value({clj2_loc, _, _, Inner, Meta}, Opts) when is_map(Meta), map_size(Meta) > 0 ->
    V = value(Inner, Opts),
    case is_tuple(V) andalso lists:member(element(1, V), [vector, map, set]) orelse is_list(V) of
        true -> clj2_rt:with_meta(V, clj2_coll:hash_map_kv(lists:append([[meta_key(K), value(X, Opts)]
                                                                          || {K, X} <- maps:to_list(Meta)])));
        false -> V
    end;
value({clj2_loc, _, _, Inner, _}, Opts) -> value(Inner, Opts);
value(L, Opts) when is_list(L) -> [value(X, Opts) || X <- L];
value({vector, [], Items}, Opts) when is_list(Items) -> clj2_coll:vector([value(X, Opts) || X <- Items]);
value({map, [], Pairs}, Opts) when is_list(Pairs) ->
    KVs = [{value(K, Opts), value(V, Opts)} || {K, V} <- Pairs],
    no_dup([K || {K, _} <- KVs]),
    clj2_coll:hash_map_kv(lists:append([[K, V] || {K, V} <- KVs]));
value({set, [], Items}, Opts) when is_list(Items) ->
    Vs = [value(X, Opts) || X <- Items],
    no_dup(Vs),
    clj2_coll:hash_set(Vs);
value({tagged, [], Tag, F}, Opts) when Tag =/= 'Inf', Tag =/= '-Inf', Tag =/= 'NaN' ->
    V = value(F, Opts),
    Readers = clj2_coll:get(Opts, ':readers'),
    case clj2_coll:get(Readers, Tag) of
        nil ->
            case Tag of
                inst -> clj2_inst:parse(V);
                uuid when is_binary(V) -> clj2_string:uuid(V);
                _ ->
                    case clj2_coll:get(Opts, ':default') of
                        nil -> fail(':RuntimeException', <<"No reader function for tag ", (atom_to_binary(Tag))/binary>>);
                        Default -> clj2_rt:invoke(Default, [Tag, V])
                    end
            end;
        R -> clj2_rt:invoke(R, [V])
    end;
value(X, _Opts) -> clj2_form:to_data(X).

%% ^Sym reads as {tag Sym}: the key is :tag
meta_key(tag) -> ':tag';
meta_key(K) -> K.

no_dup(Xs) ->
    case length(lists:usort(Xs)) =:= length(Xs) of
        true -> ok;
        false ->
            [D | _] = Xs -- lists:usort(Xs),
            fail(':IllegalArgumentException', <<"Duplicate key: ", (clj2_print:pr_str(D))/binary>>)
    end.

fail(Type, Msg) ->
    erlang:error(clj2_rt:ex_info(Msg, clj2_coll:hash_map_kv([':type', Type]), nil)).
