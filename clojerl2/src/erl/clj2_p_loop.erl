%%%-------------------------------------------------------------------
%%% @doc lower-loop: L1 → L2 (designs/01 §5 pass 6, D6).
%%%
%%% Every fn clause gets a name and becomes an Erlang named fun; `recur'
%%% becomes a call of that name (a BEAM tail call, no trampoline):
%%%
%%%   (loop* [x 0] body)  ⇒  ((fn* L [x] body) 0)
%%%   (recur e ...)       ⇒  {self_call, A, L, [e ...]}
%%%
%%% Run after validate-recur, so every recur has a target here.
%%%-------------------------------------------------------------------
-module(clj2_p_loop).

-export([pass/0, run/2]).

pass() -> #{name => lower_loop, in => l1, out => l2}.

run(Trees, St) ->
    L1 = clj2_lang:get(l1),
    lists:mapfoldl(fun(T, S) -> expr(T, none, L1, S) end, St, Trees).

expr({recur, A, Args}, Target, L, St) ->
    {Args1, St1} = lists:mapfoldl(fun(E, S) -> expr(E, Target, L, S) end, St, Args),
    {{self_call, A, Target, Args1}, St1};
expr({loop, A, Binds, Body}, Target, L, St) ->
    {Inits, St1} = lists:mapfoldl(fun({bind, _, _, E}, S) -> expr(E, Target, L, S) end,
                                  St, Binds),
    {Name, St2} = fresh(loop, St1),
    {Body1, St3} = expr(Body, Name, L, St2),
    Params = [U || {bind, _, U, _} <- Binds],
    {{invoke, A, {fn, A, nil, [{clause, A, Name, Params, nil, Body1}]}, Inits}, St3};
expr({fn, A, Self, Clauses}, _Target, L, St) ->
    {Clauses1, St1} =
        lists:mapfoldl(fun({clause, CA, Ps, R, B}, S) ->
                           {Name, S1} = fresh(fn, S),
                           {B1, S2} = expr(B, Name, L, S1),
                           {{clause, CA, Name, Ps, R, B1}, S2}
                       end, St, Clauses),
    {{fn, A, Self, Clauses1}, St1};
expr(Node, Target, L, St) ->
    clj2_np:mapfold(L, #{expr => fun(N, S) -> expr(N, Target, L, S) end}, Node, St).

fresh(S, St = #{next_uid := N}) -> {{S, N}, St#{next_uid := N + 1}}.
