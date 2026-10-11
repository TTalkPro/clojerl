%%%-------------------------------------------------------------------
%%% @doc lower-letfn: L2 → L3 (designs/01 §5 pass 7, §6.3).
%%%
%%% Erlang funs cannot be mutually recursive, and Clojure locals are
%%% immutable, so a letfn* group becomes one named "group" fun G whose
%%% clause J returns member J; inside the members, a reference to
%%% member J is the call `G(J)':
%%%
%%%   (letfn* [f F g Gx] body)
%%%     ⇒ (let* [G (fn_group G [F' Gx'])  f (G 1)  g (G 2)] body)
%%%
%%% Members keep native closure capture, tail calls between members
%%% stay tail calls, and no lambda lifting or module-level function is
%%% needed. Lifting members to module functions is a later, optional
%%% optimisation pass.
%%%
%%% The same lowering serves a self-named multi-arity fn
%%% `(fn* f ([] (f 1)) ([x] x))', whose value is not a single fun.
%%%-------------------------------------------------------------------
-module(clj2_p_letfn).

-export([pass/0, run/2]).

pass() -> #{name => lower_letfn, in => l2, out => l3}.

run(Trees, St) ->
    L2 = clj2_lang:get(l2),
    lists:mapfoldl(fun(T, S) -> expr(T, #{}, L2, S) end, St, Trees).

%% Subst :: #{MemberUid => {GroupUid, Index}}
expr({local, A, U} = N, Subst, _L, St) ->
    case Subst of
        #{U := {G, J}} -> {{group_ref, A, G, J}, St};
        _ -> {N, St}
    end;
expr({letfn, A, Binds, Body}, Subst, L, St) ->
    {G, St1} = fresh(letfn, St),
    Idx = lists:zip([U || {bind, _, U, _} <- Binds], lists:seq(1, length(Binds))),
    Inner = maps:merge(Subst, maps:from_list([{U, {G, J}} || {U, J} <- Idx])),
    {Fns, St2} = lists:mapfoldl(fun({bind, _, _, E}, S) -> expr(E, Inner, L, S) end,
                                St1, Binds),
    {Body1, St3} = expr(Body, Subst, L, St2),
    Members = [{bind, BA, U, {group_ref, BA, G, J}}
               || {{bind, BA, U, _}, {U, J}} <- lists:zip(Binds, Idx)],
    {{'let', A, [{bind, A, G, {fn_group, A, G, Fns}} | Members], Body1}, St3};
%% A multi-arity/variadic fn naming itself is not one Erlang fun, so the
%% name cannot be the fun's own: lower it as a one-member letfn group.
expr({fn, A, Self, Clauses}, Subst, L, St)
  when Self =/= nil, (length(Clauses) > 1 orelse element(5, hd(Clauses)) =/= nil) ->
    expr({letfn, A, [{bind, A, Self, {fn, A, nil, Clauses}}], {local, A, Self}}, Subst, L, St);
expr(Node, Subst, L, St) ->
    clj2_np:mapfold(L, #{expr => fun(N, S) -> expr(N, Subst, L, S) end}, Node, St).

fresh(S, St = #{next_uid := N}) -> {{S, N}, St#{next_uid := N + 1}}.
