%%%-------------------------------------------------------------------
%%% @doc inline: L4 → L4, optimisation, release mode only
%%% (designs/01 §5 pass 10).
%%%
%%% Beta-reduces a fn literal called on the spot:
%%%
%%%   ((fn* [x y] body) a b)  ⇒  (let* [x a y b] body)
%%%
%%% when the fn has one fixed-arity clause of that arity, no self name,
%%% and does not recur (a `loop*' that never recurs becomes a `let*').
%%% The body is not copied (the literal is used once), uids stay unique,
%%% and argument evaluation order is unchanged. It runs in the fixpoint
%%% group with const-fold: inlining exposes constants, folding exposes
%%% more calls.
%%%-------------------------------------------------------------------
-module(clj2_p_inline).

-export([pass/0, run/2]).

pass() -> #{name => inline, in => l4, out => l4}.

run(Tops, St) ->
    L4 = clj2_lang:get(l4),
    {[expr(T, L4) || T <- Tops], St}.

expr({invoke, A, {fn, _, nil, [{clause, _, Name, Ps, nil, Body}]}, Args}, L)
  when length(Ps) =:= length(Args) ->
    case recurs(Name, Body, L) of
        true -> descend({invoke, A, {fn, A, nil, [{clause, A, Name, Ps, nil, Body}]}, Args}, L);
        false ->
            Binds = [{bind, A, P, expr(X, L)} || {P, X} <- lists:zip(Ps, Args)],
            Body1 = expr(Body, L),
            case Binds of
                [] -> Body1;
                _ -> {'let', A, Binds, Body1}
            end
    end;
expr(Node, L) -> descend(Node, L).

descend(Node, L) ->
    clj2_np:descend(L, #{expr => fun(N, _) -> expr(N, L) end}, Node, nil).

recurs(Name, Body, L) ->
    clj2_np:fold(L, fun({self_call, _, N, _}, _) when N =:= Name -> true;
                       (_, Acc) -> Acc
                    end, false, Body).
