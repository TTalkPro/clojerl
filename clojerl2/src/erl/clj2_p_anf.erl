%%%-------------------------------------------------------------------
%%% @doc normalize-anf: L4 → L5 (designs/01 §5 pass 8).
%%%
%%% Every argument position gets a trivial expression (local or
%%% constant); a non-trivial argument is bound first by a `let' with a
%%% fresh uid, in source order:
%%%
%%%   (f (g x) 1)   ⇒   (let* [a1 (g x)] (f a1 1))
%%%
%%% Why it matters on BEAM:
%%%   * Clojure evaluates arguments left to right; Erlang leaves the
%%%     order of call arguments unspecified — the lets fix it;
%%%   * the test of `if'/`case*' and the head and arguments of `invoke'
%%%     are used more than once by lower-labs (guards, dispatch), so they
%%%     must be variables or literals, never expressions.
%%%
%%% An invoke head that is a fn literal stays (lower-labs calls it
%%% directly: `loop*' entry).
%%%-------------------------------------------------------------------
-module(clj2_p_anf).

-export([pass/0, run/2]).

pass() -> #{name => normalize_anf, in => l4, out => l5}.

run(Tops, St) ->
    L4 = clj2_lang:get(l4),
    lists:mapfoldl(fun(T, S) -> expr(T, L4, S) end, St, Tops).

expr({'if', A, C, T, E}, L, St) ->
    with_trivs(A, [C], St, L, fun([C1], S) ->
        {T1, S1} = expr(T, L, S),
        {E1, S2} = expr(E, L, S1),
        {{'if', A, C1, T1, E1}, S2}
    end);
expr({'case', A, X, Clauses, Default}, L, St) ->
    with_trivs(A, [X], St, L, fun([X1], S) ->
        {Cs, S1} = lists:mapfoldl(fun({cclause, CA, K, R}, Sx) ->
                                          {R1, Sx1} = expr(R, L, Sx),
                                          {{cclause, CA, K, R1}, Sx1}
                                  end, S, Clauses),
        {D, S2} = case Default of
                      nil -> {nil, S1};
                      _ -> expr(Default, L, S1)
                  end,
        {{'case', A, X1, Cs, D}, S2}
    end);
expr({invoke, A, {fn, _, _, _} = F, Args}, L, St) ->
    {F1, St1} = expr(F, L, St),
    with_trivs(A, Args, St1, L, fun(As, S) -> {{invoke, A, F1, As}, S} end);
expr({invoke, A, F, Args}, L, St) ->
    with_trivs(A, [F | Args], St, L, fun([F1 | As], S) -> {{invoke, A, F1, As}, S} end);
expr({erl_call, A, M, Fn, Args}, L, St) ->
    with_trivs(A, Args, St, L, fun(As, S) -> {{erl_call, A, M, Fn, As}, S} end);
expr({call_var, A, M, Fn, Args}, L, St) ->
    with_trivs(A, Args, St, L, fun(As, S) -> {{call_var, A, M, Fn, As}, S} end);
expr({self_call, A, N, Args}, L, St) ->
    with_trivs(A, Args, St, L, fun(As, S) -> {{self_call, A, N, As}, S} end);
expr({list, A, Items}, L, St) ->
    with_trivs(A, Items, St, L, fun(Is, S) -> {{list, A, Is}, S} end);
expr({throw, A, X}, L, St) ->
    with_trivs(A, [X], St, L, fun([X1], S) -> {{throw, A, X1}, S} end);
expr(Node, L, St) ->
    clj2_np:mapfold(L, #{expr => fun(N, S) -> expr(N, L, S) end}, Node, St).

%% Normalise `Args', bind the non-trivial ones (in order), then build
%% the node from the trivial forms with `K'.
with_trivs(A, Args, St, L, K) ->
    {Pairs, St1} =
        lists:mapfoldl(fun(X, S) ->
                               {X1, S1} = expr(X, L, S),
                               case is_triv(X1) of
                                   true -> {{none, X1}, S1};
                                   false ->
                                       {U, S2} = fresh(S1),
                                       {{{bind, A, U, X1}, {local, A, U}}, S2}
                               end
                       end, St, Args),
    {Node, St2} = K([T || {_, T} <- Pairs], St1),
    case [B || {B, _} <- Pairs, B =/= none] of
        [] -> {Node, St2};
        Binds -> {{'let', A, Binds, Node}, St2}
    end.

is_triv({local, _, _}) -> true;
is_triv({const, _, _}) -> true;
is_triv(_) -> false.

fresh(St = #{next_uid := N}) -> {{anf, N}, St#{next_uid := N + 1}}.
