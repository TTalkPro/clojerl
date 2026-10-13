%%%-------------------------------------------------------------------
%%% @doc emit: Labs → Erlang abstract forms (designs/02 §2, D4).
%%%
%%% A serializer, one clause per Labs node: no Clojure semantics here
%%% (they are all in lower-labs). Anno is passed through, so BEAM stack
%%% traces carry Clojure line/column. A uid `{x, 3}' becomes the Erlang
%%% variable 'V3_x' (unique per unit, see clj2_p_verify).
%%%-------------------------------------------------------------------
-module(clj2_p_emit).

-export([pass/0, run/2]).

pass() -> #{name => emit, in => labs, out => absform}.

run(Tops, St) ->
    {[top(T) || T <- Tops], St}.

top({eattr, A, file, File}) -> {attribute, A, file, {File, 1}};
top({eattr, A, Key, Value}) -> {attribute, A, Key, Value};
top({efunction, A, Name, Arity, Clauses}) ->
    {function, A, Name, Arity, [clause(C) || C <- Clauses]}.

clause({eclause, A, Pats, Guards, Body}) ->
    {clause, A, es(Pats), [es(G) || G <- Guards], es(Body)}.

es(Es) -> [e(X) || X <- Es].

e({evar, A, U}) -> {var, A, var(U)};
e({ewild, A}) -> {var, A, '_'};
e({elit, A, V}) -> erl_parse:abstract(V, [{location, erl_anno:location(A)}, {encoding, none}]);
e({eblock, _A, [X]}) -> e(X);
e({eblock, A, Xs}) -> {block, A, es(Xs)};
e({ematch, A, P, X}) -> {match, A, e(P), e(X)};
e({ecall, A, F, Args}) -> {call, A, {atom, A, F}, es(Args)};
e({eremote, A, M, F, Args}) -> {call, A, {remote, A, {atom, A, M}, {atom, A, F}}, es(Args)};
e({eapply, A, F, Args}) -> {call, A, e(F), es(Args)};
e({efun, A, Cs}) -> {'fun', A, {clauses, [clause(C) || C <- Cs]}};
e({enamed, A, U, Cs}) -> {named_fun, A, var(U), [clause(C) || C <- Cs]};
e({efunref, A, F, N}) -> {'fun', A, {function, F, N}};
e({eextref, A, M, F, N}) -> {'fun', A, {function, {atom, A, M}, {atom, A, F}, {integer, A, N}}};
e({ecase, A, X, Cs}) -> {'case', A, e(X), [clause(C) || C <- Cs]};
e({eif, A, Cs}) -> {'if', A, [clause(C) || C <- Cs]};
e({etry, A, Body, Cs, After}) -> {'try', A, es(Body), [], [clause(C) || C <- Cs], es(After)};
e({etuple, A, Xs}) -> {tuple, A, es(Xs)};
e({ereceive, A, Cs, nil, _}) -> {'receive', A, [clause(C) || C <- Cs]};
e({ereceive, A, Cs, T, After}) -> {'receive', A, [clause(C) || C <- Cs], e(T), es(After)};
e({emapp, A, Assocs}) -> {map, A, [{map_field_exact, AA, e(K), e(V)} || {eassoc, AA, K, V} <- Assocs]};
e({emap, A, Assocs}) -> {map, A, [{map_field_assoc, AA, e(K), e(V)} || {eassoc, AA, K, V} <- Assocs]};
e({elist, A, Xs}) -> lists:foldr(fun(X, T) -> {cons, A, e(X), T} end, {nil, A}, Xs);
e({gop, A, Op, Xs}) -> e({eop, A, Op, Xs});
e({gcall, A, F, Args}) -> {call, A, {atom, A, F}, es(Args)};
e({eop, A, Op, [X]}) -> {op, A, Op, e(X)};
e({eop, A, Op, [X, Y]}) -> {op, A, Op, e(X), e(Y)}.

%% uid {x, 3} → Erlang variable 'V3_x'
var({S, N}) ->
    list_to_atom("V" ++ integer_to_list(N) ++ "_" ++ atom_to_list(S)).
