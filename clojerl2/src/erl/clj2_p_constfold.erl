%%%-------------------------------------------------------------------
%%% @doc const-fold: L4 → L4, optimisation (designs/01 §5 pass 10).
%%%
%%% Runs in a fixpoint group (clj2_np:run `{fixpoint, ...}'): one round
%%% may enable another, e.g. a folded test lets its `if' fold.
%%%
%%%   (if c a b), c a constant          ⇒ a or b (Clojure truthiness)
%%%   (case* c ...), c a constant       ⇒ the matching result
%%%   (mod/f k ...), all constants      ⇒ the value, when mod:f is a
%%%                                       pure BIF in `pure/2' and the
%%%                                       call succeeds (else unchanged:
%%%                                       the error stays a run-time one)
%%%   (do ... k ...)                    ⇒ pure statements dropped
%%%   (let* [x k] ...) / [x y]          ⇒ x replaced by k / y (both are
%%%                                       immutable, uids are unique)
%%%-------------------------------------------------------------------
-module(clj2_p_constfold).

-export([pass/0, run/2]).

pass() -> #{name => const_fold, in => l4, out => l4}.

run(Tops, St) ->
    L4 = clj2_lang:get(l4),
    {[expr(T, #{}, L4) || T <- Tops], St}.

%% Sub :: #{Uid => trivial node} — let-bound constants and aliases
expr({local, A, U} = N, Sub, _L) ->
    case Sub of
        #{U := {const, _, V}} -> {const, A, V};
        #{U := {local, _, U2}} -> {local, A, U2};
        _ -> N
    end;
expr({'if', A, C, T, E}, Sub, L) ->
    case expr(C, Sub, L) of
        {const, _, V} when V =:= false; V =:= nil -> expr(E, Sub, L);
        {const, _, _} -> expr(T, Sub, L);
        C1 -> {'if', A, C1, expr(T, Sub, L), expr(E, Sub, L)}
    end;
expr({'case', A, X, Clauses, Default}, Sub, L) ->
    X1 = expr(X, Sub, L),
    Clauses1 = [{cclause, CA, Cs, expr(R, Sub, L)} || {cclause, CA, Cs, R} <- Clauses],
    Default1 = case Default of
                   nil -> nil;
                   _ -> expr(Default, Sub, L)
               end,
    case X1 of
        {const, _, V} ->
            case [R || {cclause, _, Cs, R} <- Clauses1, lists:any(fun(C) -> C =:= V end, Cs)] of
                [R | _] -> R;
                [] when Default1 =/= nil -> Default1;
                [] -> {'case', A, X1, Clauses1, Default1}
            end;
        _ -> {'case', A, X1, Clauses1, Default1}
    end;
expr({erl_call, A, M, F, Args}, Sub, L) ->
    Args1 = [expr(X, Sub, L) || X <- Args],
    case pure(M, F) andalso lists:all(fun is_const/1, Args1) of
        true ->
            try {const, A, erlang:apply(M, F, [V || {const, _, V} <- Args1])}
            catch _:_ -> {erl_call, A, M, F, Args1}
            end;
        false -> {erl_call, A, M, F, Args1}
    end;
expr({do, A, Stmts, Ret}, Sub, L) ->
    Stmts1 = [S || S <- [expr(X, Sub, L) || X <- Stmts], not is_pure(S)],
    Ret1 = expr(Ret, Sub, L),
    case Stmts1 of
        [] -> Ret1;
        _ -> {do, A, Stmts1, Ret1}
    end;
expr({'let', A, Binds, Body}, Sub, L) ->
    {Kept, Sub1} =
        lists:foldl(fun({bind, BA, U, X}, {Acc, S}) ->
                            case expr(X, S, L) of
                                {const, _, _} = K -> {Acc, S#{U => K}};
                                {local, _, _} = V -> {Acc, S#{U => V}};
                                X1 -> {[{bind, BA, U, X1} | Acc], S}
                            end
                    end, {[], Sub}, Binds),
    Body1 = expr(Body, Sub1, L),
    case Kept of
        [] -> Body1;
        _ -> {'let', A, lists:reverse(Kept), Body1}
    end;
expr(Node, Sub, L) ->
    clj2_np:descend(L, #{expr => fun(N, _) -> expr(N, Sub, L) end}, Node, nil).

is_const({const, _, _}) -> true;
is_const(_) -> false.

%% statements that can be dropped: no effect, cannot fail
is_pure({const, _, _}) -> true;
is_pure({local, _, _}) -> true;
is_pure({fn, _, _, _}) -> true;
is_pure({fn_var, _, _, _, _, _}) -> true;
is_pure(_) -> false.

%% BIFs whose result depends only on their arguments
pure(erlang, F) ->
    lists:member(F, ['+', '-', '*', '/', 'div', 'rem', 'band', 'bor', 'bxor',
                     'bsl', 'bsr', 'bnot', 'abs', 'min', 'max',
                     '==', '/=', '=:=', '=/=', '<', '>', '=<', '>=',
                     'not', 'and', 'or', 'xor',
                     'is_atom', 'is_binary', 'is_integer', 'is_float', 'is_number',
                     'is_list', 'is_tuple', 'is_map', 'is_boolean',
                     'element', 'tuple_size', 'length', 'hd', 'tl',
                     'atom_to_list', 'list_to_atom', 'integer_to_list',
                     'atom_to_binary', 'binary_to_list', 'list_to_binary',
                     'byte_size', 'tuple_to_list', 'list_to_tuple']);
pure(lists, F) -> lists:member(F, [reverse, append, nth, sum, member, seq]);
pure(_, _) -> false.
