%%%-------------------------------------------------------------------
%%% @doc validate-recur: L1 → L1, analysis only (designs/01 §5 pass 5).
%%%
%%% `recur' must be in tail position of its target (the innermost
%%% `loop*' or fn clause), with the target's argument count (a variadic
%%% clause takes its rest argument as one value), and must not cross a
%%% `try' (Clojure's rule; on BEAM it would also break the tail call).
%%% The tree is returned unchanged.
%%%-------------------------------------------------------------------
-module(clj2_p_recur).

-export([pass/0, run/2]).

pass() -> #{name => validate_recur, in => l1, out => l1}.

run(Trees, St) ->
    L1 = clj2_lang:get(l1),
    _ = [expr(T, none, false, L1) || T <- Trees],
    {Trees, St}.

%% Target :: none | {Arity, try | ok}; Tail :: boolean()
expr({recur, A, Args}, Target, Tail, L) ->
    case Target of
        none -> fail(A, recur_without_target);
        {_, in_try} -> fail(A, recur_across_try);
        {N, ok} when N =/= length(Args) -> fail(A, {recur_arity, N, length(Args)});
        _ when not Tail -> fail(A, recur_not_in_tail_position);
        _ -> ok
    end,
    [expr(E, Target, false, L) || E <- Args],
    ok;
expr({'if', _, C, T, E}, Target, Tail, L) ->
    expr(C, Target, false, L),
    expr(T, Target, Tail, L),
    expr(E, Target, Tail, L);
expr({'case', _, X, Clauses, Default}, Target, Tail, L) ->
    expr(X, Target, false, L),
    [expr(R, Target, Tail, L) || {cclause, _, _, R} <- Clauses],
    Default =:= nil orelse expr(Default, Target, Tail, L),
    ok;
expr({do, _, Stmts, Ret}, Target, Tail, L) ->
    [expr(S, Target, false, L) || S <- Stmts],
    expr(Ret, Target, Tail, L);
expr({Op, _, Binds, Body}, Target, Tail, L) when Op =:= 'let'; Op =:= letfn ->
    [expr(E, Target, false, L) || {bind, _, _, E} <- Binds],
    expr(Body, Target, Tail, L);
expr({loop, _, Binds, Body}, Target, _Tail, L) ->
    [expr(E, Target, false, L) || {bind, _, _, E} <- Binds],
    expr(Body, {length(Binds), ok}, true, L);
expr({fn, _, _, Clauses}, _Target, _Tail, L) ->
    [expr(B, {length(Ps) + rest_count(R), ok}, true, L)
     || {clause, _, Ps, R, B} <- Clauses],
    ok;
expr({'try', _, Body, Catches, Fin}, Target, _Tail, L) ->
    InTry = case Target of
                none -> none;
                {N, _} -> {N, in_try}
            end,
    expr(Body, InTry, false, L),
    [expr(B, InTry, false, L) || {'catch', _, _, _, B} <- Catches],
    Fin =:= nil orelse expr(Fin, InTry, false, L),
    ok;
%% every other node: children are not in tail position
expr(Node, Target, _Tail, L) ->
    [expr(C, Target, false, L) || {expr, C} <- clj2_np:children(L, Node)],
    ok.

rest_count(nil) -> 0;
rest_count(_) -> 1.

fail(A, Why) -> erlang:error({clj2_compile, erl_anno:location(A), {recur, Why}}).
