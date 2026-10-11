%%%-------------------------------------------------------------------
%%% @doc link: L3 → L4 (designs/03 §2.1 "direct linking").
%%%
%%% Turns var references into the calls the NS module model provides:
%%%
%%%   (f a b)  f a fn var with arity 2      ⇒ M:f(a, b)        direct call
%%%   (f a b c) f variadic, min 1          ⇒ M:f(a, [b, c])    rest packed
%%%   f        fn var used as a value       ⇒ fun M:f/N  (or a clj2_fn tuple)
%%%   x        any other var                ⇒ M:x()            accessor
%%%
%%% Calls are local when M is the unit's own module (emit decides).
%%% A call with an arity the fn var does not have is a compile error.
%%%-------------------------------------------------------------------
-module(clj2_p_link).

-export([pass/0, run/2]).

pass() -> #{name => link, in => l3, out => l4}.

run(Tops, St) ->
    L3 = clj2_lang:get(l3),
    {[expr(T, L3) || T <- Tops], St}.

expr({invoke, A, {varref, _, M, Name, #{kind := fn} = Info}, Args}, L) ->
    Args1 = [expr(E, L) || E <- Args],
    N = length(Args1),
    #{arities := Fixed, variadic := Min} = Info,
    case lists:member(N, Fixed) of
        true -> {call_var, A, M, Name, Args1};
        false when Min =/= nil, N >= Min ->
            {Req, Rest} = lists:split(Min, Args1),
            RestE = case Rest of
                        [] -> {const, A, nil};
                        _ -> {list, A, Rest}
                    end,
            {call_var, A, M, Name, Req ++ [RestE]};
        false ->
            fail(A, {arity, M, Name, N})
    end;
expr({varref, A, M, Name, #{kind := fn, arities := Fixed, variadic := Min}}, _L) ->
    {fn_var, A, M, Name, Fixed, Min};
expr({varref, A, M, Name, _Info}, _L) ->
    {call_var, A, M, Name, []};
expr(Node, L) ->
    clj2_np:descend(L, #{expr => fun(N, _) -> expr(N, L) end}, Node, nil).

fail(A, Why) -> erlang:error({clj2_compile, erl_anno:location(A), {link, Why}}).
