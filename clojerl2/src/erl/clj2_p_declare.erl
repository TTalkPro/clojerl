%%%-------------------------------------------------------------------
%%% @doc declare: L0 → L0, analysis only (designs/03 §2.1).
%%%
%%% Collects, before any symbol is resolved, everything the namespace
%%% declares, so a fn body may call a var defined later in the file
%%% (forward references without fake_fun):
%%%
%%%   ns        the namespace (from `ns', default `user')
%%%   vars      #{Name => VarInfo} of every top-level def (see clj2_ns)
%%%   requires  the `(:require ...)' specs
%%%   ns_refs   namespaces named by qualified symbols, for the driver to
%%%             look up (D5: the pass itself reads no runtime state)
%%%-------------------------------------------------------------------
-module(clj2_p_declare).

-export([pass/0, run/2, var_info/2]).

pass() -> #{name => declare, in => l0, out => l0}.

run(Tops0, St) ->
    L0 = clj2_lang:get(l0),
    {Tops1, Redefined} = redefinitions(Tops0),
    {Tops, Hoisted} = hoisted(Tops1, maps:get(prior, St, #{})),
    Settable = maps:merge(maps:merge(Hoisted, Redefined), root_targets(L0, Tops)),
    {Ns, Reqs, NsDoc} = case Tops of
                            [{ns_decl, _, N, R, M} | _] -> {N, R, maps:get(':doc', M, nil)};
                            _ -> {maps:get(ns, St, user), [], nil}
                        end,
    Vars = lists:foldl(fun({def, A, Name, Meta, Init}, Acc) ->
                               check_name(A, Name, Acc),
                               Info = var_info(Meta, Init),
                               Acc#{Name => case is_map_key(Name, Settable) of
                                                true -> settable(Info);
                                                false -> Info
                                            end};
                          (_, Acc) -> Acc
                       end, #{}, Tops),
    Refs = lists:usort(
             lists:append(
               [clj2_np:fold(L0, fun({Tag, _, S}, Acc) when Tag =:= sym; Tag =:= the_var ->
                                         case qualifier(S) of
                                             nil -> Acc;
                                             Q -> [Q | Acc]
                                         end;
                                    (_, Acc) -> Acc
                                 end, [], T) || T <- Tops])),
    {Tops, St#{ns => Ns, ns_doc => NsDoc, vars => Vars, requires => Reqs, ns_refs => Refs}}.

%% A var defined more than once at the top level of the unit (JVM: the
%% later def replaces the value): the first def defines it, each later
%% one assigns its root where it stands, and the var keeps its value in
%% the var table (settable/1). A later (def x) without a value changes
%% nothing. → {Tops, #{Name => true}}
redefinitions(Tops) ->
    {Rev, _, Names} =
        lists:foldl(
          fun({def, A, N, M, Init} = T, {Acc, Seen, Re}) when not is_map_key('$hoisted', M) ->
                  case Seen of
                      #{N := _} when Init =:= nil -> {Acc, Seen, Re#{N => true}};
                      #{N := _} ->
                          Set = {invoke, A, {sym, A, 'clj2_rt/def_root'}, [{the_var, A, N}, Init]},
                          {[{eval, A, Set} | Acc], Seen, Re#{N => true}};
                      _ -> {[T | Acc], Seen#{N => true}, Re}
                  end;
             (T, {Acc, Seen, Re}) -> {[T | Acc], Seen, Re}
          end, {[], #{}, #{}}, Tops),
    {lists:reverse(Rev), Names}.

%% Declarations hoisted out of nested defs (clj2_p_parse): one per name,
%% and none for a name the unit also defines at top level -- that var
%% instead keeps its value where the nested def can set it (settable/1).
%% A name an earlier compile-time segment defined (`Prior') is declared
%% with that var's value, which it keeps until the nested def runs.
hoisted(Tops, Prior) ->
    Real = [N || {def, _, N, M, _} <- Tops, not is_map_key('$hoisted', M)],
    {Rev, Front, Names} =
        lists:foldl(
          fun({def, A, N, M, Init} = T, {Acc, Fr, Seen}) ->
                  case maps:take('$hoisted', M) of
                      {true, M1} ->
                          case lists:member(N, Real) orelse is_map_key(N, Seen) of
                              true -> {Acc, Fr, Seen#{N => true}};
                              false ->
                                  case Prior of
                                      %% from the start of the unit: the forms
                                      %% before the nested def see that value
                                      #{N := #{module := PM} = PI} ->
                                          Init1 = {invoke, A, {sym, A, 'clj2_rt/var_value'},
                                                   [{const, A, PM}, {const, A, N}, {const, A, PI}]},
                                          {Acc, [{def, A, N, M1, Init1} | Fr], Seen#{N => true}};
                                      _ -> {[{def, A, N, M1, Init} | Acc], Fr, Seen#{N => true}}
                                  end
                          end;
                      error -> {[T | Acc], Fr, Seen}
                  end;
             (T, {Acc, Fr, Seen}) -> {[T | Acc], Fr, Seen}
          end, {[], [], #{}}, Tops),
    Tops1 = case lists:reverse(Rev) of
                [{ns_decl, _, _, _, _} = NsDecl | Rest] -> [NsDecl | lists:reverse(Front) ++ Rest];
                Rest -> lists:reverse(Front) ++ Rest
            end,
    {Tops1, maps:filter(fun(N, _) -> lists:member(N, Real) end, Names)}.

%% The vars this unit changes the root of through (var x) --
%% (alter-var-root #'x f), (with-redefs [x v] ...) -- keep their value in
%% the var table, so the change reaches the calls linked to them.
root_targets(L0, Tops) ->
    Changers = ['alter-var-root', 'clojure.core/alter-var-root',
                'with-redefs-fn', 'clojure.core/with-redefs-fn'],
    Vars = fun(X) -> clj2_np:fold(L0, fun({the_var, _, S}, Acc) -> Acc#{unqualified(S) => true};
                                          (_, Acc) -> Acc
                                       end, #{}, X)
           end,
    lists:foldl(
      fun(T, Acc) ->
              clj2_np:fold(L0, fun({invoke, _, {sym, _, S}, Args}, Acc1) ->
                                       case lists:member(S, Changers) of
                                           true -> lists:foldl(fun(X, A1) -> maps:merge(A1, Vars(X)) end,
                                                               Acc1, Args);
                                           false -> Acc1
                                       end;
                                  (_, Acc1) -> Acc1
                               end, Acc, T)
      end, #{}, Tops).

%% a var a nested def also assigns: its root lives in the var table
settable(#{kind := K} = Info) when K =:= fn; K =:= const ->
    (maps:without([arities, variadic], Info))#{kind => cell};
settable(Info) -> Info.

%% @doc How a var is compiled and called (designs/09 §2).
var_info(Meta, Init) ->
    Dynamic = maps:get(':dynamic', Meta, false) =:= true,
    Redef = maps:get(':redef', Meta, false) =:= true,
    Base0 = #{dynamic => Dynamic,
              private => maps:get(':private', Meta, false) =:= true,
              macro => maps:get(':macro', Meta, false) =:= true},
    %% the docstring travels with the var (registry, and -doc in the beam)
    Base1 = case Meta of
                #{':doc' := Doc} when is_binary(Doc) -> Base0#{doc => Doc};
                _ -> Base0
            end,
    %% the rest of the metadata (:arglists, :tag, user keys) as given
    Base = case maps:without([':doc', ':dynamic', ':redef', ':private', ':macro'], Meta) of
               Extra when map_size(Extra) > 0 -> Base1#{meta => Extra};
               _ -> Base1
           end,
    case Init of
        _ when Dynamic; Redef -> Base#{kind => indirect};
        {fn, _, _, Clauses} ->
            Base#{kind => fn,
                  arities => lists:sort([length(Ps) || {clause, _, Ps, nil, _} <- Clauses]),
                  variadic => case [length(Ps) || {clause, _, Ps, R, _} <- Clauses, R =/= nil] of
                                  [Min] -> Min;
                                  [] -> nil
                              end};
        {const, _, _} -> Base#{kind => const};
        _ -> Base#{kind => cell}
    end.

check_name(A, Name, Seen) ->
    case Name of
        module_info -> fail(A, {reserved_var_name, Name});
        '__ns_init__' -> fail(A, {reserved_var_name, Name});
        _ -> ok
    end,
    maps:is_key(Name, Seen) andalso fail(A, {duplicate_def, Name}),
    ok.

unqualified(S) ->
    case string:split(atom_to_list(S), "/") of
        [[_ | _], [_ | _] = N] -> list_to_atom(N);
        _ -> S
    end.

qualifier(S) ->
    case string:split(atom_to_list(S), "/") of
        [[_ | _] = Q, [_ | _]] -> list_to_atom(Q);
        _ -> nil
    end.

fail(A, Why) -> erlang:error({clj2_compile, erl_anno:location(A), {declare, Why}}).
