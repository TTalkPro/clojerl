%%%-------------------------------------------------------------------
%%% @doc clj2_multi — multimethods (clojerl2-017, designs/03 §5.1).
%%%
%%% A multimethod is `{multifn, nil, {Ns, Name}}'; calling it computes the
%%% dispatch value and looks the method up in the ETS table `clj2_multi':
%%%
%%%   {{meta, Key}, #{dispatch, default, hierarchy, prefers, version}}
%%%   {{method, Key, DispatchValue}, Fun}
%%%   {{cache, Key, DispatchValue}, Stamp, Fun}
%%%
%%% An exact dispatch value is one lookup. Otherwise the best method by
%%% isa? and the prefer table is found by clojure.core's own logic
%%% (find-best-method, Clojure) and cached under a stamp of the
%%% multimethod's version and the hierarchy's: defmethod, remove-method,
%%% prefer-method and derive all invalidate it. Then the :default method
%%% (the default dispatch value), else an error.
%%%
%%% A call fetches its method when it starts, so a defmethod is seen by
%%% the next call and never by one already running (the two-version
%%% behaviour designs/03 §5.1 asks of dispatch modules; methods are
%%% closures made at load time, which a generated module could not hold
%%% as constants, so the table is data).
%%%-------------------------------------------------------------------
-module(clj2_multi).

-export([new_table/0]).
-export([hierarchy_value/1]).
-export([new/5, invoke/2, add_method/3, remove_method/2, remove_all_methods/1,
         prefer_method/3, prefers/1, methods/1, get_method/2, method_entries/1,
         dispatch_fn/1, default_value/1, hierarchy/1, name/1]).

-define(TAB, clj2_multi).

%% @private called by the clj2_ns server, which owns the table
new_table() ->
    ?TAB = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    ok.

%% @doc (defmulti name dispatch-fn :default d :hierarchy #'h). A second
%% defmulti of the same name keeps the existing one (as Clojure's
%% defmulti does, so reloading a namespace keeps its methods).
%% Hierarchy: nil (the global one) or a var.
new(Ns, Name, Dispatch, Default, Hierarchy) ->
    clj2_ns:ensure_started(),
    Key = {Ns, Name},
    _ = ets:insert_new(?TAB, {{meta, Key}, #{dispatch => Dispatch, default => Default,
                                            hierarchy => Hierarchy, prefers => #{},
                                            version => 0}}),
    {multifn, nil, Key}.

meta({multifn, _, Key}) -> meta(Key);
meta(Key) ->
    [{_, M}] = ets:lookup(?TAB, {meta, Key}),
    M.

update_meta(Key, Fun) ->
    true = ets:insert(?TAB, {{meta, Key}, Fun(meta(Key))}), ok.

%% every change to the methods or the prefer table: cached choices go
bump(Key) -> update_meta(Key, fun(M = #{version := V}) -> M#{version := V + 1} end).

%% @doc The multimethod's qualified name, a symbol
name({multifn, _, {Ns, Name}}) -> qualified(Ns, Name).

qualified(Ns, Name) -> binary_to_atom(iolist_to_binary([atom_to_binary(Ns), "/", atom_to_binary(Name)])).
dispatch_fn(MF) -> maps:get(dispatch, meta(MF)).
default_value(MF) -> maps:get(default, meta(MF)).
hierarchy(MF) -> maps:get(hierarchy, meta(MF)).

%%====================================================================
%% Calling
%%====================================================================

invoke(MF = {multifn, _, Key}, Args) ->
    #{dispatch := D, default := Default} = Meta = meta(Key),
    DV = clj2_rt:invoke(D, Args),
    F = case ets:lookup(?TAB, {method, Key, DV}) of
            [{_, Fun}] -> Fun;
            [] -> resolve(MF, Key, DV, Default, Meta)
        end,
    clj2_rt:invoke(F, Args).

resolve(MF, Key, DV, Default, Meta) ->
    Stamp = {maps:get(version, Meta), hierarchy_stamp(Meta)},
    case ets:lookup(?TAB, {cache, Key, DV}) of
        [{_, Stamp, Fun}] -> Fun;
        _ ->
            Fun = case best(MF, DV) of
                      nil ->
                          case ets:lookup(?TAB, {method, Key, Default}) of
                              [{_, DF}] -> DF;
                              [] -> no_method(Key, DV)
                          end;
                      Found -> Found
                  end,
            ets:insert(?TAB, {{cache, Key, DV}, Stamp, Fun}),
            Fun
    end.

%% the best method by isa? and prefers, from clojure.core (it needs the
%% hierarchy fns); nil when no method's dispatch value is an ancestor
best(MF, DV) ->
    F = clj2_ref:deref({var, nil, {'clojure.core', 'find-best-method'}}),
    clj2_rt:invoke(F, [MF, DV]).

%% the global hierarchy is clojure.core's atom; a :hierarchy option is a
%% var, an atom or a hierarchy map (vars and atoms are dereferenced until
%% the map): the stamp changes when any of them does
hierarchy_stamp(#{hierarchy := nil}) ->
    clj2_ref:version(clj2_ref:deref({var, nil, {'clojure.core', 'global-hierarchy'}}));
hierarchy_stamp(#{hierarchy := H}) -> stamp(H).

stamp({var, _, _} = V) -> stamp(clj2_ref:deref(V));
stamp({cell, _, _} = A) -> {clj2_ref:version(A), stamp(clj2_ref:deref(A))};
stamp(H) -> erlang:phash2(H).

%% @doc A :hierarchy option's hierarchy map (vars and atoms dereferenced)
hierarchy_value({var, _, _} = V) -> hierarchy_value(clj2_ref:deref(V));
hierarchy_value({cell, _, _} = A) -> hierarchy_value(clj2_ref:deref(A));
hierarchy_value(H) -> H.

no_method({Ns, Name}, DV) ->
    erlang:error(clj2_rt:ex_info(
                   iolist_to_binary(["No method in multimethod '", atom_to_binary(Name),
                                     "' for dispatch value: ", clj2_print:pr_str(DV)]),
                   clj2_coll:hash_map_kv([':multimethod', qualified(Ns, Name),
                                          ':dispatch-value', DV,
                                          ':type', ':IllegalArgumentException']), nil)).

%%====================================================================
%% The method table
%%====================================================================

add_method(MF = {multifn, _, Key}, DV, Fun) ->
    true = ets:insert(?TAB, {{method, Key, DV}, Fun}),
    %% the printer consults print-method once a method of the user's exists
    Key =:= {'clojure.core', 'print-method'} andalso DV =/= ':default'
        andalso persistent_term:put({clj2_print, methods}, true),
    bump(Key),
    MF.

remove_method(MF = {multifn, _, Key}, DV) ->
    true = ets:delete(?TAB, {method, Key, DV}),
    bump(Key),
    MF.

remove_all_methods(MF = {multifn, _, Key}) ->
    ets:match_delete(?TAB, {{method, Key, '_'}, '_'}),
    bump(Key),
    MF.

%% @doc (prefer-method mf x y): x wins over y when both apply. Refused
%% when y is already preferred over x (as on the JVM).
prefer_method(MF = {multifn, _, Key}, X, Y) ->
    #{prefers := P} = meta(Key),
    case prefers_over(P, Y, X) of
        true ->
            erlang:error(clj2_rt:ex_info(
                           iolist_to_binary(["Preference conflict in multimethod '",
                                             atom_to_binary(element(2, Key)), "': ",
                                             clj2_print:pr_str(Y), " is already preferred to ",
                                             clj2_print:pr_str(X)]),
                           clj2_coll:hash_map_kv([':type', ':IllegalStateException']), nil));
        false ->
            update_meta(Key, fun(M) ->
                                     Set = maps:get(X, P, #{}),
                                     M#{prefers := P#{X => Set#{Y => true}}}
                             end),
            bump(Key),
            MF
    end.

prefers_over(P, X, Y) -> maps:is_key(Y, maps:get(X, P, #{})).

%% @doc (prefers mf): {x #{y ...}}
prefers(MF) ->
    clj2_coll:hash_map_kv(lists:append([[X, clj2_coll:hash_set(maps:keys(S))]
                                        || {X, S} <- maps:to_list(maps:get(prefers, meta(MF)))])).

%% @doc (methods mf): {dispatch-value method}
methods(MF) -> clj2_coll:hash_map_kv(lists:append(entries(MF))).

%% @doc [[dispatch-value method] ...], for clojure.core/find-best-method
method_entries(MF) -> [clj2_coll:vector(E) || E <- entries(MF)].

entries({multifn, _, Key}) -> ets:match(?TAB, {{method, Key, '$1'}, '$2'}).

%% @doc (get-method mf dv): the method a call with dispatch value dv would
%% run, or nil
get_method(MF = {multifn, _, Key}, DV) ->
    case ets:lookup(?TAB, {method, Key, DV}) of
        [{_, F}] -> F;
        [] ->
            try resolve(MF, Key, DV, default_value(MF), meta(Key))
            catch error:{'clojure.lang.ExceptionInfo', _, #{':message' := <<"No method", _/binary>>}} -> nil
            end
    end.
