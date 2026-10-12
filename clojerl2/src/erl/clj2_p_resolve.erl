%%%-------------------------------------------------------------------
%%% @doc resolve: L0 → L1 (designs/01 §5 pass 2).
%%%
%%% Lexical scoping: each binder gets a fresh uid `{Sym, N}' (N from the
%%% pipeline's `next_uid', so builds are deterministic), each local
%%% reference becomes `{local, A, Uid}'.
%%%
%%% Global symbols (designs/03 §2.1), in this order:
%%%   * `ns/name' where `ns' is this namespace, an alias, or a known
%%%     namespace → `{varref, A, Module, Name, VarInfo}';
%%%   * any other `mod/fun' in call position → Erlang remote call;
%%%   * an unqualified symbol defined in this namespace (forward
%%%     references included, see clj2_p_declare) or referred by
%%%     `(:require [ns :refer [...]])' → varref.
%%% Anything else is a compile error (no fake_fun, 00 §2.6).
%%%
%%% The scope comes from the driver in the pass state (`scope'):
%%%   #{ns, module, vars, aliases, refers, externals}.
%%% In `(def f (fn* f ...))' the fn's own name resolves to the var, so
%%% self calls become direct calls of the var function.
%%%-------------------------------------------------------------------
-module(clj2_p_resolve).

-export([pass/0, run/2]).

pass() -> #{name => resolve, in => l0, out => l1}.

run(Tops, St) ->
    L0 = clj2_lang:get(l0),
    {Tops1, St1} = lists:mapfoldl(fun(T, S) -> top(T, L0, S) end, St, Tops),
    {[T || T <- Tops1, T =/= drop], St1}.

top({ns_decl, _, _, _, _}, _L, St) -> {drop, St};
top({eval, A, E}, L, St) ->
    {E1, St1} = expr(E, #{}, L, St),
    {{eval, A, E1}, St1};
top({method, A, Name, Fn}, L, St) ->
    {Fn1, St1} = expr(Fn, #{}, L, St),
    {{method, A, Name, Fn1}, St1};
top({def, A, Name, Meta, nil}, _L, St) -> {{def, A, Name, Meta, nil}, St};
top({def, A, Name, Meta, {fn, FA, Self, Clauses}}, L, St = #{scope := Scope})
  when map_get(kind, map_get(Name, map_get(vars, Scope))) =:= fn ->
    %% the fn's own name is the var itself
    Env = case Self of
              nil -> #{};
              _ -> #{Self => {'$var_self', Name}}
          end,
    {Clauses1, St1} = lists:mapfoldl(fun(C, S) -> clause(C, Env, L, S) end, St, Clauses),
    {{def, A, Name, Meta, {fn, FA, nil, Clauses1}}, St1};
top({def, A, Name, Meta, Init}, L, St) ->
    {Init1, St1} = expr(Init, #{}, L, St),
    {{def, A, Name, Meta, Init1}, St1}.

expr({sym, A, S}, Env, _L, St) ->
    case Env of
        #{S := {'$var_self', Name}} -> {own_var(A, Name, St), St};
        #{S := Uid} -> {{local, A, Uid}, St};
        _ ->
            case global(A, S, St) of
                {var, {varref, _, _, _, #{macro := true}}} ->
                    fail(A, {cannot_take_value_of_macro, S});
                {var, Node} -> {Node, St};
                {erlang, M, F} ->
                    case jvm_class(M) of
                        {ok, C} ->
                            {{erl_call, A, clj2_jvm, field, [{const, A, C}, {const, A, F}]}, St};
                        error ->
                    case class_constant(A, S, St) of
                        {ok, C} -> {C, St};
                        error -> fail(A, {erlang_fun_needs_call_position, S})
                    end
                    end;
                unresolved ->
                    case class_constant(A, S, St) of
                        {ok, C} -> {C, St};
                        error -> fail(A, {unresolved_symbol, S})
                    end
            end
    end;
%% (var x): the var itself, a constant #'ns/name (what def returns)
expr({the_var, A, S}, _Env, _L, St) ->
    %% (var ns/x) reaches a private var too, as on the JVM
    case global(A, S, St, private_ok) of
        {var, {varref, _, _, Name, _}} -> {{const, A, {var, nil, {var_ns(S, St), Name}}}, St};
        _ -> fail(A, {unresolved_var, S})
    end;
%% a nested def's assignment (clj2_p_parse:nested_def/3): a var whose root
%% lives in the var table is set there (clj2_rt:assign_root/3) -- its module
%% is known now, and the var need not be registered yet (a compile-time
%% segment); a var linked to module functions moves its value there at run
%% time (clj2_rt:def_root/2)
expr({invoke, A, {sym, _, 'clj2_rt/def_root'}, [{the_var, VA, S} = TV, Val]}, Env, L, St) ->
    {Val1, St1} = expr(Val, Env, L, St),
    case global(VA, S, St1, private_ok) of
        {var, {varref, _, M, _, #{kind := K}}} when K =/= fn, K =/= const ->
            {VarC, St2} = expr(TV, Env, L, St1),
            {{erl_call, A, clj2_rt, assign_root, [VarC, {const, A, M}, Val1]}, St2};
        _ ->
            {VarC, St2} = expr(TV, Env, L, St1),
            {{erl_call, A, clj2_rt, def_root, [VarC, Val1]}, St2}
    end;
expr({invoke, A, {sym, _, S} = H, Args}, Env, L, St) when not is_map_key(S, Env) ->
    case ctor_sugar(A, S, St) of
        {ok, {jvm, C}} ->
            {Args1, St1} = exprs(Args, Env, L, St),
            {{erl_call, A, clj2_jvm, new, [{const, A, C}, {list, A, Args1}]}, St1};
        {ok, Ctor} ->
            {Args1, St1} = exprs(Args, Env, L, St),
            {{invoke, A, Ctor, Args1}, St1};
        error -> invoke_global(A, S, H, Args, Env, L, St)
    end;
expr({'let', A, Binds, Body}, Env, L, St) ->
    {Binds1, Env1, St1} = seq_binds(Binds, Env, L, St),
    {Body1, St2} = expr(Body, Env1, L, St1),
    {{'let', A, Binds1, Body1}, St2};
expr({loop, A, Binds, Body}, Env, L, St) ->
    {Binds1, Env1, St1} = seq_binds(Binds, Env, L, St),
    {Body1, St2} = expr(Body, Env1, L, St1),
    {{loop, A, Binds1, Body1}, St2};
expr({letfn, A, Binds, Body}, Env, L, St) ->
    %% all names are visible in every init (mutual recursion)
    {Uids, St1} = lists:mapfoldl(fun({bind, _, S, _}, Sx) -> fresh(S, Sx) end, St, Binds),
    Env1 = maps:merge(Env, maps:from_list(lists:zip([S || {bind, _, S, _} <- Binds], Uids))),
    {Binds1, St2} =
        lists:mapfoldl(fun({{bind, BA, _, E}, U}, Sx) ->
                           {E1, Sx1} = expr(E, Env1, L, Sx),
                           {{bind, BA, U, E1}, Sx1}
                       end, St1, lists:zip(Binds, Uids)),
    {Body1, St3} = expr(Body, Env1, L, St2),
    {{letfn, A, Binds1, Body1}, St3};
expr({fn, A, Name, Clauses}, Env, L, St) ->
    {Self, Env1, St1} =
        case Name of
            nil -> {nil, Env, St};
            _ -> {U, S1} = fresh(Name, St), {U, Env#{Name => U}, S1}
        end,
    {Clauses1, St2} = lists:mapfoldl(fun(C, S) -> clause(C, Env1, L, S) end, St1, Clauses),
    {{fn, A, Self, Clauses1}, St2};
expr({'try', A, Body, Catches, Fin}, Env, L, St) ->
    {Body1, St1} = expr(Body, Env, L, St),
    {Catches1, St2} =
        lists:mapfoldl(fun({'catch', CA, Class, S, CB}, Sx) ->
                           {U, Sx1} = fresh(S, Sx),
                           {CB1, Sx2} = expr(CB, Env#{S => U}, L, Sx1),
                           {{'catch', CA, Class, U, CB1}, Sx2}
                       end, St1, Catches),
    {Fin1, St3} = case Fin of
                      nil -> {nil, St2};
                      _ -> expr(Fin, Env, L, St2)
                  end,
    {{'try', A, Body1, Catches1, Fin1}, St3};
%% every other node: framework pass-through
expr(Node, Env, L, St) ->
    clj2_np:mapfold(L, #{expr => fun(N, S) -> expr(N, Env, L, S) end}, Node, St).

exprs(Es, Env, L, St) -> lists:mapfoldl(fun(E, S) -> expr(E, Env, L, S) end, St, Es).

%% let*/loop*: sequential scope, each init sees the previous binders
seq_binds(Binds, Env, L, St) ->
    {Rev, Env1, St1} =
        lists:foldl(fun({bind, BA, S, E}, {Acc, En, Sx}) ->
                        {E1, Sx1} = expr(E, En, L, Sx),
                        {U, Sx2} = fresh(S, Sx1),
                        {[{bind, BA, U, E1} | Acc], En#{S => U}, Sx2}
                    end, {[], Env, St}, Binds),
    {lists:reverse(Rev), Env1, St1}.

clause({clause, A, Fixed, Rest, Body}, Env, L, St) ->
    {Us, St1} = lists:mapfoldl(fun fresh/2, St, Fixed),
    Env1 = maps:merge(Env, maps:from_list(lists:zip(Fixed, Us))),
    {RU, Env2, St2} = case Rest of
                          nil -> {nil, Env1, St1};
                          _ -> {R, S2} = fresh(Rest, St1), {R, Env1#{Rest => R}, S2}
                      end,
    {Body1, St3} = expr(Body, Env2, L, St2),
    {{clause, A, Us, RU, Body1}, St3}.

fresh(S, St = #{next_uid := N}) -> {{S, N}, St#{next_uid := N + 1}}.

%%====================================================================
%% Globals
%%====================================================================

%% Access: `value' or `call' (another namespace's private var refused;
%% the JVM names the symbol for a value, the var for a call), or
%% `private_ok' (the var special form)
global(A, S, St) -> global(A, S, St, value).

global(A, S, St = #{scope := Scope}, Access) ->
    #{ns := Ns, vars := Vars, aliases := Aliases, refers := Refers,
      externals := Ext} = Scope,
    case qualified(S) of
        {Q, Name} ->
            QNs = maps:get(Q, Aliases, Q),
            if
                QNs =:= Ns ->
                    is_map_key(Name, Vars) orelse fail(A, {no_such_var, Ns, Name}),
                    {var, own_var(A, Name, St)};
                is_map_key(QNs, Ext) ->
                    Ref = ext_var(A, QNs, Name, Ext),
                    %% another namespace's private var is refused (core's
                    %% are used by its own macro expansions)
                    case Ref of
                        %% (the JVM names the symbol as written)
                        {varref, _, _, _, #{private := true}} when QNs =/= 'clojure.core',
                                                                   Access =/= private_ok ->
                            Shown = case Access of
                                        call -> ["#'", atom_to_list(QNs), "/", atom_to_list(Name)];
                                        value -> atom_to_list(S)
                                    end,
                            fail(A, {not_public, iolist_to_binary(["var: ", Shown, " is not public"])});
                        _ -> {var, Ref}
                    end;
                true ->
                    {erlang, Q, Name}
            end;
        false ->
            case Vars of
                #{S := _} -> {var, own_var(A, S, St)};
                _ ->
                    case Refers of
                        #{S := T} ->
                            {RNs, RName} = clj2_ns:refer_target(S, T),
                            {var, ext_var(A, RNs, RName, Ext)};
                        _ -> unresolved
                    end
            end
    end.

%% The namespace a var symbol names (global/3 has found the var).
var_ns(S, #{scope := #{ns := Ns, vars := Vars, aliases := Aliases, refers := Refers}}) ->
    case qualified(S) of
        {Q, _} -> maps:get(Q, Aliases, Q);
        false when is_map_key(S, Vars) -> Ns;
        false -> element(1, clj2_ns:refer_target(S, maps:get(S, Refers)))
    end.

%% A var's info may name its module (vars of earlier compile-time
%% segments, see clj2_compiler); otherwise it lives in the unit's NS module.
own_var(A, Name, #{scope := #{module := M, vars := Vars}}) ->
    Info = maps:get(Name, Vars),
    {varref, A, maps:get(module, Info, M), Name, Info}.

ext_var(A, Ns, Name, Ext) ->
    #{module := M, vars := Vars} = maps:get(Ns, Ext),
    case Vars of
        #{Name := Info} -> {varref, A, maps:get(module, Info, M), Name, Info};
        _ -> fail(A, {no_such_var, Ns, Name})
    end.

qualified(S) ->
    case string:split(atom_to_list(S), "/") of
        [[_ | _] = M, [_ | _] = F] -> {list_to_atom(M), list_to_atom(F)};
        _ -> false
    end.

fail(A, Why) -> erlang:error({clj2_compile, erl_anno:location(A), {resolve, Why}}).

invoke_global(A, S, H, Args, Env, L, St) ->
    case global(A, S, St, call) of
        {erlang, M, F} ->
            {Args1, St1} = exprs(Args, Env, L, St),
            case {jvm_class(M), atom_to_list(F)} of
                {{ok, _}, "." ++ Method} when Args1 =/= [] ->
                    %% (Class/.method obj args), Clojure 1.12: an instance member
                    [Obj | Rest] = Args1,
                    {{erl_call, A, clj2_jvm, method, [Obj, {const, A, list_to_atom(Method)}, {list, A, Rest}]}, St1};
                {{ok, C}, _} ->
                    %% (Class/method args): a host shim (clj2_jvm)
                    {{erl_call, A, clj2_jvm, static, [{const, A, C}, {const, A, F}, {list, A, Args1}]}, St1};
                {error, _} -> {{erl_call, A, M, F, Args1}, St1}
            end;
        _ ->
            {H1, St1} = expr(H, Env, L, St),
            {Args1, St2} = exprs(Args, Env, L, St1),
            {{invoke, A, H1, Args1}, St2}
    end.

%% A symbol naming a class, as a value (a JVM class from clj2_class's
%% graph, or a record/deftype of this scope: Name when ->Name is a var).
class_constant(A, S, St) ->
    case type_var(S, St) of
        {ok, Ns} -> {ok, {const, A, list_to_atom(atom_to_list(Ns) ++ "." ++ atom_to_list(S))}};
        error ->
            case clj2_class:resolve(S) of
                {ok, C} -> {ok, {const, A, C}};
                error -> error
            end
    end.

%% The JVM class a qualified symbol's namespace part names (Math in
%% Math/sqrt), unless it is an Erlang module.
jvm_class(M) ->
    case clj2_class:resolve(M) of
        {ok, C} ->
            case code:which(M) of
                non_existing -> {ok, C};
                _ -> error
            end;
        error -> error
    end.

%% (Name. args) for a record or deftype: (->Name args); for a JVM class
%% a host constructor (clj2_jvm:new)
ctor_sugar(A, S, St) ->
    case lists:reverse(atom_to_list(S)) of
        "." ++ Rev when Rev =/= [], hd(Rev) =/= $. ->
            Name = list_to_atom(lists:reverse(Rev)),
            case type_var(Name, St) of
                {ok, _} ->
                    {var, Ref} = global(A, list_to_atom("->" ++ atom_to_list(Name)), St),
                    {ok, Ref};
                error ->
                    case clj2_class:resolve(Name) of
                        {ok, C} -> {ok, {jvm, C}};
                        error -> error
                    end
            end;
        _ -> error
    end.

%% the namespace defining ->Name, when the symbol is a bare Name
type_var(S, St) ->
    case qualified(S) of
        false ->
            Ctor = list_to_atom("->" ++ atom_to_list(S)),
            case global(erl_anno:new(0), Ctor, St) of
                {var, _} -> {ok, var_ns(Ctor, St)};
                _ -> error
            end;
        _ -> error
    end.

