%%%-------------------------------------------------------------------
%%% @doc lower-labs: L5 → Labs (designs/01 §5 pass 12, designs/02 §2).
%%%
%%% The last pass that knows Clojure: every decision about how Clojure
%%% maps onto Erlang is made here, and the result is Labs, one node per
%%% absform construct, which emit only serializes.
%%%
%%% Calling convention (platform-native):
%%%   * a fn with one fixed-arity clause IS an Erlang named fun/N; its
%%%     name is the recur target;
%%%   * otherwise `{clj2_fn, #{N => fun/N}, nil | {Min, fun/(Min+1)}}'
%%%     (normalize-arities: one fun per arity + this dispatch record),
%%%     a variadic clause receiving its rest args as a list or nil;
%%%   * invoke: `F(Args)' when `is_function(F, N)', else
%%%     `clj2_rt:invoke(F, Args)'; a fn literal head is called directly.
%%%
%%% Truthiness: `if' is an Erlang `if' with the guard
%%% `T =:= false; T =:= nil' (T is trivial after ANF, so no branch is
%%% duplicated). `case*' matches each constant by pattern when that is
%%% exact (no map inside: map patterns match supersets), else by
%%% `=:=' guards; a missing default raises IllegalArgumentException "No matching clause: V" (clj2_rt:no_matching_clause/1).
%%%
%%% Units (pass state `unit'):
%%%   ns    one namespace = one module (designs/03 §2.1): fn var → f/N,
%%%         other var → accessor x/0, `__ns_init__/0' as -on_load.
%%%         Calls to the unit's own vars are local (remote calls into a
%%%         module fail while its on_load runs).
%%%   eval  top-level expressions → run/0 returning the last value.
%%%-------------------------------------------------------------------
-module(clj2_p_labs).

-export([pass/0, run/2]).

pass() -> #{name => lower_labs, in => l5, out => labs}.

run(Tops, St = #{module := M}) ->
    A0 = erl_anno:new(0),
    File = maps:get(file, St, atom_to_list(M) ++ ".clj"),
    Head = [{eattr, A0, file, File}, {eattr, A0, module, M}],
    St0 = St#{fun_names => #{}},
    {Body, St1} = case maps:get(unit, St, eval) of
                      eval -> eval_unit(Tops, A0, St0);
                      ns -> ns_unit(Tops, A0, St0);
                      impl -> impl_unit(Tops, A0, St0)
                  end,
    {Head ++ Body, maps:remove(fun_names, St1)}.

%%====================================================================
%% Units
%%====================================================================

eval_unit(Tops, A0, St) ->
    {Body, St1} = lists:mapfoldl(
                    fun({eval, _, X}, S) -> expr(X, S);
                       ({def, A, Name, _, _}, _) -> fail(A, {def_outside_namespace_unit, Name})
                    end, St, Tops),
    Run = case Body of
              [] -> [{elit, A0, nil}];
              _ -> Body
          end,
    {[{eattr, A0, export, [{run, 0}]},
      {efunction, A0, run, 0, [{eclause, A0, [], [], Run}]}], St1}.

ns_unit(Tops, A0, St = #{module := M, ns := Ns, vars := Vars}) ->
    {Parts, St1} = lists:mapfoldl(fun top/2, St, Tops),
    Funs = lists:append([with_doc(F, Vars) || {F, _} <- Parts]),
    Steps = lists:append([S || {_, S} <- Parts]),
    {Init, St2} = init_fun(Ns, M, Vars, Steps, A0, maps:get(register, St, true), St1),
    {FnValues, St3} = fn_values(Funs, Vars, M, A0, St2),
    ModuleDoc = case maps:get(ns_doc, St, nil) of
                    nil -> [];
                    D -> [{eattr, A0, moduledoc, D}]
                end,
    {ModuleDoc ++ module_body(Funs ++ FnValues, Init, A0), St3}.

%% `'__fn__'(Name)': the value of each fn var of this module, built here
%% so it is a local fun, bound to this version of the module. Other
%% modules take a fn var's value through it (see fn_var below): a value
%% taken before a redefinition keeps running the old code (designs/02 §5).
fn_values(Funs, Vars, M, A0, St) ->
    Defined = [N || {efunction, _, N, _, _} <- Funs],
    Fns = [{N, F, Min} || {N, #{kind := fn, arities := F, variadic := Min} = I} <- lists:sort(maps:to_list(Vars)),
                          maps:get(module, I, M) =:= M, lists:member(N, Defined)],
    case Fns of
        [] -> {[], St};
        _ ->
            {Clauses, St1} = lists:mapfoldl(
                               fun({N, F, Min}, S) ->
                                       {V, S1} = expr({fn_var, A0, M, N, F, Min}, S),
                                       {{eclause, A0, [{elit, A0, N}], [], [V]}, S1}
                               end, St, Fns),
            {[{eattr, A0, doc, false}, {efunction, A0, '__fn__', 1, Clauses}], St1}
    end.

%% Docstrings become EEP-48 docs (OTP 27+ `-doc', a wild attribute in
%% absform): placed right before the var's first function, so
%% `code:get_doc/1' and the shell's h/2 show them.
with_doc([{efunction, A, Name, _, _} | _] = Fs, Vars) ->
    case Vars of
        #{Name := #{doc := Doc}} -> [{eattr, A, doc, Doc} | Fs];
        _ -> Fs
    end;
with_doc(Fs, _Vars) -> Fs.

module_body(Funs, Init, A0) ->
    Exports = [{N, Ar} || {efunction, _, N, Ar, _} <- Funs] ++ [{'__ns_init__', 0}],
    %% vars named like auto-imported BIFs (apply/2, max/2 ...): local
    %% calls must reach the var, not the BIF
    Clash = [{N, Ar} || {efunction, _, N, Ar, _} <- Funs, erl_internal:bif(N, Ar)],
    NoAuto = [{eattr, A0, compile, {no_auto_import, Clash}} || Clash =/= []],
    Hidden = {eattr, A0, doc, false},                     % -doc false: no docs for the init
    [{eattr, A0, export, Exports}, {eattr, A0, on_load, {'__ns_init__', 0}}]
    ++ NoAuto ++ Funs ++ [Hidden, Init].

%% An impl module `<Protocol>__<Tag>' (designs/03 §4): one function per
%% method clause; its on_load enters it into the dispatch cache, which
%% also clears a negative entry made before the extend.
impl_unit(Tops, A0, St = #{module := M, impl_of := {Proto, Tag}}) ->
    {Funs, St1} = lists:mapfoldl(fun({method, A, Name, {fn, _, nil, Clauses}}, S) ->
                                         var_functions(A, Name, Clauses, S)
                                 end, St, Tops),
    Loaded = {eremote, A0, clj2_proto, loaded, [{elit, A0, Proto}, {elit, A0, Tag}, {elit, A0, M}]},
    Init = {efunction, A0, '__ns_init__', 0, [{eclause, A0, [], [], [Loaded]}]},
    {module_body(lists:append(Funs), Init, A0), St1}.

%% Each top node → {Functions, InitSteps}
top({eval, _, X}, St) ->
    {E, St1} = expr(X, St),
    {{[], [E]}, St1};
top({def, A, Name, _Meta, {fn, _, nil, Clauses}}, St = #{vars := Vars})
  when map_get(kind, map_get(Name, Vars)) =:= fn ->
    {Fs, St1} = var_functions(A, Name, Clauses, St),
    {{Fs, []}, St1};
top({def, A, Name, _Meta, Init}, St = #{module := M, vars := Vars}) ->
    case maps:get(Name, Vars) of
        #{kind := const} ->
            {C, St1} = expr(Init, St),
            {{[accessor(A, Name, C)], []}, St1};
        Info ->
            Read = case Info of
                       #{dynamic := true} -> deref;
                       _ -> root
                   end,
            Acc = accessor(A, Name, {eremote, A, clj2_var, Read, [{elit, A, M}, {elit, A, Name}]}),
            case Init of
                nil -> {{[Acc], []}, St};
                _ ->
                    {I, St1} = expr(Init, St),
                    Set = {eremote, A, clj2_var, set_root, [{elit, A, M}, {elit, A, Name}, I]},
                    {{[Acc], [Set]}, St1}
            end
    end.

%% the clauses of a fn → module functions Name/N; recur in them calls
%% the function itself
var_functions(A, Name, Clauses, St) ->
    Names = maps:from_list([{CName, Name} || {clause, _, CName, _, _, _} <- Clauses]),
    St0 = St#{fun_names := maps:merge(maps:get(fun_names, St), Names)},
    lists:mapfoldl(
      fun({clause, CA, _CName, Ps, Rest, Body}, S) ->
              {B, S1} = expr(Body, S),
              Params = [{evar, CA, P} || P <- Ps] ++ [{evar, CA, Rest} || Rest =/= nil],
              {{efunction, A, Name, length(Params), [{eclause, CA, Params, [], [B]}]}, S1}
      end, St0, Clauses).

accessor(A, Name, Body) ->
    {efunction, A, Name, 0, [{eclause, A, [], [], [Body]}]}.

%% on_load: register, run steps in order; on failure tell the registry
%% (the loader is another process) and fail the load. A compile-time
%% segment (`register => false') neither registers nor reports under the
%% namespace's name, so a failing compile never unregisters it.
init_fun(Ns, M, Vars, Steps, A, Register, St) ->
    {[C, R, S], St1} = fresh_n(['C', 'R', 'S'], St),
    Reg = case Register of
              false -> {elit, A, ok};
              true -> {eremote, A, clj2_ns, register, [{elit, A, Ns}, {elit, A, M}, {elit, A, Vars}]}
          end,
    FailName = case Register of
                   true -> Ns;
                   false -> M
               end,
    Exc = {etuple, A, [{evar, A, C}, {evar, A, R}, {evar, A, S}]},
    Fail = {eremote, A, clj2_ns, init_failed, [{elit, A, FailName}, Exc]},
    Try = {etry, A, [Reg | Steps] ++ [{elit, A, ok}],
           [{eclause, A, [Exc], [], [Fail, {elit, A, {error, init_failed}}]}],
           []},
    {{efunction, A, '__ns_init__', 0, [{eclause, A, [], [], [Try]}]}, St1}.

%%====================================================================
%% Expressions
%%====================================================================

expr({const, A, V}, St) -> {{elit, A, V}, St};
expr({local, A, U}, St) -> {{evar, A, U}, St};

expr({'if', A, T, Then, Else}, St) ->
    {TE, St1} = expr(T, St),
    {ThenE, St2} = expr(Then, St1),
    {ElseE, St3} = expr(Else, St2),
    Falsey = [[{gop, A, '=:=', [TE, {elit, A, false}]}],
              [{gop, A, '=:=', [TE, {elit, A, nil}]}]],
    {{eif, A, [{eclause, A, [], Falsey, [ElseE]},
               {eclause, A, [], [[{elit, A, true}]], [ThenE]}]}, St3};

expr({'case', A, X, Clauses, Default}, St) ->
    {XE, St1} = expr(X, St),
    {Cs, St2} = lists:mapfoldl(fun case_clause/2, St1, Clauses),
    {DC, St3} = case Default of
                    nil ->
                        {V, S} = fresh(no_match, St2),
                        {{eclause, A, [{evar, A, V}], [],
                          [{eremote, A, clj2_rt, no_matching_clause, [{evar, A, V}]}]}, S};
                    _ ->
                        {D, S} = expr(Default, St2),
                        {{eclause, A, [{ewild, A}], [], [D]}, S}
                end,
    {{ecase, A, XE, Cs ++ [DC]}, St3};

expr({do, A, Stmts, Ret}, St) ->
    {Es, St1} = lists:mapfoldl(fun expr/2, St, Stmts ++ [Ret]),
    {{eblock, A, Es}, St1};

expr({'let', A, Binds, Body}, St) ->
    {Ms, St1} = lists:mapfoldl(fun({bind, BA, U, X}, S) ->
                                       {E, S1} = expr(X, S),
                                       {{ematch, BA, {evar, BA, U}, E}, S1}
                               end, St, Binds),
    {B, St2} = expr(Body, St1),
    {{eblock, A, Ms ++ [B]}, St2};

expr({fn, _A, Self, [{clause, _, _, _, nil, _} = C]}, St) ->
    clause_fun(C, Self, St);
expr({fn, A, Self, Clauses}, St) ->
    %% a self-named multi-arity fn was turned into a group by lower-letfn
    Self =:= nil orelse fail(A, self_name_on_multi_arity_fn),
    {Fixed, St1} = lists:mapfoldl(
                     fun(C = {clause, CA, _, Ps, nil, _}, S) ->
                             {F, S1} = clause_fun(C, nil, S),
                             {{eassoc, CA, {elit, CA, length(Ps)}, F}, S1}
                     end, St, [C || C = {clause, _, _, _, nil, _} <- Clauses]),
    {Var, St2} = case [C || C = {clause, _, _, _, R, _} <- Clauses, R =/= nil] of
                     [] -> {{elit, A, nil}, St1};
                     [C = {clause, CA, _, Ps, _, _}] ->
                         {F, S1} = clause_fun(C, nil, St1),
                         {{etuple, CA, [{elit, CA, length(Ps)}, F]}, S1}
                 end,
    {{etuple, A, [{elit, A, clj2_fn}, {emap, A, Fixed}, Var]}, St2};

expr({self_call, A, Name, Args}, St = #{fun_names := FNs}) ->
    {As, St1} = lists:mapfoldl(fun expr/2, St, Args),
    case FNs of
        #{Name := VarFun} -> {{ecall, A, VarFun, As}, St1};
        _ -> {{eapply, A, {evar, A, Name}, As}, St1}
    end;

expr({call_var, A, M, Name, Args}, St = #{module := Unit}) ->
    {As, St1} = lists:mapfoldl(fun expr/2, St, Args),
    case M =:= Unit of
        true -> {{ecall, A, Name, As}, St1};
        false -> {{eremote, A, M, Name, As}, St1}
    end;
expr({fn_var, A, M, Name, _Fixed, _Min}, St = #{module := Unit}) when M =/= Unit ->
    {{eremote, A, M, '__fn__', [{elit, A, Name}]}, St};
expr({fn_var, A, _M, Name, Fixed, Min}, St) ->
    Ref = fun(N) -> {efunref, A, Name, N} end,
    case {Fixed, Min} of
        {[N], nil} -> {Ref(N), St};
        _ ->
            Map = {emap, A, [{eassoc, A, {elit, A, N}, Ref(N)} || N <- Fixed]},
            Var = case Min of
                      nil -> {elit, A, nil};
                      _ -> {etuple, A, [{elit, A, Min}, Ref(Min + 1)]}
                  end,
            {{etuple, A, [{elit, A, clj2_fn}, Map, Var]}, St}
    end;
expr({list, A, Items}, St) ->
    {Es, St1} = lists:mapfoldl(fun expr/2, St, Items),
    {{elist, A, Es}, St1};

%% a fn literal head with a matching single fixed clause: direct call
expr({invoke, A, {fn, _, _, [{clause, _, _, Ps, nil, _}]} = F, Args}, St)
  when length(Ps) =:= length(Args) ->
    {FE, St1} = expr(F, St),
    {As, St2} = lists:mapfoldl(fun expr/2, St1, Args),
    {{eapply, A, FE, As}, St2};
expr({invoke, A, {fn, _, _, _} = F, Args}, St) ->
    %% other fn literal heads: bind, then the generic path
    {U, St1} = fresh(f, St),
    {FE, St2} = expr(F, St1),
    {Call, St3} = expr({invoke, A, {local, A, U}, Args}, St2),
    {{eblock, A, [{ematch, A, {evar, A, U}, FE}, Call]}, St3};
%% a constant head is never a fun: a keyword looks itself up, anything
%% else goes to the runtime (IFn of data, or the not-a-fn error)
expr({invoke, A, {const, _, K}, [X]}, St) when is_atom(K), K =/= nil, K =/= true, K =/= false ->
    {XE, St1} = expr(X, St),
    {{eremote, A, clj2_coll, get, [XE, {elit, A, K}]}, St1};
expr({invoke, A, {const, _, K}, [X, D]}, St) when is_atom(K), K =/= nil, K =/= true, K =/= false ->
    {[XE, DE], St1} = lists:mapfoldl(fun expr/2, St, [X, D]),
    {{eremote, A, clj2_coll, get, [XE, {elit, A, K}, DE]}, St1};
expr({invoke, A, {const, _, _} = F, Args}, St) ->
    {FE, St1} = expr(F, St),
    {As, St2} = lists:mapfoldl(fun expr/2, St1, Args),
    {{eremote, A, clj2_rt, invoke, [FE, {elist, A, As}]}, St2};
expr({invoke, A, F, Args}, St) ->
    {FE, St1} = expr(F, St),
    {As, St2} = lists:mapfoldl(fun expr/2, St1, Args),
    Guard = [[{gcall, A, is_function, [FE, {elit, A, length(Args)}]}]],
    {{ecase, A, FE,
      [{eclause, A, [{ewild, A}], Guard, [{eapply, A, FE, As}]},
       {eclause, A, [{ewild, A}], [], [{eremote, A, clj2_rt, invoke, [FE, {elist, A, As}]}]}]},
     St2};

expr({erl_call, A, M, F, Args}, St) ->
    {As, St1} = lists:mapfoldl(fun expr/2, St, Args),
    {{eremote, A, M, F, As}, St1};

expr({throw, A, X}, St) ->
    {E, St1} = expr(X, St),
    {{eremote, A, erlang, error, [E]}, St1};

expr({'try', A, Body, Catches, Fin}, St) ->
    case lists:all(fun({'catch', _, C, _, _}) -> lists:member(C, [error, exit, throw, any]) end, Catches) of
        true -> try_erlang_classes(A, Body, Catches, Fin, St);
        false -> try_by_class(A, Body, Catches, Fin, St)
    end;

expr({fn_group, A, G, Fns}, St) ->
    {Cs, St1} = lists:mapfoldl(
                  fun({J, F}, S) ->
                          {FE, S1} = expr(F, S),
                          {{eclause, A, [{elit, A, J}], [], [FE]}, S1}
                  end, St, lists:zip(lists:seq(1, length(Fns)), Fns)),
    {{enamed, A, G, Cs}, St1};
expr({group_ref, A, G, J}, St) ->
    {{eapply, A, {evar, A, G}, [{elit, A, J}]}, St}.

%%====================================================================
%% Helpers
%%====================================================================

%% one clause → an Erlang named fun (the name is the recur target)
clause_fun({clause, A, Name, Ps, Rest, Body}, Self, St) ->
    {B, St1} = expr(Body, St),
    Params = [{evar, A, P} || P <- Ps] ++ [{evar, A, Rest} || Rest =/= nil],
    SelfBind = [{ematch, A, {evar, A, Self}, {evar, A, Name}} || Self =/= nil],
    {{enamed, A, Name, [{eclause, A, Params, [], SelfBind ++ [B]}]}, St1}.

case_clause({cclause, A, [C], R}, St) ->
    case pattern_safe(C) of
        true ->
            {RE, St1} = expr(R, St),
            {{eclause, A, [{elit, A, C}], [], [RE]}, St1};
        false -> guard_clause(A, [C], R, St)
    end;
case_clause({cclause, A, Cs, R}, St) ->
    guard_clause(A, Cs, R, St).

guard_clause(A, Cs, R, St) ->
    {V, St1} = fresh(case_val, St),
    {RE, St2} = expr(R, St1),
    Guards = [[{gop, A, '=:=', [{evar, A, V}, {elit, A, C}]}] || C <- Cs],
    {{eclause, A, [{evar, A, V}], Guards, [RE]}, St2}.

%% a literal pattern matches exactly what =:= does, except that a map
%% pattern also matches larger maps
pattern_safe(X) when is_map(X) -> false;
pattern_safe(X) when is_list(X) -> lists:all(fun pattern_safe/1, X);
pattern_safe(X) when is_tuple(X) -> pattern_safe(tuple_to_list(X));
pattern_safe(_) -> true.

fresh(S, St = #{next_uid := N}) -> {{S, N}, St#{next_uid := N + 1}}.

fresh_n(Names, St) -> lists:mapfoldl(fun fresh/2, St, Names).

fail(A, Why) -> erlang:error({clj2_compile, erl_anno:location(A), {lower_labs, Why}}).

%% catches that name only Erlang classes: one clause each
try_erlang_classes(A, Body, Catches, Fin, St) ->
    {B, St1} = expr(Body, St),
    {Cs, St2} = lists:mapfoldl(
                  fun({'catch', CA, Class, U, CB}, S) ->
                          {CBE, S1} = expr(CB, S),
                          ClassPat = case Class of
                                         any -> {ewild, CA};
                                         _ -> {elit, CA, Class}
                                     end,
                          Pat = {etuple, CA, [ClassPat, {evar, CA, U}, {ewild, CA}]},
                          {{eclause, CA, [Pat], [], [CBE]}, S1}
                  end, St1, Catches),
    {After, St3} = case Fin of
                       nil -> {[], St2};
                       _ -> {FE, S3} = expr(Fin, St2), {[FE], S3}
                   end,
    {{etry, A, [B], Cs, After}, St3}.

%% catches naming JVM classes: one clause takes everything and tries the
%% catches in order (a class test is a call, which a pattern cannot make);
%% when none applies the exception goes on as it came
try_by_class(A, Body, Catches, Fin, St) ->
    {B, St1} = expr(Body, St),
    {[C, R, S], St2} = fresh_n(['C', 'R', 'S'], St1),
    {Dispatch, St3} = dispatch_catches(Catches, C, R, S, A, St2),
    Pat = {etuple, A, [{evar, A, C}, {evar, A, R}, {evar, A, S}]},
    {After, St4} = case Fin of
                       nil -> {[], St3};
                       _ -> {FE, S4} = expr(Fin, St3), {[FE], S4}
                   end,
    {{etry, A, [B], [{eclause, A, [Pat], [], [Dispatch]}], After}, St4}.

dispatch_catches([], C, R, S, A, St) ->
    {{eremote, A, erlang, raise, [{evar, A, C}, {evar, A, R}, {evar, A, S}]}, St};
dispatch_catches([{'catch', CA, Class, U, CB} | Rest], C, R, S, A, St) ->
    {Handler, St1} = expr(CB, St),
    {Next, St2} = dispatch_catches(Rest, C, R, S, A, St1),
    IsClass = fun(K) -> {eop, CA, '=:=', [{evar, CA, C}, {elit, CA, K}]} end,
    Test = case Class of
               any -> {elit, CA, true};
               throwable -> {elit, CA, true};
               error -> IsClass(error);
               exit -> IsClass(exit);
               throw -> IsClass(throw);
               JVM -> {eop, CA, 'andalso',
                       [IsClass(error),
                        {eremote, CA, clj2_class, exception_matches, [{elit, CA, JVM}, {evar, CA, R}]}]}
           end,
    %% a JVM-class catch binds a throwable: an ex-info as it is, an
    %% Erlang error as an ex-info of its JVM class (clj2_rt:throwable/2)
    Val = case lists:member(Class, [any, error, exit, throw]) of
              true -> {evar, CA, R};
              false -> {eremote, CA, clj2_rt, throwable, [{evar, CA, C}, {evar, CA, R}]}
          end,
    Bound = {eblock, CA, [{ematch, CA, {evar, CA, U}, Val}, Handler]},
    {{ecase, CA, Test, [{eclause, CA, [{elit, CA, true}], [], [Bound]},
                        {eclause, CA, [{elit, CA, false}], [], [Next]}]}, St2}.

