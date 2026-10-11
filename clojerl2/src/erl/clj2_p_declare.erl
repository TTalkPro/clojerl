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

run(Tops, St) ->
    L0 = clj2_lang:get(l0),
    {Ns, Reqs, NsDoc} = case Tops of
                            [{ns_decl, _, N, R, M} | _] -> {N, R, maps:get(':doc', M, nil)};
                            _ -> {maps:get(ns, St, user), [], nil}
                        end,
    Vars = lists:foldl(fun({def, A, Name, Meta, Init}, Acc) ->
                               check_name(A, Name, Acc),
                               Acc#{Name => var_info(Meta, Init)};
                          (_, Acc) -> Acc
                       end, #{}, Tops),
    Refs = lists:usort(
             lists:append(
               [clj2_np:fold(L0, fun({sym, _, S}, Acc) ->
                                         case qualifier(S) of
                                             nil -> Acc;
                                             Q -> [Q | Acc]
                                         end;
                                    (_, Acc) -> Acc
                                 end, [], T) || T <- Tops])),
    {Tops, St#{ns => Ns, ns_doc => NsDoc, vars => Vars, requires => Reqs, ns_refs => Refs}}.

%% @doc How a var is compiled and called (designs/09 §2).
var_info(Meta, Init) ->
    Dynamic = maps:get(':dynamic', Meta, false) =:= true,
    Redef = maps:get(':redef', Meta, false) =:= true,
    Base0 = #{dynamic => Dynamic,
              private => maps:get(':private', Meta, false) =:= true,
              macro => maps:get(':macro', Meta, false) =:= true},
    %% the docstring travels with the var (registry, and -doc in the beam)
    Base = case Meta of
               #{':doc' := Doc} when is_binary(Doc) -> Base0#{doc => Doc};
               _ -> Base0
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

qualifier(S) ->
    case string:split(atom_to_list(S), "/") of
        [[_ | _] = Q, [_ | _]] -> list_to_atom(Q);
        _ -> nil
    end.

fail(A, Why) -> erlang:error({clj2_compile, erl_anno:location(A), {declare, Why}}).
