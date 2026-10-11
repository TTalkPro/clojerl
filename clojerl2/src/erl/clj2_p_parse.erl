%%%-------------------------------------------------------------------
%%% @doc parse: Lcore → L0 (designs/01 §5 pass 1), with macro expansion.
%%%
%%% Input is reader output (`clj2_loc'-wrapped data) or macro output
%%% (runtime values, see {@link clj2_form}). Special forms become L0
%%% nodes; any other list is `invoke'. Positions become the node Anno;
%%% forms without a wrapper (macro output) inherit the enclosing position.
%%%
%%% Output is a list of `top' nodes: `ns_decl' (only as the first form),
%%% `def', and `eval' for every other form. A top-level `do' is
%%% flattened, as in Clojure, so `(do (def a 1) (def b 2))' defines both.
%%%
%%% Macros (designs/01 §4): a list whose head is a symbol that is not a
%%% special form and not a local is offered to the `expand' capability
%%% the driver puts in the pass state:
%%%
%%%   Expand(Sym, FormData, EnvData) -> {ok, NewFormData} | none
%%%
%%% Running macros is the driver's effect; parse stays a function of its
%%% input and that capability. Locals shadow macros, as in Clojure.
%%%
%%% Syntax-quote is expanded here (Clojure does it in the reader):
%%% symbols are namespace-qualified (special forms excepted, aliases
%%% expanded, referred vars to their namespace, the rest to the current
%%% one), `x#' becomes `x__auto__L_C' (fixed per syntax-quote, so builds
%%% are deterministic), `~'/`~@' build lists through clj2_coll.
%%%
%%% Kernel forms (they need the namespace or the compiler, so they are
%%% not macros): `ns' (`:require' with `:as'/`:refer', `:refer-clojure
%%% :exclude'), `defmacro', and the protocol forms (designs/03 §4,
%%% clojerl2-016): `defprotocol', `extend-type', `extend-protocol',
%%% `deftype', `defrecord'. extend-type produces `extend' top nodes,
%%% which the driver compiles into impl modules.
%%%
%%% `(case* e t1 r1 t2 r2 ... default?)': each test is a constant, or a
%%% list of constants grouped on one result (what `case' expands to);
%%% without a default an unmatched value raises.
%%%
%%% `@x' reads as (clojure.core/deref x).
%%%
%%% Not yet: interop, receive*, var, regex, tagged literals.
%%%-------------------------------------------------------------------
-module(clj2_p_parse).

-include("clojerl2.hrl").

-export([pass/0, run/2, specials/0]).

pass() -> #{name => parse, in => lcore, out => l0}.

specials() ->
    [quote, 'if', do, 'let*', 'loop*', recur, 'fn*', 'letfn*', throw, 'try',
     'catch', finally, def, var, '.', new, 'set!', 'case*', 'deftype*', 'reify*',
     'receive*', '&', ns | kernel_forms()].

kernel_forms() ->
    [defmacro, defprotocol, 'extend-type', 'extend-protocol', deftype, defrecord].

%% a kernel form, bare or as clojure.core/X (syntax-quote output)
kernel_form(S) when is_atom(S) ->
    Bare = case atom_to_list(S) of
               "clojure.core/" ++ N -> list_to_atom(N);
               _ -> S
           end,
    case lists:member(Bare, kernel_forms()) of
        true -> Bare;
        false -> none
    end;
kernel_form(_) -> none.

%% St may carry: ns, aliases, refers (namespace context for
%% syntax-quote) and expand (the macro capability).
run(Forms, St) when is_list(Forms) ->
    E0 = #{locals => #{},
           expand => maps:get(expand, St, none),
           ns => maps:get(ns, St, user),
           aliases => maps:get(aliases, St, #{}),
           refers => maps:get(refers, St, #{}),
           own_names => maps:get(own_names, St, #{})},
    A0 = erl_anno:new(0),
    {RevTops, _} = lists:foldl(fun(F, {Acc, E}) ->
                                       Ts = top(F, A0, E),
                                       {lists:reverse(Ts, Acc), ns_env(Ts, E)}
                               end, {[], E0}, Forms),
    Tops = lists:reverse(RevTops),
    _ = [syntax(A, ns_must_be_first_form) || {ns_decl, A, _, _, _} <- tl(Tops ++ [x])],
    {Tops, St}.

%% an `ns' form sets the context of the forms after it
ns_env(Tops, E) ->
    case [T || T = {ns_decl, _, _, _, _} <- Tops] of
        [{ns_decl, _, Ns, Reqs, _}] ->
            E#{ns := Ns,
               aliases := maps:from_list([{As, R} || #{ns := R, as := As} <- Reqs, As =/= nil]),
               refers := maps:from_list([{S, R} || #{ns := R, refer := Ss} <- Reqs, S <- Ss])};
        _ -> E
    end.

%%====================================================================
%% Top level
%%====================================================================

top(F, A0, E) ->
    A = pos(F, A0),
    case unwrap(F) of
        [H | Rest] ->
            case unwrap(H) of
                do -> lists:append([top(X, A, E) || X <- Rest]);
                def -> [def_form(Rest, A, E)];
                ns -> [ns_form(Rest, A)];
                S when is_atom(S) ->
                    case kernel_form(S) of
                        defmacro -> [defmacro_form(Rest, A, E)];
                        defprotocol -> defprotocol_form(Rest, A, E);
                        'extend-type' -> extend_type_form(Rest, A, E, none);
                        'extend-protocol' -> extend_protocol_form(Rest, A, E);
                        deftype -> deftype_form(deftype, Rest, A, E);
                        defrecord -> deftype_form(defrecord, Rest, A, E);
                        none ->
                            case macroexpand(S, F, A, E) of
                                {ok, X} -> top(X, A, E);
                                none -> [{eval, A, form(F, A0, E)}]
                            end
                    end;
                _ -> [{eval, A, form(F, A0, E)}]
            end;
        _ -> [{eval, A, form(F, A0, E)}]
    end.

%% (def name) | (def name init) | (def name "doc" init)
def_form([N | Rest], A, E) ->
    def_form(binder(N, A), name_meta(N), Rest, A, E);
def_form([], A, _E) -> syntax(A, bad_def).

def_form(Name, Meta0, Rest, A, E) ->
    case [unwrap(X) || X <- Rest] of
        [] -> {def, A, Name, Meta0, nil};
        [_] -> {def, A, Name, Meta0, form(hd(Rest), A, E)};
        [Doc, _] when is_binary(Doc) ->
            {def, A, Name, Meta0#{':doc' => Doc}, form(lists:last(Rest), A, E)};
        _ -> syntax(A, bad_def)
    end.

name_meta(W) when ?CLJ2_IS_LOC(W) ->
    case ?CLJ2_LOC_META(W) of
        M when is_map(M) -> M;
        _ -> #{}
    end;
name_meta(_) -> #{}.

%% (defmacro name doc? attr-map? [params] body*)
%% (defmacro name doc? attr-map? ([params] body*)+)
%%   ⇒ (def ^:macro name (fn* name ([&form &env params...] body*) ...))
defmacro_form([N | Rest0], A, E) ->
    Name = binder(N, A),
    {Meta1, Rest1} = case Rest0 of
                         [D | R1] -> case unwrap(D) of
                                         Doc when is_binary(Doc), R1 =/= [] ->
                                             {#{':doc' => Doc}, R1};
                                         _ -> {#{}, Rest0}
                                     end;
                         [] -> {#{}, Rest0}
                     end,
    Rest2 = case Rest1 of
                [M | R2] -> case clj2_form:map_pairs(unwrap(M)) of
                                false -> Rest1;
                                _ when R2 =:= [] -> Rest1;
                                _ -> R2
                            end;
                [] -> syntax(A, bad_defmacro)
            end,
    Clauses = case clj2_form:vector_items(unwrap(hd(Rest2))) of
                  false -> Rest2;                                % ([p] b) ...
                  _ -> [Rest2]                                   % [p] b ...
              end,
    WithEnv = [case unwrap(C) of
                   [Ps | Body] ->
                       case clj2_form:vector_items(unwrap(Ps)) of
                           false -> syntax(pos(C, A), bad_defmacro_params);
                           Items -> [clj2_coll:vector(['&form', '&env' | Items]) | Body]
                       end;
                   _ -> syntax(pos(C, A), bad_defmacro)
               end || C <- Clauses],
    Fn = fn([Name | WithEnv], A, E),
    {def, A, Name, (maps:merge(name_meta(N), Meta1))#{':macro' => true}, Fn};
defmacro_form([], A, _E) -> syntax(A, bad_defmacro).

%% (ns name docstring? (:require spec ...)*)
ns_form([N | Clauses], A) ->
    Name = case unwrap(N) of
               S when is_atom(S), S =/= nil -> S;
               _ -> syntax(A, bad_ns_name)
           end,
    Reqs = lists:append([ns_clause(C, A) || C <- Clauses, not is_binary(unwrap(C))]),
    Meta = case [unwrap(C) || C <- Clauses, is_binary(unwrap(C))] of
               [Doc | _] -> #{':doc' => Doc};
               [] -> #{}
           end,
    {ns_decl, A, Name, Reqs, Meta};
ns_form([], A) -> syntax(A, bad_ns_name).

ns_clause(C, A) ->
    CA = pos(C, A),
    case unwrap(C) of
        [H | Specs] ->
            case unwrap(H) of
                ':require' -> [require_spec(S, CA) || S <- Specs];
                ':refer-clojure' ->
                    case [unwrap(X) || X <- Specs] of
                        [':exclude', V] ->
                            case clj2_form:vector_items(V) of
                                false -> syntax(CA, bad_refer_clojure);
                                Syms -> [#{refer_clojure => #{exclude => [unwrap(X) || X <- Syms]}}]
                            end;
                        _ -> unsupported(CA, {refer_clojure, Specs})
                    end;
                Other -> unsupported(CA, {ns_clause, Other})
            end;
        _ -> syntax(CA, bad_ns_clause)
    end.

require_spec(S, A) ->
    SA = pos(S, A),
    case unwrap(S) of
        Ns when is_atom(Ns) -> #{ns => Ns, as => nil, refer => []};
        V ->
            case clj2_form:vector_items(V) of
                [N | Opts] ->
                    Ns = unwrap(N),
                    is_atom(Ns) orelse syntax(SA, bad_require),
                    require_opts([unwrap(O) || O <- Opts], #{ns => Ns, as => nil, refer => []}, SA);
                _ -> syntax(SA, bad_require)
            end
    end.

require_opts([], R, _A) -> R;
require_opts([':as', Alias | Rest], R, A) when is_atom(Alias) ->
    require_opts(Rest, R#{as := Alias}, A);
require_opts([':refer', V | Rest], R, A) ->
    case clj2_form:vector_items(V) of
        false -> syntax(A, bad_refer);
        Syms -> require_opts(Rest, R#{refer := [unwrap(X) || X <- Syms]}, A)
    end;
require_opts([Opt | _], _R, A) ->
    unsupported(A, {require_option, Opt}).

%%====================================================================
%% Forms
%%====================================================================

form(W, _Anno, E) when ?CLJ2_IS_LOC(W) ->
    form(?CLJ2_LOC_FORM(W), anno(W), E);
form(X, A, _E) when is_integer(X); is_float(X); is_binary(X) -> {const, A, X};
form(X, A, _E) when X =:= nil; X =:= true; X =:= false -> {const, A, X};
form(X, A, _E) when is_atom(X) ->
    case is_keyword(X) of
        true -> {const, A, X};
        false -> {sym, A, X}
    end;
form({ratio, _, _} = X, A, _E) -> {const, A, X};
form([], A, _E) -> {const, A, []};
form([Head | Args] = F, A, E) -> list_form(unwrap(Head), Head, Args, F, A, E);
form({syntax_quote, [], T}, A, E) -> squote(T, A, E);
form({fnstar, [], [{arity, [], [Ps, Body]}]}, A, E) -> fn([[Ps, Body]], A, E);
form({deref, [], X}, A, E) -> form(['clojure.core/deref', X], A, E);
form({var, [], X}, A, E) -> form([var, X], A, E);           % #'x
%% #"..." (as read, or as a value from a macro): checked now, as the JVM
%% reader does; compiled on first use (clj2_re)
form({regex, _, Src}, A, _E) when is_binary(Src) ->
    try {const, A, clj2_re:pattern(Src)}
    catch error:R -> syntax(A, {bad_regex, Src, R})
    end;
form({uuid, _, S} = U, A, _E) when is_binary(S) -> {const, A, U};
form({tagged, [], uuid, S}, A, _E) when is_binary(S) ->
    try {const, A, clj2_string:uuid(S)}
    catch error:_ -> syntax(A, {bad_uuid, S})
    end;
form({Unq, [], _}, A, _E) when Unq =:= unquote; Unq =:= unquote_splicing ->
    syntax(A, unquote_outside_syntax_quote);
form(X, A, E) ->
    case {clj2_form:vector_items(X), clj2_form:map_pairs(X), clj2_form:set_items(X)} of
        {Items, _, _} when Items =/= false -> coll(vector, Items, X, A, E);
        {_, Pairs, _} when Pairs =/= false ->
            coll(hash_map_kv, lists:append([[K, V] || {K, V} <- Pairs]), X, A, E);
        {_, _, Items} when Items =/= false -> coll(hash_set, Items, X, A, E);
        _ -> unsupported(A, {literal, element(1, X)})
    end.

%% A collection literal: a constant when every element is one, else
%% built at run time (clj2_coll).
coll(Ctor, Items, _X, A, E) ->
    Nodes = [form(I, A, E) || I <- Items],
    case lists:all(fun({const, _, _}) -> true; (_) -> false end, Nodes) of
        %% built from the elements' values: `{:a '(1)}' holds the list (1)
        true -> {const, A, clj2_coll:Ctor([V || {const, _, V} <- Nodes])};
        false -> {invoke, A, {sym, A, qsym(clj2_coll, Ctor)}, [{list, A, Nodes}]}
    end.

list_form(quote, _, [D], _F, A, _E) -> {const, A, clj2_form:to_data(D)};
list_form('if', _, [C, T], _F, A, E) -> {'if', A, form(C, A, E), form(T, A, E), {const, A, nil}};
list_form('if', _, [C, T, El], _F, A, E) -> {'if', A, form(C, A, E), form(T, A, E), form(El, A, E)};
list_form('do', _, Body, _F, A, E) -> body(Body, A, E);
list_form('let*', _, [Bs | Body], _F, A, E) ->
    {Binds, E1} = bindings(Bs, A, E),
    {'let', A, Binds, body(Body, A, E1)};
list_form('loop*', _, [Bs | Body], _F, A, E) ->
    {Binds, E1} = bindings(Bs, A, E),
    {loop, A, Binds, body(Body, A, E1)};
list_form(recur, _, Args, _F, A, E) -> {recur, A, [form(X, A, E) || X <- Args]};
list_form('fn*', _, Rest, _F, A, E) -> fn(Rest, A, E);
list_form('letfn*', _, [Bs | Body], _F, A, E) ->
    BA = pos(Bs, A),
    Items = case clj2_form:vector_items(unwrap(Bs)) of
                L when is_list(L), length(L) rem 2 =:= 0 -> L;
                _ -> syntax(BA, bad_binding_vector)
            end,
    Names = [binder(S, BA) || {S, _} <- pairs_of(Items)],
    E1 = add_locals(Names, E),
    Binds = [begin
                 Fn = form(F, pos(S, BA), E1),
                 case Fn of
                     {fn, _, _, _} -> ok;
                     _ -> syntax(pos(S, BA), {letfn_binding_not_fn, binder(S, BA)})
                 end,
                 {bind, pos(S, BA), binder(S, BA), Fn}
             end || {S, F} <- pairs_of(Items)],
    {letfn, A, Binds, body(Body, A, E1)};
list_form(throw, _, [X], _F, A, E) -> {throw, A, form(X, A, E)};
list_form('case*', _, [X | Rest], _F, A, E) -> case_form(X, Rest, A, E);
list_form('try', _, Body, _F, A, E) -> try_form(Body, A, E);
list_form(Special, _, Args, _F, A, _E) when Special =:= quote; Special =:= 'if';
                                            Special =:= throw; Special =:= 'let*';
                                            Special =:= 'loop*'; Special =:= 'letfn*' ->
    syntax(A, {bad_special_form, Special, length(Args)});
list_form(Def, _, _Args, _F, A, _E) when Def =:= def; Def =:= ns ->
    syntax(A, {not_at_top_level, Def});
list_form(var, _, [S0], _F, A, _E) ->
    case clj2_form:to_data(S0) of
        S when is_atom(S), S =/= nil, S =/= true, S =/= false -> {the_var, A, S};
        _ -> syntax(A, {bad_special_form, var, 1})
    end;
list_form(Special, _, _Args, _F, A, _E) when Special =:= '.'; Special =:= new;
                                             Special =:= 'set!'; Special =:= var;
                                             Special =:= 'deftype*'; Special =:= 'reify*';
                                             Special =:= 'receive*' ->
    unsupported(A, {special_form, Special});
list_form(S, Head, Args, F, A, E) when is_atom(S) ->
    case kernel_form(S) of
        none -> list_form_call(S, Head, Args, F, A, E);
        K -> syntax(A, {not_at_top_level, K})
    end;
list_form(_, Head, Args, _F, A, E) ->
    {invoke, A, form(Head, A, E), [form(X, A, E) || X <- Args]}.

list_form_call(S, Head, Args, F, A, E) ->
    case macroexpand(S, F, A, E) of
        {ok, X} -> form(X, A, E);
        none -> {invoke, A, form(Head, A, E), [form(X, A, E) || X <- Args]}
    end.

%% Offer a call to the driver's macro capability. Locals and keywords
%% are never macros.
macroexpand(S, F, A, E = #{locals := Ls, expand := Expand}) ->
    case Expand =:= none orelse is_map_key(S, Ls) orelse is_keyword(S)
         orelse lists:member(S, specials()) of
        true -> none;
        false ->
            Env = clj2_coll:hash_map_kv(lists:append([[L, nil] || L <- maps:keys(Ls)])),
            case Expand(S, form_data(F, A, E), Env) of
                none -> none;
                {ok, X} -> {ok, X};
                {error, Why} -> erlang:error({clj2_compile, erl_anno:location(A),
                                             {macroexpand, S, Why}})
            end
    end;
macroexpand(_, _, _, _) -> none.

%% A form as the value a macro receives. Clojure's reader has already
%% expanded `#(...)' and syntax-quote by then, so they are expanded
%% here too: `#(...)' to (fn* ...), syntax-quote to the code that builds
%% its result (same rules as squote/3, as forms instead of nodes).
form_data(W, _A, E) when ?CLJ2_IS_LOC(W) -> form_data(?CLJ2_LOC_FORM(W), anno(W), E);
form_data({syntax_quote, [], T}, A, E) -> sq_data(T, A, E, gensym_suffix(A));
form_data({fnstar, [], [{arity, [], [Ps, Body]}]}, A, E) ->
    ['fn*', form_data(Ps, A, E), form_data(Body, A, E)];
form_data({deref, [], X}, A, E) -> ['clojure.core/deref', form_data(X, A, E)];
form_data(L, A, E) when is_list(L) -> [form_data(X, A, E) || X <- L];
form_data({vector, [], Items}, A, E) when is_list(Items) ->
    clj2_coll:vector([form_data(X, A, E) || X <- Items]);
form_data({map, [], Pairs}, A, E) when is_list(Pairs) ->
    clj2_coll:hash_map_kv(lists:append([[form_data(K, A, E), form_data(V, A, E)] || {K, V} <- Pairs]));
form_data({set, [], Items}, A, E) when is_list(Items) ->
    clj2_coll:hash_set([form_data(X, A, E) || X <- Items]);
form_data(X, _A, _E) -> clj2_form:to_data(X).

sq_data(W, _A, E, G) when ?CLJ2_IS_LOC(W) -> sq_data(?CLJ2_LOC_FORM(W), anno(W), E, G);
sq_data({unquote, [], X}, A, E, _G) -> form_data(X, A, E);
sq_data({unquote_splicing, [], _}, A, _E, _G) -> syntax(A, splice_outside_list);
sq_data(S, _A, E, G) when is_atom(S) ->
    case sq_symbol(S, E, G) of
        Q when Q =:= nil; Q =:= true; Q =:= false -> Q;
        Q -> case is_keyword(Q) of
                 true -> Q;
                 false -> [quote, Q]
             end
    end;
sq_data([], _A, _E, _G) -> [quote, []];
sq_data(L, A, E, G) when is_list(L) -> sq_data_seq(L, A, E, G);
sq_data(X, A, E, G) ->
    case {clj2_form:vector_items(X), clj2_form:map_pairs(X), clj2_form:set_items(X)} of
        {Items, _, _} when Items =/= false ->
            [qsym(clj2_coll, vector), sq_data_seq(Items, A, E, G)];
        {_, Pairs, _} when Pairs =/= false ->
            [qsym(clj2_coll, hash_map_kv), sq_data_seq(lists:append([[K, V] || {K, V} <- Pairs]), A, E, G)];
        {_, _, Items} when Items =/= false ->
            [qsym(clj2_coll, hash_set), sq_data_seq(Items, A, E, G)];
        _ -> clj2_form:to_data(X)
    end.

%% (clj2_coll/concat (cons part1 (cons part2 '()))), each part a seqable
sq_data_seq(Items, A, E, G) ->
    Parts = [case unwrap(I) of
                 {unquote_splicing, [], X} -> form_data(X, pos(I, A), E);
                 _ -> [qsym(clj2_coll, cons), sq_data(I, pos(I, A), E, G), [quote, []]]
             end || I <- Items],
    Cons = lists:foldr(fun(P, Acc) -> [qsym(clj2_coll, cons), P, Acc] end, [quote, []], Parts),
    [qsym(clj2_coll, concat), Cons].

%% (do) → nil; (do e) → e; otherwise a do node.
body([], A, _E) -> {const, A, nil};
body([X], A, E) -> form(X, A, E);
body(Xs, A, E) ->
    Nodes = [form(X, A, E) || X <- Xs],
    {Stmts, [Ret]} = lists:split(length(Nodes) - 1, Nodes),
    {do, A, Stmts, Ret}.

%% let*/loop*: sequential, each init sees the previous names
bindings(W, A, E) ->
    BA = pos(W, A),
    case clj2_form:vector_items(unwrap(W)) of
        Items when is_list(Items), length(Items) rem 2 =:= 0 ->
            {Rev, E1} = lists:foldl(
                          fun({S, X}, {Acc, Ex}) ->
                                  SA = pos(S, BA),
                                  Name = binder(S, BA),
                                  {[{bind, SA, Name, form(X, SA, Ex)} | Acc],
                                   add_locals([Name], Ex)}
                          end, {[], E}, pairs_of(Items)),
            {lists:reverse(Rev), E1};
        _ -> syntax(BA, bad_binding_vector)
    end.

pairs_of([]) -> [];
pairs_of([S, X | Rest]) -> [{S, X} | pairs_of(Rest)].

add_locals(Names, E = #{locals := Ls}) ->
    E#{locals := maps:merge(Ls, maps:from_keys(Names, true))}.

binder(W, A) ->
    case unwrap(W) of
        S when is_atom(S), S =/= nil, S =/= true, S =/= false, S =/= '&' ->
            case is_keyword(S) orelse is_qualified(S) of
                true -> syntax(pos(W, A), {bad_binding_name, S});
                false -> S
            end;
        Other -> syntax(pos(W, A), {bad_binding_name, Other})
    end.

%%====================================================================
%% fn*
%%====================================================================

fn([N | Rest], A, E) ->
    case unwrap(N) of
        Name when is_atom(Name), Name =/= nil ->
            Self = binder(N, A),
            fn_clauses(Self, Rest, A, add_locals([Self], E));
        _ -> fn_clauses(nil, [N | Rest], A, E)
    end;
fn([], A, _E) -> syntax(A, fn_without_params).

fn_clauses(Name, [P | Body], A, E) ->
    case clj2_form:vector_items(unwrap(P)) of
        false ->
            Clauses = [case unwrap(C) of
                           [Ps | B] -> clause(Ps, B, pos(C, A), E);
                           _ -> syntax(pos(C, A), bad_fn_clause)
                       end || C <- [P | Body]],
            check_arities({fn, A, Name, Clauses});
        _ ->
            check_arities({fn, A, Name, [clause(P, Body, A, E)]})
    end;
fn_clauses(_Name, [], A, _E) -> syntax(A, fn_without_params).

clause(Ps, Body, A, E) ->
    CA = pos(Ps, A),
    case clj2_form:vector_items(unwrap(Ps)) of
        false -> syntax(CA, bad_fn_params);
        Items ->
            {Fixed, Rest} = params(Items, CA, []),
            Names = Fixed ++ [Rest || Rest =/= nil],
            {clause, CA, Fixed, Rest, body(Body, CA, add_locals(Names, E))}
    end.

params([], _A, Acc) -> {lists:reverse(Acc), nil};
params([P | Ps], A, Acc) ->
    case {unwrap(P), Ps} of
        {'&', [R]} -> {lists:reverse(Acc), binder(R, A)};
        {'&', _} -> syntax(pos(P, A), bad_rest_param);
        _ -> params(Ps, A, [binder(P, A) | Acc])
    end.

%% distinct fixed arities, at most one variadic clause, whose fixed
%% part is not shorter than any fixed arity (Clojure's rule).
check_arities(Fn = {fn, A, _, Clauses}) ->
    Fixed = [length(Ps) || {clause, _, Ps, nil, _} <- Clauses],
    Var = [length(Ps) || {clause, _, Ps, R, _} <- Clauses, R =/= nil],
    lists:usort(Fixed) =:= lists:sort(Fixed) orelse syntax(A, duplicate_fn_arity),
    length(Var) =< 1 orelse syntax(A, more_than_one_variadic_clause),
    case {Var, Fixed} of
        {[V], [_ | _]} -> V >= lists:max(Fixed) orelse
                              syntax(A, fixed_arity_greater_than_variadic);
        _ -> true
    end,
    Fn.

%%====================================================================
%% Protocols (designs/03 §4, clojerl2-016)
%%====================================================================

%% (defprotocol P doc? (m [this] [this a] doc?) ...)
%%   ⇒ (def P {:name ns.P :methods [m ...]})
%%     (def m (fn* m ([this] (clj2_proto/dispatch 'ns.P 'm this ()))
%%                   ([this a] (clj2_proto/dispatch 'ns.P 'm this (a)))))
defprotocol_form([N | Rest0], A, E = #{ns := Ns}) ->
    Name = binder(N, A),
    Proto = dotted(Ns, Name),
    {Doc, Rest} = case Rest0 of
                      [D | R] -> case unwrap(D) of
                                     B when is_binary(B) -> {#{':doc' => B}, R};
                                     _ -> {#{}, Rest0}
                                 end;
                      [] -> {#{}, []}
                  end,
    Sigs = [case unwrap(S) of
                [M | Specs] ->
                    MName = binder(M, pos(S, A)),
                    Params = [P || P <- Specs, clj2_form:vector_items(unwrap(P)) =/= false],
                    Params =/= [] orelse syntax(pos(S, A), {protocol_method_without_params, MName}),
                    {MName, pos(S, A), Params};
                _ -> syntax(pos(S, A), bad_protocol_method)
            end || S <- Rest, not is_binary(unwrap(S)), not is_keyword(unwrap(S))],
    Methods = [{def, MA, MName, #{},
                fn([MName | [dispatch_clause(Proto, MName, P, MA) || P <- Params]], MA, E)}
               || {MName, MA, Params} <- Sigs],
    Info = clj2_coll:hash_map_kv([':name', Proto,
                                  ':methods', clj2_coll:vector([M || {M, _, _} <- Sigs])]),
    [{def, A, Name, Doc, {const, A, Info}} | Methods];
defprotocol_form([], A, _E) -> syntax(A, bad_defprotocol).

dispatch_clause(Proto, MName, ParamsVec, A) ->
    case [unwrap(X) || X <- clj2_form:vector_items(unwrap(ParamsVec))] of
        [This | Args] ->
            lists:member('&', Args) andalso syntax(A, {variadic_protocol_method, MName}),
            [clj2_coll:vector([This | Args]),
             [qsym(clj2_proto, dispatch), [quote, Proto], [quote, MName], This, cons_chain(Args)]];
        [] -> syntax(A, {protocol_method_without_this, MName})
    end.

%% (extend-type T P1 (m [this] ...) (m ([this] ...) ([this a] ...)) P2 ...)
%%   ⇒ one `extend' top per protocol. Fields = none | {deftype | defrecord, Names}
extend_type_form([T | Specs], A, E, Fields) ->
    Type = case unwrap(T) of
               S when is_atom(S) -> S;
               _ -> syntax(A, bad_extend_type)
           end,
    [{extend, A, Type, P, method_tops(Ms, A, E, Fields)} || {P, Ms} <- group_specs(Specs, A)];
extend_type_form([], A, _E, _) -> syntax(A, bad_extend_type).

%% (extend-protocol P T1 (m ...) T2 (m ...))
extend_protocol_form([P | Specs], A, E) ->
    Proto = case unwrap(P) of
                S when is_atom(S) -> S;
                _ -> syntax(A, bad_extend_protocol)
            end,
    lists:append([extend_type_form([T, Proto | Ms], A, E, none)
                  || {T, Ms} <- group_specs(Specs, A)]);
extend_protocol_form([], A, _E) -> syntax(A, bad_extend_protocol).

%% [Sym spec spec Sym spec ...] → [{Sym, [spec, ...]}]
group_specs(Specs, A) ->
    lists:reverse(
      lists:foldl(fun(S, Acc) ->
                          case {unwrap(S), Acc} of
                              {Sym, _} when is_atom(Sym) -> [{Sym, []} | Acc];
                              {L, [{Sym, Ms} | Rest]} when is_list(L) -> [{Sym, Ms ++ [S]} | Rest];
                              _ -> syntax(pos(S, A), bad_extend_spec)
                          end
                  end, [], Specs)).

%% method specs → one `method' top per name, its clauses merged
method_tops(Specs, A, E, Fields) ->
    Grouped = lists:foldl(
                fun(S, Acc) ->
                        SA = pos(S, A),
                        [M | Rest] = unwrap(S),
                        MName = binder(M, SA),
                        Clauses = case Rest of
                                      [P | Body] ->
                                          case clj2_form:vector_items(unwrap(P)) of
                                              false -> [unwrap(C) || C <- Rest];   % (m ([p] b) ...)
                                              _ -> [[P | Body]]                     % (m [p] b)
                                          end;
                                      [] -> syntax(SA, {bad_method, MName})
                                  end,
                        case lists:keyfind(MName, 1, Acc) of
                            {MName, MA, Cs} -> lists:keyreplace(MName, 1, Acc, {MName, MA, Cs ++ Clauses});
                            false -> Acc ++ [{MName, SA, Clauses}]
                        end
                end, [], Specs),
    [{method, MA, MName, fn([with_fields(C, Fields) || C <- Cs], MA, E)}
     || {MName, MA, Cs} <- Grouped].

%% In deftype/defrecord methods the fields are locals: the clause takes
%% `this' as a fresh name and binds the user's name and every field not
%% shadowed by a parameter.
with_fields(Clause, none) -> Clause;
with_fields([Params | Body], {Kind, FieldNames}) ->
    [This | Ps] = [unwrap(X) || X <- clj2_form:vector_items(unwrap(Params))],
    G = 'this__auto__',
    Shadowed = [This | Ps],
    Binds = [[This, G] || This =/= '_'] ++
            [[F, field_access(Kind, G, F, I)]
             || {I, F} <- lists:zip(lists:seq(1, length(FieldNames)), FieldNames),
                not lists:member(F, Shadowed)],
    [clj2_coll:vector([G | Ps]), ['let*', clj2_coll:vector(lists:append(Binds)) | Body]].

field_access(deftype, G, _F, I) -> [qsym(clj2_proto, record_field), G, I];
field_access(defrecord, G, F, _I) ->
    [qsym(clj2_proto, record_field), G, list_to_atom(":" ++ atom_to_list(F))].

%% (deftype T [fields] P (m [this] ...) ...)   value {ns.T, nil, {f1, f2}}
%% (defrecord R [fields] P ...)                value {ns.R, nil, #{:f1 v1 ...}}
%%   ⇒ (def T 'ns.T) (def ->T (fn* [fields] ...)) [(def map->R ...)] + extend-type T ...
deftype_form(Kind, [N, FieldsVec | Specs], A, E = #{ns := Ns}) ->
    Name = binder(N, A),
    Tag = dotted(Ns, Name),
    Fields = case clj2_form:vector_items(unwrap(FieldsVec)) of
                 false -> syntax(A, {bad_fields, Name});
                 Fs -> [binder(F, A) || F <- Fs]
             end,
    Kws = [list_to_atom(":" ++ atom_to_list(F)) || F <- Fields],
    Ctor = list_to_atom("->" ++ atom_to_list(Name)),
    CtorBody = case Kind of
                   deftype ->
                       [qsym(erlang, list_to_tuple),
                        cons_chain([[quote, Tag], nil, [qsym(erlang, list_to_tuple), cons_chain(Fields)]])];
                   defrecord ->
                       [qsym(clj2_proto, record), [quote, Tag], [quote, Kws], cons_chain(Fields)]
               end,
    Defs = [{def, A, Name, #{}, {const, A, Tag}},
            {def, A, Ctor, #{}, fn([Ctor, [clj2_coll:vector(Fields), CtorBody]], A, E)}]
        ++ [{def, A, list_to_atom("map->" ++ atom_to_list(Name)), #{},
             fn([[clj2_coll:vector(['m__auto__']),
                  [qsym(clj2_proto, record), [quote, Tag], [quote, Kws], 'm__auto__']]], A, E)}
            || Kind =:= defrecord],
    Defs ++ case Specs of
                [] -> [];
                _ -> extend_type_form([Name | Specs], A, E, {Kind, Fields})
            end;
deftype_form(Kind, _, A, _E) -> syntax(A, {bad_form, Kind}).

dotted(Ns, Name) -> list_to_atom(atom_to_list(Ns) ++ "." ++ atom_to_list(Name)).

%% data for an Erlang list of the values of Xs: (clj2_coll/cons x1 ... '())
cons_chain(Xs) ->
    lists:foldr(fun(X, Acc) -> [qsym(clj2_coll, cons), X, Acc] end, [quote, []], Xs).

%%====================================================================
%% case*
%%====================================================================

case_form(X, Rest, A, E) ->
    {Pairs, Default} = case length(Rest) rem 2 of
                           0 -> {pairs_of(Rest), nil};
                           1 -> {pairs_of(lists:droplast(Rest)), form(lists:last(Rest), A, E)}
                       end,
    Clauses = [begin
                   TA = pos(T, A),
                   Consts = case unwrap(T) of
                                L when is_list(L), L =/= [] -> [clj2_form:to_data(C) || C <- L];
                                _ -> [clj2_form:to_data(T)]
                            end,
                   {cclause, TA, Consts, form(R, TA, E)}
               end || {T, R} <- Pairs],
    All = lists:append([Cs || {cclause, _, Cs, _} <- Clauses]),
    length(lists:usort(All)) =:= length(All) orelse syntax(A, duplicate_case_test),
    {'case', A, form(X, A, E), Clauses, Default}.

%%====================================================================
%% try
%%====================================================================

try_form(Items, A, E) ->
    {Body, Tail} = lists:splitwith(fun(I) -> not is_clause(I, ['catch', finally]) end, Items),
    {Catches, Fin} = lists:splitwith(fun(I) -> is_clause(I, ['catch']) end, Tail),
    Finally = case Fin of
                  [] -> nil;
                  [F] -> case is_clause(F, [finally]) of
                             true -> [_ | FB] = unwrap(F), body(FB, pos(F, A), E);
                             false -> syntax(A, bad_try_tail)
                         end;
                  _ -> syntax(A, bad_try_tail)
              end,
    {'try', A, body(Body, A, E), [catch_clause(C, A, E) || C <- Catches], Finally}.

is_clause(I, Heads) ->
    case unwrap(I) of
        [H | _] -> lists:member(unwrap(H), Heads);
        _ -> false
    end.

catch_clause(C, A, E) ->
    CA = pos(C, A),
    case unwrap(C) of
        [_Catch, Class, Var | Body] ->
            Name = binder(Var, CA),
            {'catch', CA, catch_class(unwrap(Class), CA), Name,
             body(Body, CA, add_locals([Name], E))};
        _ -> syntax(CA, bad_catch)
    end.

%% Platform classes are the Erlang exception classes. `:default'
%% (ClojureScript's spelling) and the JVM names catch every class.
catch_class(':error', _) -> error;
catch_class(':exit', _) -> exit;
catch_class(':throw', _) -> throw;
catch_class(C, _) when C =:= ':default'; C =:= '_';
                       C =:= 'Exception'; C =:= 'Throwable' -> any;
catch_class(C, A) -> syntax(A, {bad_catch_class, C}).

%%====================================================================
%% Syntax-quote
%%====================================================================

squote(T, A, E) ->
    Gensym = gensym_suffix(A),
    sq(T, A, E, Gensym).

sq(W, _A, E, G) when ?CLJ2_IS_LOC(W) -> sq(?CLJ2_LOC_FORM(W), anno(W), E, G);
sq({unquote, [], X}, A, E, _G) -> form(X, A, E);
sq({unquote_splicing, [], _}, A, _E, _G) -> syntax(A, splice_outside_list);
sq(S, A, E, G) when is_atom(S) -> {const, A, sq_symbol(S, E, G)};
sq([], A, _E, _G) -> {const, A, []};
sq(L, A, E, G) when is_list(L) -> sq_seq(L, A, E, G, fun(N) -> N end);
sq({syntax_quote, [], _}, A, _E, _G) -> unsupported(A, nested_syntax_quote);
sq(X, A, E, G) ->
    case {clj2_form:vector_items(X), clj2_form:map_pairs(X), clj2_form:set_items(X)} of
        {Items, _, _} when Items =/= false ->
            sq_seq(Items, A, E, G, fun(N) -> call(A, clj2_coll, vector, [N]) end);
        {_, Pairs, _} when Pairs =/= false ->
            sq_seq(lists:append([[K, V] || {K, V} <- Pairs]), A, E, G,
                   fun(N) -> call(A, clj2_coll, hash_map_kv, [N]) end);
        {_, _, Items} when Items =/= false ->
            sq_seq(Items, A, E, G, fun(N) -> call(A, clj2_coll, hash_set, [N]) end);
        _ -> {const, A, clj2_form:to_data(X)}
    end.

%% Elements → one list expression; constant parts stay constant.
sq_seq(Items, A, E, G, Wrap) ->
    Parts = [case unwrap(I) of
                 {unquote_splicing, [], X} -> {splice, form(X, pos(I, A), E)};
                 _ -> {one, sq(I, pos(I, A), E, G)}
             end || I <- Items],
    case lists:all(fun({one, {const, _, _}}) -> true; (_) -> false end, Parts) of
        true ->
            List = {const, A, [V || {one, {const, _, V}} <- Parts]},
            case Wrap(List) of
                List -> List;
                Built -> {const, A, eval_const(Built)}
            end;
        false ->
            Args = [case P of
                        {one, N} -> {list, A, [N]};
                        {splice, N} -> N
                    end || P <- Parts],
            Wrap(call(A, clj2_coll, concat, [{list, A, Args}]))
    end.

%% constant collections inside a syntax-quote are built now
eval_const({invoke, _, {sym, _, F}, [{const, _, L}]}) ->
    [M, Fun] = string:split(atom_to_list(F), "/"),
    apply(list_to_atom(M), list_to_atom(Fun), [L]).

sq_symbol(S, E = #{ns := Ns, aliases := Aliases, refers := Refers}, G) ->
    Own = maps:get(own_names, E, #{}),
    Str = atom_to_list(S),
    case is_keyword(S) orelse S =:= nil orelse S =:= true orelse S =:= false
         orelse lists:member(S, specials() -- kernel_forms()) of
        true -> S;
        false ->
            case lists:suffix("#", Str) of
                true -> list_to_atom(lists:droplast(Str) ++ G);
                false ->
                    case string:split(Str, "/") of
                        [[_ | _] = Q, [_ | _] = N] ->
                            QA = list_to_atom(Q),
                            case Aliases of
                                #{QA := Full} -> qsym(Full, list_to_atom(N));
                                _ -> S
                            end;
                        _ when S =:= defmacro; S =:= defprotocol; S =:= deftype;
                               S =:= defrecord; S =:= 'extend-type';
                               S =:= 'extend-protocol' -> qsym('clojure.core', S);
                        _ when is_map_key(S, Own) -> qsym(Ns, S);
                        _ ->
                            qsym(maps:get(S, Refers, Ns), S)
                    end
            end
    end.

gensym_suffix(A) ->
    case erl_anno:location(A) of
        {L, C} -> "__auto__" ++ integer_to_list(L) ++ "_" ++ integer_to_list(C);
        L -> "__auto__" ++ integer_to_list(L)
    end.

call(A, M, F, Args) -> {invoke, A, {sym, A, qsym(M, F)}, Args}.

qsym(Ns, Name) -> list_to_atom(atom_to_list(Ns) ++ "/" ++ atom_to_list(Name)).

%%====================================================================
%% Helpers
%%====================================================================

unwrap(W) when ?CLJ2_IS_LOC(W) -> ?CLJ2_LOC_FORM(W);
unwrap(X) -> X.

anno(W) -> erl_anno:new(?CLJ2_LOC_POS(W)).

pos(W, _A) when ?CLJ2_IS_LOC(W) -> anno(W);
pos(_, A) -> A.

is_keyword(X) -> is_atom(X) andalso X =/= ':' andalso hd(atom_to_list(X)) =:= $:.

is_qualified(S) ->
    case string:split(atom_to_list(S), "/") of
        [[_ | _], [_ | _]] -> true;
        _ -> false
    end.

syntax(A, Why) -> erlang:error({clj2_compile, erl_anno:location(A), {syntax, Why}}).
unsupported(A, What) -> erlang:error({clj2_compile, erl_anno:location(A), {unsupported, What}}).
