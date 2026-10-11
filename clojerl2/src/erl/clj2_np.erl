%%%-------------------------------------------------------------------
%%% @doc clj2_np — nanopass framework in Erlang (designs/01 §3, D3).
%%%
%%% A language is data (see {@link clj2_lang}): a map of nonterminals,
%%% each a map `Op => [FieldKind]', plus terminal predicates. Nodes are
%%% tuples shaped like absform: `{Op, Anno, Field1, ..., FieldN}'.
%%%
%%% FieldKind :: Terminal | Nonterminal | {list, FieldKind} | {opt, FieldKind}
%%%   (`{opt, K}' holds `nil' or a K.)
%%%
%%% A nonterminal may include others (`includes => #{expr => [triv]}'),
%%% nanopass's `Expr ::= t': where an `expr' is expected, any `triv' node
%%% is accepted. Processors are chosen by the field's declared
%%% nonterminal; a missing one is the default descent.
%%%
%%% What the framework gives a pass (the part nanopass auto-generates):
%%%
%%%   * `descend/4'  — rebuild a node with every nonterminal child run
%%%                    through the pass's processor for that nonterminal
%%%                    (default: keep descending).  This is the
%%%                    "system clause": a pass only writes clauses for
%%%                    the ops it changes and ends with
%%%                    `expr(N, Ctx) -> clj2_np:descend(Lang, Procs, N, Ctx)'.
%%%   * `mapfold/4'  — the same with a threaded accumulator.
%%%   * `fold/4', `children/2' — read-only traversal for analysis passes.
%%%   * `check/2'    — validate a whole tree against a language (dev mode
%%%                    runs it after every pass: "pass boundary = grammar
%%%                    contract").
%%%   * `run/3'      — pipeline driver with check/trace options.
%%%-------------------------------------------------------------------
-module(clj2_np).

-export([ descend/4
        , mapfold/4
        , fold/4
        , children/2
        , check/2
        , nonterminal_of/2
        , run/3
        , diff_languages/2
        ]).

-export_type([lang/0, tree/0, pass_state/0]).

-type lang()       :: map().
-type tree()       :: tuple().
-type pass_state() :: map().

%%====================================================================
%% Traversal
%%====================================================================

%% @doc Rebuild `Node' with each nonterminal child replaced by
%% `Proc(Child, Ctx)', where `Proc' comes from `Procs' for the child's
%% nonterminal, or defaults to descending further.
-spec descend(lang(), #{atom() => fun()}, tree(), term()) -> tree().
descend(Lang, Procs, Node, Ctx) ->
    {Node1, _} = mapfold(Lang,
                         maps:map(fun(_, F) ->
                                      fun(N, A) -> {F(N, Ctx), A} end
                                  end, Procs),
                         Node, nil),
    Node1.

%% @doc Like descend/4, but every processor is `fun((Node, Acc) -> {Node, Acc})'.
-spec mapfold(lang(), #{atom() => fun()}, tree(), Acc) -> {tree(), Acc}.
mapfold(Lang, Procs, Node, Acc) ->
    [Op, Anno | Fields] = tuple_to_list(Node),
    Kinds = field_kinds(Lang, Op, Node),
    {Fields1, Acc1} =
        lists:mapfoldl(fun({K, F}, A) -> map_field(Lang, Procs, K, F, A) end,
                       Acc, lists:zip(Kinds, Fields)),
    {list_to_tuple([Op, Anno | Fields1]), Acc1}.

map_field(Lang, Procs, {list, K}, Xs, Acc) when is_list(Xs) ->
    lists:mapfoldl(fun(X, A) -> map_field(Lang, Procs, K, X, A) end, Acc, Xs);
map_field(_Lang, _Procs, {opt, _K}, nil, Acc) ->
    {nil, Acc};
map_field(Lang, Procs, {opt, K}, X, Acc) ->
    map_field(Lang, Procs, K, X, Acc);
map_field(Lang, Procs, K, X, Acc) ->
    case is_nonterminal(Lang, K) of
        false -> {X, Acc};
        true ->
            case Procs of
                #{K := P} -> P(X, Acc);
                _ -> mapfold(Lang, Procs, X, Acc)
            end
    end.

%% @doc Pre-order fold over every node of the tree.
-spec fold(lang(), fun((tree(), Acc) -> Acc), Acc, tree()) -> Acc.
fold(Lang, Fun, Acc, Node) ->
    lists:foldl(fun({_NT, C}, A) -> fold(Lang, Fun, A, C) end,
                Fun(Node, Acc), children(Lang, Node)).

%% @doc Direct nonterminal children of a node, in field order.
-spec children(lang(), tree()) -> [{atom(), tree()}].
children(Lang, Node) ->
    [Op, _Anno | Fields] = tuple_to_list(Node),
    Kinds = field_kinds(Lang, Op, Node),
    lists:append([field_children(Lang, K, F) || {K, F} <- lists:zip(Kinds, Fields)]).

field_children(Lang, {list, K}, Xs) ->
    lists:append([field_children(Lang, K, X) || X <- Xs]);
field_children(_Lang, {opt, _}, nil) -> [];
field_children(Lang, {opt, K}, X) -> field_children(Lang, K, X);
field_children(Lang, K, X) ->
    case is_nonterminal(Lang, K) of
        true -> [{K, X}];
        false -> []
    end.

%%====================================================================
%% Validation
%%====================================================================

%% @doc Validate `Tree' (an instance of the language's entry nonterminal).
%% Returns `ok' or raises `{clj2_np, {bad_tree, Lang, Path, Why}}'.
-spec check(lang(), tree()) -> ok.
check(Lang = #{entry := Entry}, Tree) ->
    check_kind(Lang, Entry, Tree, []).

check_kind(Lang, {list, K}, Xs, Path) ->
    case is_list(Xs) of
        true ->
            _ = [check_kind(Lang, K, X, [I | Path])
                 || {I, X} <- lists:zip(lists:seq(1, length(Xs)), Xs)],
            ok;
        false -> bad(Lang, Path, {expected_list, Xs})
    end;
check_kind(_Lang, {opt, _K}, nil, _Path) -> ok;
check_kind(Lang, {opt, K}, X, Path) -> check_kind(Lang, K, X, Path);
check_kind(Lang = #{terminals := Ts, nonterminals := NTs}, K, X, Path) ->
    case {Ts, NTs} of
        {#{K := Pred}, _} ->
            case Pred(X) of
                true -> ok;
                false -> bad(Lang, Path, {bad_terminal, K, X})
            end;
        {_, #{K := Ops}} ->
            check_node(Lang, K, Ops, X, Path);
        _ ->
            bad(Lang, Path, {unknown_kind, K})
    end.

check_node(Lang = #{nonterminals := NTs}, NT, Ops, X, Path) when is_tuple(X), tuple_size(X) >= 2 ->
    Op = element(1, X),
    Owner = nonterminal_of(Lang, Op),
    case Ops of
        #{Op := _} -> check_own(Lang, NT, Ops, X, Path);
        _ when Owner =/= none ->
            case lists:member(Owner, included(Lang, NT)) of
                true -> check_own(Lang, Owner, maps:get(Owner, NTs), X, Path);
                false -> bad(Lang, Path, {op_not_in_nonterminal, NT, Op})
            end;
        _ -> bad(Lang, Path, {op_not_in_nonterminal, NT, Op})
    end;
check_node(Lang, NT, _Ops, X, Path) ->
    bad(Lang, Path, {not_a_node, NT, X}).

check_own(Lang, NT, Ops, X, Path) ->
    Op = element(1, X),
    case Ops of
        #{Op := Kinds} when length(Kinds) =:= tuple_size(X) - 2 ->
            [_, _ | Fields] = tuple_to_list(X),
            _ = [check_kind(Lang, K, F, [{Op, I} | Path])
                 || {I, K, F} <- lists:zip3(lists:seq(1, length(Kinds)), Kinds, Fields)],
            ok;
        #{Op := Kinds} ->
            bad(Lang, Path, {bad_arity, NT, Op, length(Kinds), X})
    end.

%% nonterminals transitively included by NT
included(Lang, NT) -> included(Lang, maps:get(NT, maps:get(includes, Lang, #{}), []), []).

included(_Lang, [], Acc) -> Acc;
included(Lang, [I | Is], Acc) ->
    case lists:member(I, Acc) of
        true -> included(Lang, Is, Acc);
        false -> included(Lang, Is ++ maps:get(I, maps:get(includes, Lang, #{}), []), [I | Acc])
    end.

bad(#{name := Name}, Path, Why) ->
    erlang:error({clj2_np, {bad_tree, Name, lists:reverse(Path), Why}}).

%%====================================================================
%% Pipeline driver
%%====================================================================

%% @doc Run `Passes' (pass modules) over `Input'.
%%
%% A pass module exports `pass() -> #{name, in, out}' and
%% `run(Tree, PassState) -> {Tree, PassState}'. `in'/`out' name
%% languages of {@link clj2_lang} (`lcore'/`absform' are boundaries and
%% are not checked).
%%
%% A pipeline element may also be `{fixpoint, [Pass], #{max_iter => N}}':
%% the group (each pass Lx → Lx) is re-run until the tree stops changing
%% or N rounds have run (jolt's fixpoint cluster; optimisations that
%% enable each other, designs/01 §3).
%%
%% Opts: `check' (default true) validates every pass output against its
%% `out' language; `trace' is a list of pass names whose output is
%% handed to `trace_fun' (default: printed; nanopass's trace/echo).
-spec run([module() | {fixpoint, [module()], map()}], term(), map()) ->
          {term(), pass_state()}.
run(Passes, Input, Opts) ->
    St0 = maps:get(state, Opts, #{next_uid => 1}),
    lists:foldl(fun(P, Acc) -> run_one(P, Acc, Opts) end, {Input, St0}, Passes).

run_one({fixpoint, Group, FOpts}, {Tree, St}, Opts) ->
    fixpoint(Group, Tree, St, Opts, maps:get(max_iter, FOpts, 8));
run_one(P, {Tree, St}, Opts) ->
    #{name := Name, out := Out} = P:pass(),
    {Tree1, St1} = P:run(Tree, St),
    _ = maps:get(check, Opts, true) andalso is_checked(Out) andalso
            ok =:= check_out(clj2_lang:get(Out), Tree1),
    _ = lists:member(Name, maps:get(trace, Opts, [])) andalso
            ok =:= (maps:get(trace_fun, Opts, fun print_trace/3))(Name, Out, Tree1),
    {Tree1, St1}.

print_trace(Name, Out, Tree) ->
    io:format(user, "~n;; ---- ~s -> ~s~n~p~n", [Name, Out, Tree]).

fixpoint(_Group, Tree, St, _Opts, 0) -> {Tree, St};
fixpoint(Group, Tree, St, Opts, N) ->
    {Tree1, St1} = lists:foldl(fun(P, Acc) -> run_one(P, Acc, Opts) end, {Tree, St}, Group),
    case Tree1 =:= Tree of
        true -> {Tree1, St1};
        false -> fixpoint(Group, Tree1, St1, Opts, N - 1)
    end.

is_checked(Out) -> Out =/= lcore andalso Out =/= absform.

%% A pass may produce one tree or a list of top-level trees.
check_out(Lang, Trees) when is_list(Trees) -> lists:foreach(fun(T) -> check(Lang, T) end, Trees);
check_out(Lang, Tree) -> check(Lang, Tree).

%% @doc Production-level difference between two languages (nanopass's
%% `diff-languages'): per nonterminal, ops added, removed, or whose
%% fields changed.
-spec diff_languages(lang(), lang()) -> #{atom() => map()}.
diff_languages(#{nonterminals := A}, #{nonterminals := B}) ->
    NTs = lists:usort(maps:keys(A) ++ maps:keys(B)),
    maps:from_list(
      [{NT, #{added => lists:sort(maps:keys(maps:without(maps:keys(OA), OB))),
              removed => lists:sort(maps:keys(maps:without(maps:keys(OB), OA))),
              changed => lists:sort([Op || {Op, K} <- maps:to_list(OA),
                                           maps:is_key(Op, OB), maps:get(Op, OB) =/= K])}}
       || NT <- NTs,
          OA <- [maps:get(NT, A, #{})], OB <- [maps:get(NT, B, #{})], OA =/= OB]).

%%====================================================================
%% Internal
%%====================================================================

%% @doc Which nonterminal of `Lang' owns `Op'.
-spec nonterminal_of(lang(), atom()) -> atom() | none.
nonterminal_of(#{op_index := Idx}, Op) -> maps:get(Op, Idx, none).

field_kinds(Lang = #{nonterminals := NTs}, Op, Node) ->
    case nonterminal_of(Lang, Op) of
        none -> bad(Lang, [], {unknown_op, Op, Node});
        NT ->
            #{Op := Kinds} = maps:get(NT, NTs),
            case length(Kinds) =:= tuple_size(Node) - 2 of
                true -> Kinds;
                false -> bad(Lang, [], {bad_arity, NT, Op, length(Kinds), Node})
            end
    end.

is_nonterminal(#{nonterminals := NTs}, K) when is_atom(K) -> maps:is_key(K, NTs);
is_nonterminal(_, _) -> false.
