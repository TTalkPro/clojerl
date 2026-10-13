%%%-------------------------------------------------------------------
%%% @doc verify: L5 → L5, analysis only (designs/01 §5 pass 11).
%%%
%%% The grammar is checked at every pass boundary by the framework; this
%%% pass checks what a grammar cannot, the scoping invariant the emitted
%%% Erlang relies on (designs/09 §3.1):
%%%
%%%   * every uid is bound exactly once in the unit (so no Erlang
%%%     variable is ever rebound or shadowed);
%%%   * every reference (local, self_call, group_ref) is to a uid bound
%%%     in an enclosing scope (so no variable is used outside the
%%%     Clojure scope that bound it — erl_lint's "unsafe" variables).
%%%
%%% A failure is a compiler bug, reported as `{verify, ...}'.
%%%-------------------------------------------------------------------
-module(clj2_p_verify).

-export([pass/0, run/2]).

pass() -> #{name => verify, in => l5, out => l5}.

run(Tops, St) ->
    L5 = clj2_lang:get(l5),
    _ = lists:foldl(fun(T, Seen) -> top(T, L5, Seen) end, #{}, Tops),
    {Tops, St}.

top({def, _, _, _, nil}, _L, Seen) -> Seen;
top({def, _, _, _, Init}, L, Seen) -> expr(Init, #{}, L, Seen);
top({eval, _, X}, L, Seen) -> expr(X, #{}, L, Seen);
top({method, _, _, Fn}, L, Seen) -> expr(Fn, #{}, L, Seen).

%% Scope :: #{Uid => true}; Seen :: every uid bound so far (threaded)
expr({local, A, U}, Scope, _L, Seen) -> ref(A, U, Scope), Seen;
expr({self_call, A, U, Args}, Scope, L, Seen) ->
    ref(A, U, Scope),
    exprs(Args, Scope, L, Seen);
expr({group_ref, A, G, _}, Scope, _L, Seen) -> ref(A, G, Scope), Seen;
expr({'let', _, Binds, Body}, Scope, L, Seen) ->
    {Scope1, Seen1} =
        lists:foldl(fun({bind, BA, U, X}, {Sc, Sn}) ->
                            Sn1 = expr(X, Sc, L, Sn),
                            {Sc#{U => true}, bind(BA, U, Sn1)}
                    end, {Scope, Seen}, Binds),
    expr(Body, Scope1, L, Seen1);
expr({fn, A, Self, Clauses}, Scope, L, Seen) ->
    {Scope1, Seen1} = case Self of
                          nil -> {Scope, Seen};
                          _ -> {Scope#{Self => true}, bind(A, Self, Seen)}
                      end,
    lists:foldl(fun({clause, CA, Name, Ps, Rest, Body}, Sn) ->
                        Us = [Name | Ps] ++ [Rest || Rest =/= nil],
                        Sn1 = lists:foldl(fun(U, S) -> bind(CA, U, S) end, Sn, Us),
                        expr(Body, maps:merge(Scope1, maps:from_keys(Us, true)), L, Sn1)
                end, Seen1, Clauses);
%% the group name is the let binding it initialises (`G = fun G(J) ...'
%% in Erlang): in scope inside, not a second binding
expr({fn_group, _, G, Fns}, Scope, L, Seen) ->
    exprs(Fns, Scope#{G => true}, L, Seen);
expr({'try', _, Body, Catches, Fin}, Scope, L, Seen) ->
    Seen1 = expr(Body, Scope, L, Seen),
    Seen2 = lists:foldl(fun({'catch', CA, _, U, CB}, Sn) ->
                                expr(CB, Scope#{U => true}, L, bind(CA, U, Sn))
                        end, Seen1, Catches),
    case Fin of
        nil -> Seen2;
        _ -> expr(Fin, Scope, L, Seen2)
    end;
%% receive*: a clause's pattern variables are in scope in its body
expr({'receive', _, Clauses, T, After}, Scope, L, Seen) ->
    Seen1 = lists:foldl(fun({rclause, CA, _, Us, Pins, Body}, Sn) ->
                                Sn1 = exprs(Pins, Scope, L, Sn),
                                Sn2 = lists:foldl(fun(U, S) -> bind(CA, U, S) end, Sn1, Us),
                                expr(Body, maps:merge(Scope, maps:from_keys(Us, true)), L, Sn2)
                        end, Seen, Clauses),
    exprs([X || X <- [T, After], X =/= nil], Scope, L, Seen1);
expr(Node, Scope, L, Seen) ->
    exprs([C || {_, C} <- clj2_np:children(L, Node)], Scope, L, Seen).

exprs(Xs, Scope, L, Seen) ->
    lists:foldl(fun(X, Sn) -> expr(X, Scope, L, Sn) end, Seen, Xs).

ref(A, U, Scope) ->
    is_map_key(U, Scope) orelse fail(A, {out_of_scope, U}).

bind(A, U, Seen) ->
    is_map_key(U, Seen) andalso fail(A, {bound_twice, U}),
    Seen#{U => true}.

fail(A, Why) -> erlang:error({clj2_compile, erl_anno:location(A), {verify, Why}}).
