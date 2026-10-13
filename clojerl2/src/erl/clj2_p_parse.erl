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

-export([pass/0, run/2, specials/0, data_form/2]).

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

%% ... unless the namespace has its own var of that name (clojure.pprint's
%% deftype, with clojure.core's excluded)
kernel_form(S, E) ->
    case maps:get(own_names, E, #{}) of
        #{S := _} -> none;
        _ -> kernel_form(S)
    end.

%% St may carry: ns, aliases, refers (namespace context for
%% syntax-quote) and expand (the macro capability).
run(Forms, St) when is_list(Forms) ->
    E0 = #{locals => #{},
           expand => maps:get(expand, St, none),
           ns => maps:get(ns, St, user),
           aliases => maps:get(aliases, St, #{}),
           refers => maps:get(refers, St, #{}),
           own_names => maps:get(own_names, St, #{}),
           file_unit => maps:get(file_unit, St, false)},
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
               refers := lists:foldl(fun(R, Acc) -> maps:merge(Acc, clj2_rt_eval:req_refers(R)) end,
                                     #{}, [R || R = #{refer := _} <- Reqs])};
        _ -> E
    end.

%%====================================================================
%% Top level
%%====================================================================

%% A def inside an expression ((let [c (atom 0)] (defn f [] ...)), (when
%% x (def y 1))) is interned when the form compiles, as on the JVM: its
%% unbound declaration is hoisted ahead of the top-level form, and the def
%% itself becomes a run-time assignment of the var's root (nested_def/3).
-define(HOIST_KEY, {?MODULE, hoisted}).

top(F, A0, E) ->
    Saved = get(?HOIST_KEY),
    put(?HOIST_KEY, []),
    try
        Tops = top1(F, A0, E),
        lists:reverse(get(?HOIST_KEY)) ++ Tops
    after
        case Saved of
            undefined -> erase(?HOIST_KEY);
            _ -> put(?HOIST_KEY, Saved)
        end
    end.

top1(F, A0, E) ->
    A = pos(F, A0),
    case unwrap(F) of
        [H | Rest] ->
            case unwrap(H) of
                do -> lists:append([top1(X, A, E) || X <- Rest]);
                def -> def_form(Rest, A, E);
                ns -> [ns_form(Rest, A)];
                S when is_atom(S) ->
                    case kernel_form(S, E) of
                        defmacro -> [defmacro_form(Rest, A, E)];
                        defprotocol -> defprotocol_form(Rest, A, E);
                        'extend-type' -> extend_type_form(Rest, A, E, none);
                        'extend-protocol' -> extend_protocol_form(Rest, A, E);
                        deftype -> deftype_form(deftype, Rest, A, E);
                        defrecord -> deftype_form(defrecord, Rest, A, E);
                        none ->
                            case macroexpand(S, F, A, E) of
                                {ok, X} -> top1(X, A, E);
                                none -> [{eval, A, form(F, A0, E)}]
                            end
                    end;
                _ -> [{eval, A, form(F, A0, E)}]
            end;
        _ -> [{eval, A, form(F, A0, E)}]
    end.

%% (def name) | (def name init) | (def name "doc" init)
def_form([N | Rest], A, E) ->
    def_form(def_name(N, A, E), name_meta(N), Rest, A, E);
def_form([], A, _E) -> syntax(A, bad_def).

def_form(Name, Meta00, Rest, A, E) ->
    Meta0 = maps:map(fun(_, V) -> clj2_form:to_data(V) end, Meta00),
    {Meta, Init} =
        case [unwrap(X) || X <- Rest] of
            [] -> {Meta0, none};
            [_] -> {Meta0, hd(Rest)};
            [Doc, _] when is_binary(Doc) -> {Meta0#{':doc' => Doc}, lists:last(Rest)};
            %% (def name {attr-map} init): what defn expands to
            [M, _] ->
                case clj2_form:map_pairs(M) of
                    false -> syntax(A, bad_def);
                    Pairs -> {maps:merge(Meta0, maps:from_list([{clj2_form:to_data(K), clj2_form:to_data(V)}
                                                                || {K, V} <- Pairs])),
                              lists:last(Rest)}
                end;
            _ -> syntax(A, bad_def)
        end,
    %% constant metadata is the var's from the start; any other value is
    %% an expression, evaluated when the def runs (as on the JVM)
    {Static, Dynamic} = maps:fold(fun(K, V, {S, D}) ->
                                          case meta_const(K, V) of
                                              {ok, C} -> {S#{K => C}, D};
                                              error -> {S, [{K, V} | D]}
                                          end
                                  end, {#{}, []}, Meta),
    Def = {def, A, Name, Static, case Init of none -> nil; _ -> form(Init, A, E) end},
    case Dynamic of
        [] -> [Def];
        _ ->
            Kvs = lists:append([[{const, A, K}, form(V, A, E)] || {K, V} <- lists:sort(Dynamic)]),
            [Def, {eval, A, call(A, clj2_rt, merge_var_meta,
                                 [{the_var, A, Name}, call(A, clj2_coll, hash_map_kv, [{list, A, Kvs}])])}]
    end.

%% (def name init) inside an expression: the var exists from compile time
%% (its declaration is hoisted, unless the namespace has the var already),
%% the root is set when the def runs, and the value is the var.
nested_def([N | Rest], A, E) ->
    Name = binder(N, A),
    [{def, _, Name, Static, Init} | MetaSteps] = def_form(Name, name_meta(N), Rest, A, E),
    %% a var the namespace has already keeps its value until the def runs:
    %% at the REPL it is not declared again; in a namespace file the
    %% declaration meets the earlier def in the same module, which then
    %% keeps its value where this def can set it (clj2_p_declare:hoisted/1)
    Own = case maps:get(file_unit, E, false) of
              true -> #{};
              false -> maps:get(own_names, E, #{})
          end,
    Hoisted = get(?HOIST_KEY),
    case is_map_key(Name, Own) orelse lists:keymember(Name, 3, Hoisted) orelse Hoisted =:= undefined of
        true -> ok;
        false -> put(?HOIST_KEY, [{def, A, Name, Static#{'$hoisted' => true}, nil} | Hoisted])
    end,
    Var = {the_var, A, Name},
    Steps = [call(A, clj2_rt, def_root, [Var, Init]) || Init =/= nil] ++ [X || {eval, _, X} <- MetaSteps],
    case Steps of
        [] -> Var;
        _ -> {do, A, Steps, Var}
    end;
nested_def([], A, _E) -> syntax(A, bad_def).

%% a metadata value that evaluates to itself (a quoted form: its data);
%% a :tag stays the symbol it names
meta_const(':tag', S) when is_atom(S) -> {ok, S};
meta_const(_, V) -> meta_const(V).

meta_const(V) when is_number(V); is_binary(V); V =:= nil; V =:= true; V =:= false -> {ok, V};
meta_const([quote, X]) -> {ok, X};
meta_const(V) when is_atom(V) ->
    case is_keyword(V) of
        true -> {ok, V};
        false -> error
    end;
meta_const({Tag, _, _} = V) when Tag =:= vector; Tag =:= map; Tag =:= set ->
    Items = clj2_coll:to_list(case Tag of map -> clj2_coll:vals(V); _ -> V end),
    Keys = case Tag of map -> clj2_coll:to_list(clj2_coll:keys(V)); _ -> [] end,
    case lists:all(fun(X) -> meta_const(X) =:= {ok, X} end, Items ++ Keys) of
        true -> {ok, V};
        false -> error
    end;
meta_const(_) -> error.

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
    {Lead, Rest2} = case Rest1 of
                        [M | R2] -> case clj2_form:map_pairs(unwrap(M)) of
                                        false -> {#{}, Rest1};
                                        _ when R2 =:= [] -> {#{}, Rest1};
                                        Ps0 -> {attr_meta(Ps0), R2}
                                    end;
                        [] -> {#{}, Rest1}
                    end,
    %% (defmacro m ([a] ...) {:k 1}): a trailing attr-map after the arities
    {Rest3, Trail} = case Rest2 of
                         [] -> {[], #{}};
                         _ ->
                             case {clj2_form:vector_items(unwrap(hd(Rest2))), clj2_form:map_pairs(unwrap(lists:last(Rest2)))} of
                                 {false, Ps1} when Ps1 =/= false -> {lists:droplast(Rest2), attr_meta(Ps1)};
                                 _ -> {Rest2, #{}}
                             end
                     end,
    Clauses = case Rest3 of
                  [] -> [];
                  _ -> case clj2_form:vector_items(unwrap(hd(Rest3))) of
                           false -> Rest3;                       % ([p] b) ...
                           _ -> [Rest3]                          % [p] b ...
                       end
              end,
    WithEnv = [case unwrap(C) of
                   [Ps | Body] ->
                       case clj2_form:vector_items(unwrap(Ps)) of
                           false -> syntax(pos(C, A), bad_defmacro_params);
                           Items -> [clj2_coll:vector(['&form', '&env' | [clj2_form:to_data(I) || I <- Items]]) | Body]
                       end;
                   _ -> syntax(pos(C, A), bad_defmacro)
               end || C <- Clauses],
    %% destructured params: clojure.core/fn takes them apart
    Plain = lists:all(fun(C) -> lists:all(fun(P) -> is_atom(unwrap(P)) end,
                                          clj2_form:vector_items(unwrap(hd(C)))) end, WithEnv),
    Fn = case Plain of
             true -> fn([Name | WithEnv], A, E);
             false -> form(['clojure.core/fn', Name | WithEnv], A, E)
         end,
    Arglists = [clj2_form:to_data(hd(unwrap(C))) || C <- Clauses],
    Meta = lists:foldl(fun(M, Acc) -> maps:merge(Acc, M) end, #{':arglists' => Arglists},
                       [name_meta(N), Meta1, Lead, Trail]),
    {def, A, Name, Meta#{':macro' => true}, Fn};
defmacro_form([], A, _E) -> syntax(A, bad_defmacro).

%% an attr-map's pairs as var metadata (constants: keys and values as data)
attr_meta(Pairs) -> maps:from_list([{clj2_form:to_data(K), clj2_form:to_data(V)} || {K, V} <- Pairs]).

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
                ':refer-clojure' -> [#{refer_clojure => refer_filters(Specs, CA)}];
                %% (:use ns ...) is (:require ns ...) referring all its
                %% public vars, or :only them
                ':use' -> [use_spec(S, CA) || S <- Specs];
                Other -> unsupported(CA, {ns_clause, Other})
            end;
        _ -> syntax(CA, bad_ns_clause)
    end.

%% :exclude [syms] :only [syms] :rename {sym sym}, as refer takes them
refer_filters(Specs, A) -> refer_filters([unwrap(X) || X <- Specs], #{}, A).

refer_filters([], F, _A) -> F;
refer_filters([':exclude', V | Rest], F, A) -> refer_filters(Rest, F#{exclude => syms(V, A)}, A);
refer_filters([':only', V | Rest], F, A) -> refer_filters(Rest, F#{only => syms(V, A)}, A);
refer_filters([':rename', M | Rest], F, A) ->
    case clj2_form:map_pairs(M) of
        false -> syntax(A, bad_refer_rename);
        Pairs -> refer_filters(Rest, F#{rename => maps:from_list([{unwrap(K), unwrap(V)} || {K, V} <- Pairs])}, A)
    end;
refer_filters(Other, _F, A) -> unsupported(A, {refer_filters, Other}).

syms(V, A) ->
    case clj2_form:vector_items(V) of
        false ->
            case unwrap(V) of
                L when is_list(L) -> [unwrap(X) || X <- L];
                _ -> syntax(A, bad_refer_list)
            end;
        Items -> [unwrap(X) || X <- Items]
    end.

use_spec(S, A) ->
    SA = pos(S, A),
    case unwrap(S) of
        Ns when is_atom(Ns) -> #{ns => Ns, as => nil, refer => all, rename => #{}, exclude => []};
        V ->
            case clj2_form:vector_items(V) of
                [N | Opts] ->
                    F = refer_filters(Opts, SA),
                    Ns = unwrap(N),
                    is_atom(Ns) orelse syntax(SA, bad_use),
                    #{ns => Ns, as => nil, refer => maps:get(only, F, all),
                      rename => maps:get(rename, F, #{}), exclude => maps:get(exclude, F, [])};
                _ -> syntax(SA, bad_use)
            end
    end.

require_spec(S, A) ->
    SA = pos(S, A),
    case unwrap(S) of
        Ns when is_atom(Ns) -> #{ns => Ns, as => nil, refer => [], rename => #{}};
        V ->
            case clj2_form:vector_items(V) of
                [N | Opts] ->
                    Ns = unwrap(N),
                    is_atom(Ns) orelse syntax(SA, bad_require),
                    require_opts([unwrap(O) || O <- Opts], #{ns => Ns, as => nil, refer => [], rename => #{}}, SA);
                _ -> syntax(SA, bad_require)
            end
    end.

require_opts([], R, _A) -> R;
require_opts([':as', Alias | Rest], R, A) when is_atom(Alias) ->
    require_opts(Rest, R#{as := Alias}, A);
%% :refer :all: the namespace's public vars, known once it is loaded
require_opts([':refer', ':all' | Rest], R, A) ->
    require_opts(Rest, R#{refer := all}, A);
require_opts([':rename', M | Rest], R, A) ->
    case clj2_form:map_pairs(M) of
        false -> syntax(A, bad_require_rename);
        Pairs -> require_opts(Rest, R#{rename := maps:from_list([{unwrap(K), unwrap(V)} || {K, V} <- Pairs])}, A)
    end;
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

%% ^{...} on a vector, map or set literal: the value carries it (the
%% metadata map is evaluated, as in Clojure)
form({clj2_loc, _, _, Inner, Meta} = W, _Anno, E) when is_map(Meta), map_size(Meta) > 0,
                                                     is_tuple(Inner),
                                                     (element(1, Inner) =:= vector orelse
                                                      element(1, Inner) =:= map orelse
                                                      element(1, Inner) =:= set) ->
    A = anno(W),
    MetaForm = {map, [], [{K, V} || {K, V} <- lists:sort(maps:to_list(Meta))]},
    {invoke, A, {sym, A, 'clj2_rt/with_meta'}, [form(Inner, A, E), form(MetaForm, A, E)]};
form(W, _Anno, E) when ?CLJ2_IS_LOC(W) ->
    form(?CLJ2_LOC_FORM(W), anno(W), E);
form(X, A, _E) when is_integer(X); is_float(X); is_binary(X) -> {const, A, X};
%% a fn value in code (a macro spliced one in): a fun is no BEAM literal,
%% so it is kept in this node's table and fetched when the code runs
%% (the JVM cannot embed one in AOT-compiled code either)
form(F, A, E) when is_function(F); is_tuple(F), (element(1, F) =:= clj2_fn orelse element(1, F) =:= fnmeta) ->
    Key = erlang:phash2(F),
    persistent_term:put({clj2_fn_const, Key}, F),
    form(['clj2_rt/fn_const', Key], A, E);
form(X, A, _E) when X =:= nil; X =:= true; X =:= false -> {const, A, X};
form(X, A, E) when is_atom(X) ->
    case is_keyword(X) of
        true -> {const, A, kw(X, E)};
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
form({tagged, [], inst, S}, A, _E) when is_binary(S) -> {const, A, clj2_inst:parse(S)};
form({tagged, [], uuid, S}, A, _E) when is_binary(S) ->
    try {const, A, clj2_string:uuid(S)}
    catch error:_ -> syntax(A, {bad_uuid, S})
    end;
%% ##Inf / ##-Inf / ##NaN: BEAM floats have neither (known divergence
%% :number/beam-semantics); the literal raises when evaluated, so the
%% rest of a file that mentions one still compiles
form({tagged, [], T, nil}, A, E) when T =:= 'NaN'; T =:= 'Inf'; T =:= '-Inf' ->
    form(['clj2_rt/unsupported_float', list_to_atom(":" ++ atom_to_list(T))], A, E);
%% 1.5M: a BigDecimal constant (clj2_decimal)
form({bigdec, [], B}, A, _E) when is_binary(B) ->
    {const, A, clj2_decimal:parse(B)};
form({decimal, U, S} = D, A, _E) when is_integer(U), is_integer(S) -> {const, A, D};   % from a macro
%% #=(...): evaluated now, as the JVM reader does
form({read_eval, [], F}, A, _E) -> {const, A, clj2_form:to_data({read_eval, [], F})};
%% any other tagged literal: a record literal (#ns.Rec{..}, data: its
%% values are not evaluated) is a constant; a *data-readers* fn's result
%% is code; no reader function for the tag raises when evaluated (the
%% JVM reader rejects the file)
form({tagged, [], Tag, _} = T, A, E) when is_atom(Tag) ->
    case clj2_form:record_tag(Tag) of
        {ok, _, _} -> {const, A, clj2_form:to_data(T)};
        none ->
            case clj2_form:to_data(T) of
                %% ns.Rec not defined yet (a defrecord in the same
                %% top-level form): the record is made when this runs
                {tagged, [], Tag, _} = D when is_tuple(D) ->
                    case binary:match(atom_to_binary(Tag), <<".">>) of
                        nomatch -> form(['clj2_rt/unsupported_tag', [quote, Tag]], A, E);
                        _ -> form(['clj2_form/resolve_tags', [quote, T]], A, E)
                    end;
                V -> form(clj2_form:from_value(V), A, E)
            end
    end;
form({Unq, [], _}, A, _E) when Unq =:= unquote; Unq =:= unquote_splicing ->
    syntax(A, unquote_outside_syntax_quote);
form(X, A, E) ->
    case {clj2_form:vector_items(X), clj2_form:map_pairs(X), clj2_form:set_items(X)} of
        {Items, _, _} when Items =/= false -> coll(vector, Items, X, A, E);
        {_, Pairs, _} when Pairs =/= false ->
            coll(hash_map_kv, lists:append([[K, V] || {K, V} <- Pairs]), X, A, E);
        {_, _, Items} when Items =/= false -> coll(hash_set, Items, X, A, E);
        %% a record value (a record literal that a macro got as data)
        _ when tuple_size(X) =:= 3, is_atom(element(1, X)), is_map(element(3, X)) -> {const, A, X};
        _ -> unsupported(A, {literal, element(1, X)})
    end.

dup([]) -> none;
dup([X | Xs]) ->
    case lists:any(fun(Y) -> clj2_coll:equals(X, Y) end, Xs) of
        true -> {dup, X};
        false -> dup(Xs)
    end.

%% A collection literal: a constant when every element is one, else
%% built at run time (clj2_coll).
coll(Ctor, Items, _X, A, E) ->
    Nodes = [form(I, A, E) || I <- Items],
    %% a set element or map key written twice is an error, as the JVM
    %% reader has it (Duplicate key: k)
    Keys = case Ctor of
               hash_set -> Nodes;
               hash_map_kv -> [K || {K, _} <- pairs_of(Nodes)];
               vector -> []
           end,
    Consts = [V || {const, _, V} <- Keys],
    case dup(Consts) of
        none -> ok;
        {dup, D} -> syntax(A, {duplicate_key, clj2_print:pr_str(D)})
    end,
    case lists:all(fun({const, _, _}) -> true; (_) -> false end, Nodes) of
        %% built from the elements' values: `{:a '(1)}' holds the list (1)
        true -> {const, A, clj2_coll:Ctor([V || {const, _, V} <- Nodes])};
        false -> {invoke, A, {sym, A, qsym(clj2_coll, Ctor)}, [{list, A, Nodes}]}
    end.

list_form(quote, _, [D], _F, A, E) ->
    case kws(quoted_data(D, A, E), E) of
        %% a list with metadata is a lazy seq holding it: no literal, so it
        %% is rebuilt when the code runs
        {lazy_seq, M, _} = L when M =/= nil ->
            call(A, clj2_rt, with_meta, [{const, A, clj2_coll:to_list(L)}, {const, A, M}]);
        V -> {const, A, V}
    end;
list_form('if', _, [C, T], _F, A, E) -> {'if', A, form(C, A, E), form(T, A, E), {const, A, nil}};
list_form('if', _, [C, T, El], _F, A, E) -> {'if', A, form(C, A, E), form(T, A, E), form(El, A, E)};
list_form('do', _, Body, _F, A, E) -> body(Body, A, E);
list_form('let*', _, [Bs | Body], _F, A, E) ->
    {Binds, E1} = bindings(Bs, A, E),
    {'let', A, Binds, body(Body, A, E1)};
list_form('loop*', _, [Bs | Body], _F, A, E) ->
    {Binds, E1} = bindings(Bs, A, E),
    case Binds of
        [_, _ | _] ->
            %% the inits run in order, each seeing the names before it (as
            %% let*): bound by a let*, then the loop rebinds the names
            {'let', A, Binds, {loop, A, [{bind, BA, S, {sym, BA, S}} || {bind, BA, S, _} <- Binds],
                               body(Body, A, E1)}};
        _ -> {loop, A, Binds, body(Body, A, E1)}
    end;
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
list_form(def, _, Args, _F, A, E) -> nested_def(Args, A, E);
list_form(ns, _, _Args, _F, A, _E) ->
    syntax(A, {not_at_top_level, ns});
list_form(var, _, [S0], _F, A, _E) ->
    case clj2_form:to_data(S0) of
        S when is_atom(S), S =/= nil, S =/= true, S =/= false -> {the_var, A, S};
        _ -> syntax(A, {bad_special_form, var, 1})
    end;
%% (set! v x) of a var: its binding in this process (var-set)
list_form('set!', _, [S0, X], _F, A, E = #{locals := Ls}) ->
    case clj2_form:to_data(S0) of
        S when is_atom(S), S =/= nil, S =/= true, S =/= false, not is_map_key(S, Ls) ->
            call(A, clj2_var, var_set, [{the_var, A, S}, form(X, A, E)]);
        _ -> unsupported(A, {special_form, 'set!'})
    end;
list_form('.', _, [Target, Member | Rest], _F, A, E) -> dot(Target, Member, Rest, A, E);
list_form('..', _, [X, M | Ms], _F, A, E) ->
    form(lists:foldl(fun(Mi, Acc) -> ['.', Acc, Mi] end, ['.', X, M], Ms), A, E);
list_form(new, _, [C | Args], _F, A, E) ->
    case unwrap(C) of
        S when is_atom(S) -> {invoke, A, {sym, A, list_to_atom(atom_to_list(S) ++ ".")}, [form(X, A, E) || X <- Args]};
        _ -> syntax(A, {bad_special_form, new, length(Args) + 1})
    end;
list_form(Special, _, _Args, _F, A, _E) when Special =:= '.'; Special =:= new;
                                             Special =:= 'set!'; Special =:= var;
                                             Special =:= 'deftype*'; Special =:= 'reify*';
                                             Special =:= 'receive*' ->
    unsupported(A, {special_form, Special});
list_form(S, Head, Args, F, A, E) when is_atom(S) ->
    list_form_atom(S, Head, Args, F, A, E);
list_form(_, Head, Args, _F, A, E) ->
    {invoke, A, form(Head, A, E), [form(X, A, E) || X <- Args]}.

%% (.method obj args) / (.-field obj): member access on obj
list_form_atom(S, Head, [Obj | Args] = All, F, A, E = #{locals := Ls}) when not is_map_key(S, Ls) ->
    case atom_to_list(S) of
        "." ++ [C | _] = Name when C =/= $. -> dot(Obj, list_to_atom(tl(Name)), Args, A, E);
        _ -> list_form_plain(S, Head, All, F, A, E)
    end;
list_form_atom(S, Head, Args, F, A, E) -> list_form_plain(S, Head, Args, F, A, E).

list_form_plain(S, Head, Args, F, A, E) ->
    case kernel_form(S, E) of
        none -> list_form_call(S, Head, Args, F, A, E);
        K -> syntax(A, {not_at_top_level, K})
    end.

%% (. Target member args) / (. Target (member args)): a static member
%% when Target names a JVM class (and is not a local), else an instance
%% one. A member -name is a field. All go through clj2_jvm.
dot(Target, Member0, Rest, A, E = #{locals := Ls}) ->
    {Member, Args} = case unwrap(Member0) of
                         [M | MArgs] when Rest =:= [] -> {unwrap(M), MArgs};
                         M -> {M, Rest}
                     end,
    is_atom(Member) orelse syntax(A, {bad_special_form, '.', length(Rest) + 2}),
    {Field, Name} = case atom_to_list(Member) of
                        "-" ++ [_ | _] = N -> {true, list_to_atom(tl(N))};
                        N -> {false, list_to_atom(N)}
                    end,
    Class = case unwrap(Target) of
                T when is_atom(T), not is_map_key(T, Ls) ->
                    case clj2_class:resolve(T) of
                        {ok, C} -> C;
                        error -> none
                    end;
                _ -> none
            end,
    Args1 = [form(X, A, E) || X <- Args],
    case {Class, Field} of
        {none, true} -> call(A, clj2_jvm, instance_field, [form(Target, A, E), {const, A, Name}]);
        {none, false} -> call(A, clj2_jvm, method, [form(Target, A, E), {const, A, Name}, {list, A, Args1}]);
        {_, true} -> call(A, clj2_jvm, field, [{const, A, Class}, {const, A, Name}]);
        _ -> call(A, clj2_jvm, static, [{const, A, Class}, {const, A, Name}, {list, A, Args1}])
    end.

list_form_call(S, Head, Args, F, A, E) ->
    case macroexpand(S, F, A, E) of
        {ok, X} -> form(X, A, E);
        none -> {invoke, A, form(Head, A, E), [form(X, A, E) || X <- Args]}
    end.

%% Offer a call to the driver's macro capability. Locals and keywords
%% are never macros.
macroexpand(S, F, A, E = #{locals := Ls, expand := Expand}) ->
    %% a kernel form's name is a macro when the namespace defines its own
    case Expand =:= none orelse is_map_key(S, Ls) orelse is_keyword(S)
         orelse (lists:member(S, specials()) andalso kernel_form(S, E) =/= none)
         orelse lists:member(S, specials() -- kernel_forms()) of
        true -> none;
        false ->
            Env = clj2_coll:hash_map_kv(lists:append([[L, nil] || L <- maps:keys(Ls)])),
            case Expand(S, form_data(F, A, E), Env) of
                none -> none;
                {ok, X} -> {ok, carry_name_meta(F, X)};
                {error, {not_public, _} = NP} ->
                    erlang:error({clj2_compile, erl_anno:location(A), {resolve, NP}});
                {error, Why} -> erlang:error({clj2_compile, erl_anno:location(A),
                                             {macroexpand, S, Why}})
            end
    end;
macroexpand(_, _, _, _) -> none.

%% Metadata the reader put on a defining macro's name ((defn ^:private f
%% ...), (defmulti ^:dynamic m ...)) does not survive the macro, since a
%% symbol value carries none (:symbol/no-metadata): it is put back on the
%% same name in the expansion -- (def f ...), or the next macro call.
carry_name_meta(F, X) ->
    case unwrap(F) of
        [_, {clj2_loc, L, C, Sym, M} | _] when is_atom(Sym), is_map(M), map_size(M) > 0 ->
            case X of
                [H, Sym | Rest] when is_atom(H) -> [H, {clj2_loc, L, C, Sym, M} | Rest];
                %% a def of the name deeper in the expansion ((defonce ^:private x ..)
                %% is (when-not (bound? #'x) (def x ..)))
                _ -> element(1, carry_into_def(X, Sym, {clj2_loc, L, C, Sym, M}))
            end;
        _ -> X
    end.

carry_into_def([def, Sym | Rest], Sym, W) -> {[def, W | Rest], true};
carry_into_def(L, Sym, W) when is_list(L) ->
    lists:mapfoldl(fun(X, true) -> {X, true};
                      (X, false) -> carry_into_def(X, Sym, W)
                   end, false, L);
carry_into_def(X, _, _) -> {X, false}.

%% A form as the value a macro receives. Clojure's reader has already
%% expanded `#(...)' and syntax-quote by then, so they are expanded
%% here too: `#(...)' to (fn* ...), syntax-quote to the code that builds
%% its result (same rules as squote/3, as forms instead of nodes).
%% @doc A reader form as the data (read) returns in namespace `Ns': as
%% the JVM reader does, syntax-quote is expanded there (`x is (quote
%% ns/x)), against the namespace's aliases and refers, and #() is a fn*.
data_form(F, Ns) ->
    {Aliases, Own} = case clj2_ns:info(Ns) of
                         {ok, I = #{vars := Vars}} -> {maps:get(aliases, I, #{}), maps:map(fun(_, _) -> true end, Vars)};
                         error -> {#{}, #{}}
                     end,
    E = #{ns => Ns, aliases => Aliases, refers => clj2_ns:refers(Ns), own_names => Own,
          locals => #{}, expand => none},
    form_data(F, erl_anno:new({1, 1}), E).

%% a collection's reader metadata (^:k [..]) stays on the value, as it does
%% on the JVM (clj2_form:to_data keeps it the same way)
form_data({clj2_loc, _, _, Inner, Meta} = W, _A, E)
  when is_map(Meta), map_size(Meta) > 0,
       (is_list(Inner) orelse is_tuple(Inner) andalso
        (element(1, Inner) =:= vector orelse element(1, Inner) =:= map orelse element(1, Inner) =:= set)) ->
    clj2_rt:with_meta(form_data(Inner, anno(W), E),
                      clj2_coll:hash_map_kv(lists:append([[K, form_data(V, anno(W), E)] || {K, V} <- maps:to_list(Meta)])));
form_data(W, _A, E) when ?CLJ2_IS_LOC(W) -> form_data(?CLJ2_LOC_FORM(W), anno(W), E);
form_data({syntax_quote, [], T}, A, E) -> sq_data(T, A, E, gensym_suffix(A));
form_data({fnstar, [], [{arity, [], [Ps, Body]}]}, A, E) ->
    ['fn*', form_data(Ps, A, E), form_data(Body, A, E)];
form_data({deref, [], X}, A, E) -> ['clojure.core/deref', form_data(X, A, E)];
form_data({unquote, [], X}, A, E) -> ['clojure.core/unquote', form_data(X, A, E)];
form_data({unquote_splicing, [], X}, A, E) -> ['clojure.core/unquote-splicing', form_data(X, A, E)];
form_data(L, A, E) when is_list(L) -> [form_data(X, A, E) || X <- L];
form_data({vector, [], Items}, A, E) when is_list(Items) ->
    clj2_coll:vector([form_data(X, A, E) || X <- Items]);
form_data({map, [], Pairs}, A, E) when is_list(Pairs) ->
    clj2_coll:hash_map_kv(lists:append([[form_data(K, A, E), form_data(V, A, E)] || {K, V} <- Pairs]));
form_data({set, [], Items}, A, E) when is_list(Items) ->
    clj2_coll:hash_set([form_data(X, A, E) || X <- Items]);
form_data({tagged, [], Tag, F}, A, E) when Tag =/= inst, Tag =/= uuid, F =/= nil ->
    clj2_form:tag_value(Tag, form_data(F, A, E));
form_data({read_eval, [], F}, A, E) -> clj2_form:to_data({read_eval, [], form_data(F, A, E)});
form_data(X, _A, _E) -> clj2_form:to_data(X).

%% a quoted form as data: a syntax-quote or unquote inside it reads as the
%% JVM reader makes it; anything else as clj2_form:to_data does
quoted_data(D, A, E) ->
    case has_quote_forms(D) of
        true -> form_data(D, A, E);
        false -> clj2_form:to_data(D)
    end.

has_quote_forms({Tag, [], _}) when Tag =:= syntax_quote; Tag =:= unquote; Tag =:= unquote_splicing -> true;
has_quote_forms(W) when ?CLJ2_IS_LOC(W) -> has_quote_forms(?CLJ2_LOC_FORM(W));
has_quote_forms(L) when is_list(L) -> lists:any(fun has_quote_forms/1, L);
has_quote_forms({Tag, [], Items}) when (Tag =:= vector orelse Tag =:= set), is_list(Items) ->
    lists:any(fun has_quote_forms/1, Items);
has_quote_forms({map, [], Pairs}) when is_list(Pairs) ->
    lists:any(fun({K, V}) -> has_quote_forms(K) orelse has_quote_forms(V) end, Pairs);
has_quote_forms(_) -> false.

%% A syntax-quote as data: the construction code the JVM reader makes of
%% it ((clojure.core/seq (clojure.core/concat (clojure.core/list ..) ..)),
%% (clojure.core/apply clojure.core/vector ..) ...): what read-string,
%% quote and a nested syntax-quote see. Literals stand for themselves.
sq_data(W, _A, E, G) when ?CLJ2_IS_LOC(W) -> sq_data(?CLJ2_LOC_FORM(W), anno(W), E, G);
sq_data({unquote, [], X}, A, E, _G) -> form_data(X, A, E);
sq_data(['clojure.core/unquote', X], A, E, _G) -> form_data(X, A, E);
%% ``x: the inner expansion, quoted again
sq_data({syntax_quote, [], T}, A, E, G) -> sq_data(sq_data(T, A, E, gensym_suffix(A) ++ "i"), A, E, G);
sq_data({fnstar, [], _} = F, A, E, G) -> sq_data(form_data(F, A, E), A, E, G);
%% #'x and @x are the lists (var x) and (clojure.core/deref x) to a syntax-quote
sq_data({var, [], X}, A, E, G) -> sq_data([var, X], A, E, G);
sq_data({deref, [], X}, A, E, G) -> sq_data(['clojure.core/deref', X], A, E, G);
sq_data({unquote_splicing, [], _}, A, _E, _G) -> syntax(A, splice_outside_list);
sq_data(S, _A, E, G) when is_atom(S) ->
    case sq_symbol(S, E, G) of
        %% only keywords, numbers, characters and strings stand for
        %% themselves; nil and booleans are quoted, as on the JVM
        Q when Q =:= nil; Q =:= true; Q =:= false -> [quote, Q];
        Q -> case is_keyword(Q) of
                 true -> Q;
                 false -> [quote, Q]
             end
    end;
sq_data([], _A, _E, _G) -> ['clojure.core/list'];
sq_data(L, A, E, G) when is_list(L) -> ['clojure.core/seq', sq_data_seq(L, A, E, G)];
sq_data(X, A, E, G) ->
    Apply = fun(F, Items) -> ['clojure.core/apply', F, ['clojure.core/seq', sq_data_seq(Items, A, E, G)]] end,
    case {clj2_form:vector_items(X), clj2_form:map_pairs(X), clj2_form:set_items(X)} of
        {Items, _, _} when Items =/= false -> Apply('clojure.core/vector', Items);
        {_, Pairs, _} when Pairs =/= false ->
            Apply('clojure.core/hash-map', lists:append([[K, V] || {K, V} <- Pairs]));
        {_, _, Items} when Items =/= false -> Apply('clojure.core/hash-set', Items);
        _ -> clj2_form:to_data(X)
    end.

%% (clj2_coll/concat (cons part1 (cons part2 '()))), each part a seqable
sq_data_seq(Items, A, E, G) ->
    ['clojure.core/concat' | [case unwrap(I) of
                                  {unquote_splicing, [], X} -> form_data(X, pos(I, A), E);
                                  ['clojure.core/unquote-splicing', X] -> form_data(X, pos(I, A), E);
                                  _ -> ['clojure.core/list', sq_data(I, pos(I, A), E, G)]
                              end || I <- Items]].

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

%% a def's name: ns/name is the name when ns is this namespace (a
%% syntax-quoted def in a macro), as on the JVM
def_name(W, A, E = #{ns := Ns}) ->
    case unwrap(W) of
        S when is_atom(S) ->
            case is_qualified(S) andalso string:split(atom_to_list(S), "/") of
                [Q, N] when N =/= "" ->
                    case list_to_atom(Q) =:= Ns orelse maps:get(list_to_atom(Q), maps:get(aliases, E, #{}), none) =:= Ns of
                        true -> list_to_atom(N);
                        false -> syntax(pos(W, A), {def_outside_namespace, S})
                    end;
                _ -> binder(W, A)
            end;
        _ -> binder(W, A)
    end.

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
                    MDoc = case [unwrap(D0) || D0 <- Specs, is_binary(unwrap(D0))] of
                               [D1 | _] -> D1;
                               [] -> nil
                           end,
                    {MName, pos(S, A), Params, MDoc};
                _ -> syntax(pos(S, A), bad_protocol_method)
            end || S <- drop_options(Rest), not is_binary(unwrap(S))],
    %% a method var's meta names its protocol's var, as on the JVM
    Methods = [{def, MA, MName,
                maps:merge(#{':protocol' => {var, nil, {Ns, Name}},
                             ':arglists' => [clj2_form:to_data(P) || P <- Params]},
                           case MDoc of nil -> #{}; _ -> #{':doc' => MDoc} end),
                fn([MName | [dispatch_clause(Proto, MName, P, MA) || P <- Params]], MA, E)}
               || {MName, MA, Params, MDoc} <- Sigs],
    %% :sigs as on the JVM: {:msig {:name msig :arglists ([this] ...) :doc .. :tag nil}}
    SigMap = clj2_coll:hash_map_kv(
               lists:append([[clj2_rt:keyword(atom_to_binary(M)),
                              clj2_coll:hash_map_kv([':name', M, ':tag', nil, ':doc', MDoc,
                                                     ':arglists', [clj2_form:to_data(P) || P <- Ps]])]
                             || {M, _, Ps, MDoc} <- Sigs])),
    Info = clj2_coll:hash_map_kv([':name', Proto,
                                  ':var', {var, nil, {Ns, Name}},
                                  ':sigs', SigMap,
                                  ':methods', clj2_coll:vector([M || {M, _, _, _} <- Sigs])]),
    [{def, A, Name, Doc, {const, A, Info}} | Methods];
defprotocol_form([], A, _E) -> syntax(A, bad_defprotocol).

%% (defprotocol P "doc" :extend-via-metadata true (m [x]) ...): the
%% option pairs are not methods
drop_options([X | Rest]) ->
    case {is_keyword(unwrap(X)), Rest} of
        {true, [_ | Rest1]} -> drop_options(Rest1);
        {true, []} -> [];
        {false, _} -> [X | drop_options(Rest)]
    end;
drop_options([]) -> [].

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
    %% an inline impl (deftype/defrecord's own) is marked generated: it is
    %% not an extension that (extenders P) lists
    A1 = case Fields of none -> A; _ -> erl_anno:set_generated(true, A) end,
    [{extend, A1, Type, P, method_tops(Ms, A, E, Fields)} || {P, Ms} <- group_specs(Specs, A)];
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
    [{method, MA, MName, fn([with_fields(destructured_params(C), Fields) || C <- Cs], MA, E)}
     || {MName, MA, Cs} <- Grouped].

%% a method param that is a pattern ([k v], {:keys [a]}) becomes a fresh
%% name, taken apart by clojure.core/let inside the body
destructured_params([Params | Body]) ->
    Items = clj2_form:vector_items(unwrap(Params)),
    {Ps, Binds, _} = lists:foldl(
                       fun(P, {Acc, Bs, I}) ->
                               case unwrap(P) of
                                   S when is_atom(S) -> {[S | Acc], Bs, I};
                                   _ ->
                                       G = list_to_atom("p__" ++ integer_to_list(I) ++ "__auto__"),
                                       {[G | Acc], Bs ++ [clj2_form:to_data(P), G], I + 1}
                               end
                       end, {[], [], 1}, Items),
    case Binds of
        [] -> [Params | Body];
        _ -> [clj2_coll:vector(lists:reverse(Ps)), ['clojure.core/let', clj2_coll:vector(Binds) | Body]]
    end.

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
    %% leading option pairs (:no-print true :load-ns false) are not specs
    Specs1 = drop_options(Specs),
    Defs ++ case Specs1 of
                [] -> [];
                _ -> extend_type_form([Name | Specs1], A, E, {Kind, Fields})
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

%% The Erlang exception classes :error :exit :throw; :default
%% (ClojureScript's spelling), Exception and Throwable catch everything;
%% any other class the JVM class model knows catches errors of that class
%% or a subclass (clj2_class:exception_matches/2): (catch
%% ArithmeticException e ...) catches badarith.
catch_class(':error', _) -> error;
catch_class(':exit', _) -> exit;
catch_class(':throw', _) -> throw;
catch_class(C, _) when C =:= ':default'; C =:= '_' -> any;
%% everything, bound as a throwable (an Erlang error given its JVM class)
catch_class(C, _) when C =:= 'Exception'; C =:= 'Throwable';
                       C =:= 'java.lang.Exception'; C =:= 'java.lang.Throwable' -> throwable;
catch_class(C, A) when is_atom(C) ->
    case clj2_class:resolve(C) of
        {ok, Class} -> Class;
        error -> syntax(A, {bad_catch_class, C})
    end;
catch_class(C, A) -> syntax(A, {bad_catch_class, C}).

%%====================================================================
%% Syntax-quote
%%====================================================================

squote(T, A, E) ->
    Gensym = gensym_suffix(A),
    sq(T, A, E, Gensym).

sq(W, _A, E, G) when ?CLJ2_IS_LOC(W) -> sq(?CLJ2_LOC_FORM(W), anno(W), E, G);
sq({unquote, [], X}, A, E, _G) -> form(X, A, E);
%% (clojure.core/unquote x) as data is an unquote too (a nested
%% syntax-quote's construction code carries ~'~x so)
sq(['clojure.core/unquote', X], A, E, _G) -> form(X, A, E);
sq({unquote_splicing, [], _}, A, _E, _G) -> syntax(A, splice_outside_list);
sq(S, A, E, G) when is_atom(S) -> {const, A, sq_symbol(S, E, G)};
sq([], A, _E, _G) -> {const, A, []};
sq(L, A, E, G) when is_list(L) -> sq_seq(L, A, E, G, list);
%% a syntax-quote inside one: its construction code, syntax-quoted
sq({syntax_quote, [], T}, A, E, G) -> sq(sq_data(T, A, E, G ++ "i"), A, E, G);
sq({fnstar, [], _} = F, A, E, G) -> sq(form_data(F, A, E), A, E, G);
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
                 ['clojure.core/unquote-splicing', X] -> {splice, form(X, pos(I, A), E)};
                 _ -> {one, sq(I, pos(I, A), E, G)}
             end || I <- Items],
    case lists:all(fun({one, {const, _, _}}) -> true; (_) -> false end, Parts) of
        true ->
            List = {const, A, [V || {one, {const, _, V}} <- Parts]},
            case Wrap of
                list -> List;
                _ -> {const, A, eval_const(Wrap(List))}
            end;
        false ->
            Args = [case P of
                        {one, N} -> {list, A, [N]};
                        {splice, N} -> N
                    end || P <- Parts],
            case Wrap of
                %% (seq (concat ...)) as on the JVM: a spliced seq is
                %% realized only when the walk reaches it
                list -> call(A, clj2_coll, sq_concat, [{list, A, Args}]);
                _ -> Wrap(call(A, clj2_coll, concat, [{list, A, Args}]))
            end
    end.

%% constant collections inside a syntax-quote are built now
eval_const({invoke, _, {sym, _, F}, [{const, _, L}]}) ->
    [M, Fun] = string:split(atom_to_list(F), "/"),
    apply(list_to_atom(M), list_to_atom(Fun), [L]).

sq_symbol(S, E = #{ns := Ns, aliases := Aliases, refers := Refers}, G) ->
    Own = maps:get(own_names, E, #{}),
    Str = atom_to_list(S),
    case is_keyword(S) of
        true -> kw(S, E);
        false -> sq_symbol1(S, Str, Own, E, Ns, Aliases, Refers, G)
    end.

sq_symbol1(S, Str, Own, _E, Ns, Aliases, Refers, G) ->
    case S =:= nil orelse S =:= true orelse S =:= false
         orelse lists:member(S, specials() -- kernel_forms()) of
        true -> S;
        false ->
            case lists:suffix("#", Str) orelse hd(Str) =:= $% of
                %% x# and #()'s %, %1, %& (the JVM reads those as gensyms too)
                true when hd(Str) =:= $% -> list_to_atom(Str ++ G);
                true -> list_to_atom(lists:droplast(Str) ++ G);
                false ->
                    case string:split(Str, "/") of
                        [[_ | _] = Q, [_ | _] = N] ->
                            QA = list_to_atom(Q),
                            case Aliases of
                                #{QA := Full} -> qsym(Full, list_to_atom(N));
                                _ -> S
                            end;
                        %% host member access, constructors and classes stay
                        %% as written (.method, Name., .., String)
                        ["." ++ _] -> S;
                        _ when not is_map_key(S, Own), not is_map_key(S, Refers),
                               hd(Str) >= $A, hd(Str) =< $Z ->
                            case lists:last(Str) =:= $. orelse clj2_class:resolve(S) =/= error of
                                true -> S;
                                false -> qsym(Ns, S)
                            end;
                        _ when S =:= defmacro; S =:= defprotocol; S =:= deftype;
                               S =:= defrecord; S =:= 'extend-type';
                               S =:= 'extend-protocol' -> qsym('clojure.core', S);
                        _ when is_map_key(S, Own) -> qsym(Ns, S);
                        _ ->
                            case Refers of
                                #{S := T} ->
                                    {RNs, RName} = clj2_ns:refer_target(S, T),
                                    qsym(RNs, RName);
                                _ -> qsym(Ns, S)
                            end
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

%% ::name is :<this namespace>/name, ::alias/name :<the aliased one>/name
kw(K, #{ns := Ns, aliases := Aliases}) ->
    case atom_to_list(K) of
        "::" ++ Rest ->
            case string:split(Rest, "/") of
                [[_ | _] = Q, [_ | _] = N] ->
                    QA = list_to_atom(Q),
                    case Aliases of
                        #{QA := Full} -> list_to_atom(":" ++ atom_to_list(Full) ++ "/" ++ N);
                        _ -> erlang:error({clj2_compile, {0, 0}, {syntax, {invalid_token, K}}})
                    end;
                _ -> list_to_atom(":" ++ atom_to_list(Ns) ++ "/" ++ Rest)
            end;
        _ -> K
    end;
kw(K, _) -> K.

%% the keywords inside quoted data
kws(K, E) when is_atom(K) -> kw(K, E);
kws(L, E) when is_list(L) -> [kws(X, E) || X <- L];
kws({vector, M, T}, E) when is_tuple(T) -> {vector, M, list_to_tuple([kws(X, E) || X <- tuple_to_list(T)])};
kws({map, M, Map}, E) when is_map(Map) -> {map, M, maps:from_list([{kws(K, E), kws(V, E)} || {K, V} <- maps:to_list(Map)])};
kws({set, M, Map}, E) when is_map(Map) -> {set, M, maps:from_list([{kws(K, E), nil} || K <- maps:keys(Map)])};
kws(X, _) -> X.

is_qualified(S) ->
    case string:split(atom_to_list(S), "/") of
        [[_ | _], [_ | _]] -> true;
        _ -> false
    end.

syntax(A, Why) -> erlang:error({clj2_compile, erl_anno:location(A), {syntax, Why}}).
unsupported(A, What) -> erlang:error({clj2_compile, erl_anno:location(A), {unsupported, What}}).
