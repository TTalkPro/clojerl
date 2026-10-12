%%%-------------------------------------------------------------------
%%% @doc clj2_compiler — driver: source → reader → pass chain → .beam.
%%%
%%% The pass chain is data (`pipeline/0'); adding an optimisation is
%%% adding a module to the list (designs/01 §3). The driver owns the two
%%% effects the passes must not have (D5, designs/01 §4):
%%%
%%%   * looking up other namespaces (clj2_ns) — handed to the passes as
%%%     an explicit `scope';
%%%   * running macros — handed to parse as the `expand' capability.
%%%
%%% Form at a time: each top-level form is parsed (and macroexpanded)
%%% with every macro defined before it available. A macro defined in the
%%% namespace being compiled must be runnable before the namespace module
%%% exists, so at each `defmacro' the forms since the previous one are
%%% compiled into a compile-time segment module `'<ns>$ctN'' and loaded
%%% (their top-level forms run, as JVM Clojure loads what it compiles).
%%% Segments are deleted when the compile ends; the namespace module is
%%% compiled from all the expanded forms at once.
%%%
%%% Units:
%%%   compile_ns/load_ns  a namespace source → one module (designs/03 §2)
%%%   eval                REPL evaluation, form at a time, in namespace
%%%                       `ns' (default: the current one, *ns*). An
%%%                       expression → a throwaway module `clj2_eval_N',
%%%                       run once; a def → the var's own module
%%%                       `<ns>$v$<name>', reloaded on redefinition (BEAM
%%%                       two-version semantics, designs/02 §5); `ns'
%%%                       switches the current namespace.
%%%
%%% compile:forms runs in a process of its own (designs/02 §5).
%%%-------------------------------------------------------------------
-module(clj2_compiler).

-export([ pipeline/0
        , compile_ns/1, compile_ns/2, compile_ns_modules/2
        , load_ns/1, load_ns/2
        , forms/2, forms/3
        , eval/1, eval/2
        , macroexpand_1/2
        , var_module/2
        ]).

%% Opts `mode': dev (default) folds constants only; release also
%% inlines (designs/01 §5 pass 10, mode-gated like jolt).
back() -> back(#{}).

back(Opts) ->
    Optimise = case maps:get(mode, Opts, dev) of
                   dev -> [clj2_p_constfold];
                   release -> [clj2_p_inline, clj2_p_constfold]
               end,
    [ clj2_p_resolve                              % L0 → L1
    , clj2_p_recur                                % L1 → L1 (analysis)
    , clj2_p_loop                                 % L1 → L2
    , clj2_p_letfn                                % L2 → L3
    , clj2_p_link                                 % L3 → L4
    , {fixpoint, Optimise, #{max_iter => 8}}      % L4 → L4 (optimisation)
    , clj2_p_anf                                  % L4 → L5
    , clj2_p_verify                               % L5 → L5 (analysis)
    , clj2_p_labs                                 % L5 → Labs
    , clj2_p_emit                                 % Labs → absform
    ].

pipeline() -> [clj2_p_parse, clj2_p_declare | back()].

%%====================================================================
%% Namespaces
%%====================================================================

%% @doc Namespace source → `{ok, Ns, Module, Beam}' (the namespace module
%% only; see compile_ns_modules/2) | `{error, Errors, Warnings}'.
compile_ns(Src) -> compile_ns(Src, #{}).

compile_ns(Src, Opts) ->
    case compile_ns_modules(Src, Opts) of
        {ok, Ns, Mods} ->
            {M, Bin} = lists:last(Mods),
            {ok, Ns, M, Bin};
        {error, _, _} = E -> E
    end.

%% @doc Namespace source → `{ok, Ns, [{Module, Beam}]}': the impl modules
%% of its extend-type forms (designs/03 §4), then the namespace module.
compile_ns_modules(Src, Opts) ->
    %% segments are dropped however the compile ends, including a
    %% failing macro after some segments were loaded
    Key = {?MODULE, segments, make_ref()},
    %% *ns* is the namespace being compiled while it compiles (expand_ns
    %% sets it at the ns form), then restored
    Saved = clj2_rt_eval:save_ns(),
    try
        {Tops, Ctx} = expand_ns(Src, Opts#{segment_key => Key}),
        #{ns := Ns} = Ctx,
        M = clj2_ns:module(Ns),
        {Extends, NsTops} = lists:partition(fun(T) -> element(1, T) =:= extend end, Tops),
        {Forms, St} = compile_tops(NsTops, Ns, M, #{}, true, Ctx, Opts),
        NsVars = maps:map(fun(_, I) -> I#{module => M} end, maps:get(vars, St)),
        Units = [impl_unit(X, Ns, NsVars, Ctx, Opts) || X <- Extends] ++ [{M, Forms}],
        beams(Ns, Units, [debug_info])
    after
        drop_segments(erase(Key)),
        clj2_rt_eval:restore_ns(Saved)
    end.

beams(Ns, Units, CompileOpts) ->
    Results = [{Mod, compile_forms(Forms, CompileOpts)} || {Mod, Forms} <- Units],
    case [E || {_, {error, _, _} = E} <- Results] of
        [] -> {ok, Ns, [{Mod, Bin} || {Mod, {ok, Mod, Bin}} <- Results]};
        [E | _] -> E
    end.

%% An extend top → the forms of its impl module `<Protocol>__<Tag>'.
impl_unit({extend, A, TypeSym, ProtoSym, Methods}, Ns, NsVars, Ctx, Opts) ->
    Tag = case is_map_key(list_to_atom("->" ++ atom_to_list(TypeSym)), NsVars) of
              true -> list_to_atom(atom_to_list(Ns) ++ "." ++ atom_to_list(TypeSym));   % a type of this ns
              false -> clj2_proto:designator(TypeSym, Ns)
          end,
    Proto = protocol_id(A, ProtoSym, Ns, NsVars, Ctx),
    Mod = clj2_proto:impl_module(Proto, Tag),
    {Forms, _} = compile_tops(Methods, Ns, Mod, NsVars, false,
                              Ctx#{unit => impl, impl_of => {Proto, Tag}}, Opts),
    {Mod, Forms}.

%% The protocol a symbol names: `ns.P' for the var P of namespace ns.
protocol_id(A, Sym, Ns, NsVars, #{aliases := Al, refers := Rf}) ->
    {PNs, Name} =
        case string:split(atom_to_list(Sym), "/") of
            [[_ | _] = Q, [_ | _] = N] ->
                QA = list_to_atom(Q),
                {maps:get(QA, Al, QA), list_to_atom(N)};
            _ when is_map_key(Sym, NsVars) -> {Ns, Sym};
            _ ->
                case Rf of
                    #{Sym := T} -> clj2_ns:refer_target(Sym, T);
                    _ -> fail(A, {unresolved_protocol, Sym})
                end
        end,
    Known = case PNs =:= Ns of
                true -> is_map_key(Name, NsVars);
                false -> case clj2_ns:info(PNs) of
                             {ok, #{vars := Vs}} -> is_map_key(Name, Vs);
                             error -> false
                         end
            end,
    Known orelse fail(A, {unresolved_protocol, Sym}),
    list_to_atom(atom_to_list(PNs) ++ "." ++ atom_to_list(Name)).

%% @doc Compile and load a namespace; its `__ns_init__' runs on load.
%%
%% Reloading follows BEAM's two-version semantics (designs/02 §5):
%% closures made by the previous version keep running it; the version
%% before that is purged, unless a process still runs it (then the load
%% is refused instead of killing that process).
load_ns(Src) -> load_ns(Src, #{}).

load_ns(Src, Opts) ->
    case compile_ns_modules(Src, Opts) of
        {ok, Ns, Mods} ->
            %% impl modules first: the namespace's top-level forms may
            %% dispatch to them while it loads
            {M, Bin} = lists:last(Mods),
            case load_impls(lists:droplast(Mods)) of
                ok -> load_module(Ns, M, Bin, file(Opts, M));
                {error, _} = E -> E
            end;
        {error, Es, _} -> {error, {lint, Es}}
    end.

load_impls([]) -> ok;
load_impls([{Mod, Bin} | Rest]) ->
    case code:soft_purge(Mod) of
        false -> {error, {old_code_in_use, Mod}};
        true ->
            case code:load_binary(Mod, atom_to_list(Mod) ++ ".clj", Bin) of
                {module, Mod} -> load_impls(Rest);
                {error, Why} -> {error, {impl_load_failed, Mod, Why}}
            end
    end.

load_module(Ns, M, Bin, File) ->
    case code:soft_purge(M) of
        false -> {error, {old_code_in_use, M}};
        true ->
            clj2_ns:ensure_started(),
            true = ets:insert(clj2_beam, {M, Bin}),
            case code:load_binary(M, File, Bin) of
                {module, M} -> {ok, Ns};
                {error, on_load_failure} ->
                    case clj2_ns:take_init_failure(Ns) of
                        {ok, Reason} -> {error, {ns_init_failed, Ns, Reason}};
                        error -> {error, {on_load_failure, Ns}}
                    end;
                {error, _} = E -> E
            end
    end.

%%====================================================================
%% Expressions
%%====================================================================

%% @doc Source → abstract forms of an eval module `M' (exporting run/0).
forms(Src, M) -> forms(Src, M, #{}).

forms(Src, M, Opts) ->
    {_Impls, Forms} = eval_units(Src, M, Opts),
    Forms.

%% → {[{ImplModule, Forms}], EvalForms}
eval_units(Src, M, Opts) ->
    Ns = maps:get(ns, Opts, user),
    Ctx = ns_ctx(Ns, Opts),
    Lcore = read(Src),
    {Tops, _} = clj2_np:run([clj2_p_parse], Lcore, pass_opts(Opts, parse_state(Ctx))),
    [fail(A, {not_allowed_in_eval, ns}) || {ns_decl, A, _, _, _} <- Tops],
    {Extends, Rest} = lists:partition(fun(T) -> element(1, T) =:= extend end, Tops),
    Own = maps:get(own, Ctx),
    Impls = [impl_unit(X, Ns, Own, Ctx, Opts) || X <- Extends],
    {Forms, _} = compile_tops(Rest, Ns, M, Own, false, Ctx#{unit => eval}, Opts),
    {Impls, Forms}.

%% @doc Evaluate source (or `{forms, Forms}'), form at a time: a macro
%% defined by one form expands the next. The value of the last form.
eval(Src) -> eval(Src, #{}).

eval(Src, Opts = #{ns := Ns}) ->
    %% evaluating in a namespace: *ns* is that namespace meanwhile (macros
    %% read it), then the caller's again
    Saved = clj2_rt_eval:save_ns(),
    clj2_rt_eval:set_current_ns(Ns),
    try eval_forms(Src, Opts)
    after clj2_rt_eval:restore_ns(Saved)
    end;
eval(Src, Opts) -> eval_forms(Src, Opts).

eval_forms(Src, Opts) ->
    {V, _} = lists:foldl(fun(F, {_, O}) -> eval_form(F, O) end, {nil, Opts}, unroll_do(read(Src))),
    V.

%% A top-level (do a b c) is a, b and c as top-level forms, one after the
%% other (as the JVM compiler does): a require in it takes effect before
%% the next form compiles. (do) stays itself (it is nil).
unroll_do(Forms) -> lists:append([unroll_do1(F) || F <- Forms]).

unroll_do1(F) ->
    case unwrap(F) of
        [H | [_ | _] = Body] ->
            case unwrap(H) of
                'do' -> unroll_do(Body);
                _ -> [F]
            end;
        _ -> [F]
    end.

unwrap({clj2_loc, _, _, X, _}) -> X;
unwrap(X) -> X.

eval_form(F, Opts) ->
    Ns = current(Opts),
    {Tops, _} = clj2_np:run([clj2_p_parse], [F], pass_opts(Opts, parse_state(ns_ctx(Ns, Opts)))),
    lists:foldl(fun(T, {_, O}) -> eval_top(T, current(O), O) end, {nil, Opts}, Tops).

current(Opts) ->
    case Opts of
        #{ns := Ns} -> Ns;
        _ -> clj2_rt_eval:current_ns()
    end.

%% → {Value, Opts}
eval_top({ns_decl, _, Ns, Reqs, _}, _Cur, Opts) ->
    clj2_ns:ensure(Ns),
    declare_ns(Ns, requires(Ns, Reqs, ns_ctx(Ns, Opts))),
    clj2_rt_eval:in_ns(Ns),
    {nil, case Opts of #{ns := _} -> Opts#{ns := Ns}; _ -> Opts end};
eval_top({def, _, _, _, _} = T, Ns, Opts) ->
    {define_var(T, Ns, Opts), Opts};
eval_top({extend, _, _, _, _} = T, Ns, Opts) ->
    Ctx = ns_ctx(Ns, Opts),
    case beams(Ns, [impl_unit(T, Ns, maps:get(own, Ctx), Ctx, Opts)], [debug_info]) of
        {ok, _, ImplBeams} -> ok = load_impls(ImplBeams);
        {error, IEs, _} -> erlang:error({clj2_lint, IEs})
    end,
    {nil, Opts};
eval_top(T, Ns, Opts) ->
    M = list_to_atom("clj2_eval_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Ctx = ns_ctx(Ns, Opts),
    {Forms, _} = compile_tops([T], Ns, M, maps:get(own, Ctx), false, Ctx#{unit => eval}, Opts),
    case compile_forms(Forms, [debug_info]) of
        {ok, M, Bin} ->
            {module, M} = code:load_binary(M, file(Opts, M), Bin),
            try {M:run(), Opts}
            after
                retire_eval(M)
            end;
        {error, Es, _} ->
            erlang:error({clj2_lint, Es})
    end.

%% A def at the REPL: the var gets a module of its own, compiled like a
%% namespace unit holding just that var, and is then added to the
%% namespace's registry entry with that module. Redefinition reloads the
%% same module: closures made by the old version keep running it, new
%% calls go to the new one (designs/02 §5). → the var, #'ns/name.
define_var({def, A, Name, Meta, Init} = T, Ns, Opts) ->
    case clj2_ns:info(Ns) of
        %% a var whose value moved into the var table (clj2_rt_eval:redirect/3)
        %% stays there: a new def is an assignment, no code is loaded
        %% a watched or validated var too: the def is a change of its root
        {ok, #{vars := #{Name := I}}}
          when (is_map_key(redirected, I) orelse is_map_key(watches, I) orelse is_map_key(validator, I)),
               not is_map_key(module_def, Opts),
               Init =/= nil, not is_map_key(':dynamic', Meta), not is_map_key(':macro', Meta) ->
            Set = {invoke, A, {sym, A, 'clj2_rt/def_root'}, [{the_var, A, Name}, Init]},
            {V, _} = eval_top({eval, A, Set}, Ns, Opts),
            {ok, #{vars := #{Name := I1}}} = clj2_ns:info(Ns),
            Keep = maps:with([module, kind, redirected, dynamic, macro, validator, watches, arities, variadic], I1),
            clj2_ns:put_var(Ns, Name, maps:merge(clj2_p_declare:var_info(Meta, nil), Keep)),
            V;
        _ -> define_var_module(T, Ns, Opts)
    end.

define_var_module({def, _, Name, _, _} = T, Ns, Opts) ->
    Ctx = ns_ctx(Ns, Opts),
    M = var_module(Ns, Name),
    {Forms, St} = compile_tops([T], Ns, M, maps:get(own, Ctx), false, Ctx#{unit => ns}, Opts),
    Bin = case compile_forms(Forms, [debug_info]) of
              {ok, M, B} -> B;
              {error, Es, _} -> erlang:error({clj2_lint, Es})
          end,
    %% one definition of a var at a time (two processes defining it at
    %% once would race between purge and load)
    Loaded = global:trans({{?MODULE, define, M}, self()},
                          fun() ->
                                  case code:soft_purge(M) of
                                      false -> {error, old_code_in_use};
                                      true -> code:load_binary(M, file(Opts, M), Bin)
                                  end
                          end),
    case Loaded of
        {module, M} -> ok;
        {error, on_load_failure} ->
            case clj2_ns:take_init_failure(M) of
                {ok, {C, R, Stack}} -> erlang:raise(C, R, Stack);
                _ -> erlang:error({clj2_def_failed, Ns, Name})
            end;
        {error, Why} -> erlang:error({clj2_redefine, {Why, Ns, Name}})
    end,
    clj2_ns:put_var(Ns, Name, (maps:get(Name, maps:get(vars, St)))#{module => M}),
    clj2_rt:var(Ns, Name).

%% @doc The module of a var defined at the REPL. Module names must be
%% latin1 (function names need not): a code point above 255 is written
%% `$uXXXX$'.
var_module(Ns, Name) ->
    Latin1 = fun(C) when C > 255 -> "$u" ++ integer_to_list(C, 16) ++ "$";
                (C) -> [C]
             end,
    list_to_atom(lists:append([Latin1(C) || C <- atom_to_list(Ns) ++ "$v$" ++ atom_to_list(Name)])).

%% compile:forms in a process of its own (designs/02 §5): the compiler's
%% process state never mixes with the caller's (the REPL's).
compile_forms(Forms, Opts) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({compiled, compile:forms(Forms, [binary, return_errors | Opts])}) end),
    receive
        {'DOWN', Ref, process, Pid, {compiled, R}} -> R;
        {'DOWN', Ref, process, Pid, Why} -> erlang:error({clj2_compile_crashed, Why})
    end.

%% @doc Expand the macro call `Form' (a value) once, in namespace `Ns'.
%% `none' when its head is not a macro.
macroexpand_1(Form, Ns) ->
    Expand = expander(ns_ctx(Ns, #{})),
    case Form of
        [S | _] when is_atom(S) ->
            case Expand(S, Form, clj2_coll:hash_map_kv([])) of
                {ok, X} -> X;
                none -> Form;
                {error, Why} -> erlang:error({clj2_macroexpand, S, Why})
            end;
        _ -> Form
    end.

%%====================================================================
%% Form-at-a-time expansion of a namespace
%%====================================================================

%% Ctx: ns, aliases, refers, own (#{Name => VarInfo} of vars already
%% runnable, each with its `module'), pending (tops not yet in a
%% segment), segments (loaded segment modules).
expand_ns(Src, Opts) ->
    Lcore = unroll_do(read(Src)),
    Ctx0 = (ns_ctx(maps:get(ns, Opts, user), Opts))#{own := #{}, pending => [], segments => [],
                                                      refer_clojure => maps:get(refer_clojure, Opts, true),
                                                      defined => #{},
                                                      allowed_ns => maps:get(allowed_ns, Opts, any)},
    {RevTops, Ctx} =
        lists:foldl(
          fun(F, {Acc, C}) ->
                  {Tops, _} = clj2_np:run([clj2_p_parse], [F], pass_opts(Opts, parse_state(C))),
                  _ = [erlang:error({clj2_compile, erl_anno:location(A), {syntax, ns_must_be_first_form}})
                       || {ns_decl, A, _, _, _} = T <- Tops, Acc =/= [] orelse T =/= hd(Tops)],
                  C0 = case Tops of
                           [{ns_decl, _, Ns, Reqs, _} | _] ->
                               %% the namespace exists from its ns form on
                               %% (a macro expanding in it may resolve names)
                               clj2_ns:ensure(Ns),
                               clj2_rt_eval:set_current_ns(Ns),
                               RC = requires(Ns, Reqs, C),
                               declare_ns(Ns, RC),
                               RC;
                           [{eval, _, {invoke, _, {sym, _, Req}, Args}}]
                             when Req =:= require; Req =:= 'clojure.core/require' ->
                               compile_time_require(Args, C);
                           %% (refer 'ns ...) and (refer-clojure ...) too
                           [{eval, _, {invoke, _, {sym, _, Ref}, Args}}]
                             when Ref =:= refer; Ref =:= 'clojure.core/refer';
                                  Ref =:= 'refer-clojure'; Ref =:= 'clojure.core/refer-clojure' ->
                               compile_time_refer(Ref, Args, C);
                           %% (alias 'a 'ns) too: the forms after it use a/x
                           [{eval, _, {invoke, _, {sym, _, Alias}, [{const, _, As}, {const, _, Target}]}}]
                             when (Alias =:= alias orelse Alias =:= 'clojure.core/alias'),
                                  is_atom(As), is_atom(Target) ->
                               #{aliases := Al0} = C,
                               C#{aliases := Al0#{As => Target}};
                           _ -> C
                       end,
                  C1 = C0#{defined := maps:merge(maps:get(defined, C0),
                                                 maps:from_keys([N || {def, _, N, _, _} <- Tops], true))},
                  C2 = case [T || T = {def, _, _, #{':macro' := true}, _} <- Tops] of
                           [] -> C1#{pending := maps:get(pending, C1) ++ Tops};
                           _ -> segment(maps:get(pending, C1) ++ Tops, C1, Opts)
                       end,
                  {lists:reverse(Tops, Acc), C2}
          end, {[], Ctx0}, Lcore),
    {lists:reverse(RevTops), Ctx}.

%% A top-level (require 'x ...) also runs now, as the JVM loads what it
%% compiles: the forms after it may use its aliases and refers. (Only
%% constant arguments: anything else is left to run time.)
compile_time_require(Args, C = #{ns := Ns, aliases := Al, refers := Rf}) ->
    case lists:all(fun({const, _, _}) -> true; (_) -> false end, Args) of
        false -> C;
        true ->
            {Aliases, Refers} = clj2_rt_eval:load_specs([V || {const, _, V} <- Args], Ns),
            C#{aliases := maps:merge(Al, Aliases), refers := maps:merge(Rf, Refers)}
    end.

%% A top-level refer or refer-clojure with constant arguments runs now,
%% like require: the forms after it resolve what it maps.
compile_time_refer(Ref, Args, C = #{ns := Ns}) ->
    case lists:all(fun({const, _, _}) -> true; (_) -> false end, Args) of
        false -> C;
        true ->
            Vs = [V || {const, _, V} <- Args],
            case lists:last(string:split(atom_to_list(Ref), "/")) of
                "refer" -> clj2_rt_eval:refer(hd(Vs), tl(Vs));
                _ -> clj2_rt_eval:refer_clojure(Vs)
            end,
            C#{refers := clj2_ns:refers(Ns)}
    end.

%% Compile the pending forms into a segment module and load it, so the
%% macros (and the helpers before them) can run during this compile.
segment(Tops, Ctx = #{ns := Ns, own := Own, segments := Segs}, Opts) ->
    M = list_to_atom(atom_to_list(Ns) ++ "$ct" ++ integer_to_list(length(Segs) + 1)),
    Key = maps:get(segment_key, Opts),
    put(Key, [M | case get(Key) of undefined -> []; L -> L end]),
    Defs = [T || T = {def, _, _, _, _} <- Tops],
    %% extend-type forms are not compiled into segments: impl modules
    %% are built with the namespace (a macro cannot dispatch to an impl
    %% defined earlier in the same file — registered limitation)
    {Forms, St} = compile_tops([T || T <- Tops, element(1, T) =/= ns_decl,
                                     element(1, T) =/= extend],
                               Ns, M, Own, false, Ctx, Opts),
    case compile_forms(Forms, []) of
        {ok, M, Bin} ->
            _ = code:purge(M),
            case code:load_binary(M, atom_to_list(M) ++ ".clj", Bin) of
                {module, M} -> ok;
                {error, on_load_failure} ->
                    Why = case clj2_ns:take_init_failure(M) of
                              {ok, R} -> R;
                              error -> on_load_failure
                          end,
                    {def, A, _, _, _} = lists:last(Defs),      % the defmacro
                    fail(A, {compile_time_load_failed, Why})
            end;
        {error, Es, _} ->
            erlang:error({clj2_lint, Es})
    end,
    #{vars := SegVars} = St,
    New = maps:map(fun(_, I) -> I#{module => M} end,
                   maps:with([N || {def, _, N, _, _} <- Defs], SegVars)),
    Ctx#{own := maps:merge(Own, New), pending := [], segments := [M | Segs]}.

%% An eval module stays loaded after it ran: its result may hold funs
%% from it (closures, lazy seqs realized later). Only the oldest beyond
%% the last ?EVAL_KEEP are dropped (designs/02 §5 "eval 模块泄漏").
-define(EVAL_KEEP, 100).

retire_eval(M) ->
    clj2_ns:ensure_started(),
    true = ets:insert(clj2_eval, {erlang:unique_integer([monotonic]), M}),
    case ets:info(clj2_eval, size) > ?EVAL_KEEP of
        true ->
            Oldest = ets:first(clj2_eval),
            [{_, Old}] = ets:take(clj2_eval, Oldest),
            code:delete(Old),
            code:soft_purge(Old),
            ok;
        false -> ok
    end.

drop_segments(undefined) -> ok;
drop_segments(Segs) ->
    [begin code:purge(M), code:delete(M), code:purge(M) end || M <- Segs],
    ok.

%% Namespace context for parse and expansion. For an existing namespace
%% (eval in it) its registered vars are runnable.
ns_ctx(Ns, Opts) ->
    {Own, Repl} = case clj2_ns:info(Ns) of
                      {ok, E = #{module := M, vars := Vars}} ->
                          {maps:map(fun(_, I) -> maps:merge(#{module => M}, I) end, Vars), E};
                      error -> {#{}, #{}}
                  end,
    %% what the namespace refers now: the registry's (its ns form, refer
    %% and refer-clojure calls, ns-unmap); clojure.core's own kernel none
    Refers = case maps:get(refer_clojure, Opts, true) of
                 true -> clj2_ns:refers(Ns);
                 false -> maps:get(refers, Repl, #{})
             end,
    #{ns => Ns, aliases => maps:get(aliases, Repl, #{}),
      refers => Refers, own => Own,
      defined => maps:map(fun(_, _) -> true end, Own)}.

requires(Ns, Reqs, Ctx) ->
    _ = [begin clj2_rt_eval:ensure_loaded(R), info_or_fail(R) end || #{ns := R} <- Reqs, R =/= Ns],
    Specs = core_specs(Reqs),
    Explicit = explicit_refers(Reqs),
    Core = case maps:get(refer_clojure, Ctx, true) of
               true -> clj2_ns:core_refers(Ns, Specs);
               false -> #{}
           end,
    Ctx#{ns := Ns,
         aliases := maps:from_list([{As, R} || #{ns := R, as := As} <- Reqs, As =/= nil]),
         refers := maps:merge(Core, Explicit),
         core_refer => Specs}.

%% Every namespace but clojure.core itself refers clojure.core's public
%% vars (Clojure's implicit (refer-clojure)), as its ns form's
%% :refer-clojure clauses filter them (:exclude, :only, :rename); a
%% listed name core lacks is the JVM's IllegalAccessError. Its own
%% definitions shadow them (resolve, the expander and syntax-quote look
%% at their own namespace first).
core_specs(Reqs) ->
    case [S || #{refer_clojure := S} <- Reqs] of
        [] -> [#{}];
        Specs ->
            _ = [clj2_ns:refer_map('clojure.core', S, strict) || S <- Specs],
            Specs
    end.

explicit_refers(Reqs) ->
    lists:foldl(fun(R, Acc) -> maps:merge(Acc, clj2_rt_eval:req_refers(R)) end,
                #{}, [R || R = #{refer := _} <- Reqs]).

%% The ns form, in the registry from the moment it is read: macros that
%% run while the rest compiles (resolve, ns-map ...) see its context.
declare_ns(Ns, Ctx = #{aliases := Al}) ->
    clj2_ns:ensure(Ns),
    clj2_ns:set_core_refer(Ns, maps:get(core_refer, Ctx, [#{}])),
    clj2_ns:put_ctx(Ns, Al, maps:filter(fun(_, T) -> not is_core_target(T) end, maps:get(refers, Ctx))),
    ok.

is_core_target('clojure.core') -> true;
is_core_target({'clojure.core', _}) -> true;
is_core_target(_) -> false.

parse_state(Ctx = #{ns := Ns, aliases := Al, refers := Rf}) ->
    #{ns => Ns, aliases => Al, refers => Rf, expand => expander(Ctx),
      own_names => maps:get(defined, Ctx, #{}),
      %% a namespace file compiles all its forms into one module (its
      %% compile-time segments are recompiled with it); the REPL defines
      %% each var on its own
      file_unit => is_map_key(pending, Ctx)}.

read(Src) when is_binary(Src) ->
    case clj2_reader:read_all(Src) of
        {ok, Lcore, _} -> Lcore;
        {error, Loc, Msg} -> erlang:error({clj2_read, Loc, Msg})
    end;
read({forms, Lcore}) when is_list(Lcore) -> Lcore.

%%====================================================================
%% Macros
%%====================================================================

%% The `expand' capability given to parse.
expander(Ctx) ->
    fun(S, Form, Env) ->
            case macro_var(S, Ctx) of
                none -> none;
                {private, Shown} ->
                    {error, {not_public, iolist_to_binary(["var: ", Shown, " is not public"])}};
                {M, Name, Info} ->
                    try
                        %% a fn var links directly; a var made a macro by
                        %% its metadata ((def m @#'other) + :macro) holds it
                        F = clj2_rt:var_value(M, Name, Info),
                        {ok, clj2_form:from_value(clj2_rt:invoke(F, [Form, Env | tl(Form)]))}
                    catch
                        C:R -> {error, {C, R}}
                    end
            end
    end.

macro_var(S, Ctx = #{ns := Ns, aliases := Al, refers := Rf, own := Own}) ->
    Defined = maps:get(defined, Ctx, #{}),
    case string:split(atom_to_list(S), "/") of
        [[_ | _] = Q, [_ | _] = N] ->
            QA = list_to_atom(Q),
            Full = maps:get(QA, Al, QA),
            Name = list_to_atom(N),
            case Full =:= Ns of
                true -> own_macro(Name, Own);
                false ->
                    case ext_macro(Full, Name) of
                        %% another namespace's private macro is refused, as
                        %% on the JVM (clojure.core's serve its own expansions)
                        {_, _, #{private := true}} when Full =/= 'clojure.core' ->
                            {private, ["#'", atom_to_list(Full), "/", atom_to_list(Name)]};
                        Found -> Found
                    end
            end;
        _ ->
            case own_macro(S, Own) of
                none when is_map_key(S, Defined) -> none;    % an own var shadows a referred macro
                none ->
                    case Rf of
                        #{S := T} ->
                            {RNs, RName} = clj2_ns:refer_target(S, T),
                            ext_macro(RNs, RName);
                        _ -> none
                    end;
                Found -> Found
            end
    end.

own_macro(Name, Own) ->
    case Own of
        #{Name := #{macro := true, module := M} = I} -> {M, Name, I};
        _ -> none
    end.

ext_macro(Ns, Name) ->
    case clj2_ns:info(Ns) of
        {ok, #{module := M, vars := #{Name := #{macro := true} = I}}} -> {maps:get(module, I, M), Name, I};
        _ -> none
    end.

%%====================================================================
%% Back half of the pipeline
%%====================================================================

%% Expanded top nodes → abstract forms. `Prior' are runnable vars from
%% earlier segments (they keep their module); `Register' is false for a
%% segment and an eval unit.
compile_tops(Tops, Ns, M, Prior, Register, Ctx, Opts) ->
    Unit = maps:get(unit, Ctx, ns),
    St0 = (maps:with([file], Opts))#{next_uid => 1, ns => Ns, prior => Prior},
    {Tops1, St1} = clj2_np:run([clj2_p_declare], Tops, pass_opts(Opts, St0)),
    #{vars := Declared} = St1,
    Vars = maps:merge(Prior, Declared),
    St2 = St1#{ns := Ns, vars := Vars, unit => Unit, module => M, register => Register,
               impl_of => maps:get(impl_of, Ctx, none),
               %% what the module's init registers besides its vars: the
               %% explicit aliases and refers (the implicit clojure.core
               %% refer is known to the registry already)
               ns_aliases => maps:get(aliases, Ctx, #{}),
               ns_refers => maps:filter(fun(_, T) -> not is_core_target(T) end, maps:get(refers, Ctx, #{})),
               ns_core_refer => maps:get(core_refer, Ctx, [#{}]),
               scope => scope(St1, Ns, Vars, Unit, M, Ctx)},
    clj2_np:run(back(Opts), Tops1, pass_opts(Opts, St2)).

%% The namespaces this unit can see, looked up once, here.
scope(#{ns_refs := Refs}, Ns, Vars, Unit, M, Ctx = #{aliases := Aliases, refers := Refers}) ->
    Required = lists:usort(maps:values(Aliases) ++
                           [element(1, clj2_ns:refer_target(S, T)) || {S, T} <- maps:to_list(Refers)]),
    Ext0 = maps:from_list([{R, info_or_fail(R)} || R <- Required, R =/= Ns]),
    Ext = lists:foldl(fun(Q, Acc) when Q =:= Ns; is_map_key(Q, Acc) -> Acc;
                         (Q, Acc) ->
                              %% a namespace not loaded yet but on the source
                              %% path (clojure.string ...) loads now
                              clj2_rt_eval:ensure_loaded(Q),
                              case clj2_ns:info(Q) of
                                  {ok, Info} -> Acc#{Q => Info};
                                  error -> Acc        % an Erlang module
                              end
                      end, Ext0, [maps:get(Q, Aliases, Q) || Q <- Refs]),
    %% lint (clojerl2-014): a unit may be limited to some namespaces;
    %% clojure.core's kernel may use none (Erlang modules only)
    case maps:get(allowed_ns, Ctx, any) of
        any -> ok;
        Allowed ->
            [erlang:error({clj2_compile, {0, 0}, {lint, {namespace_not_allowed, Q}}})
             || Q <- maps:keys(Ext), not lists:member(Q, Allowed)]
    end,
    NsModule = case Unit of
                   ns -> M;
                   _ -> clj2_ns:module(Ns)            % eval / impl units live beside it
               end,
    #{ns => Ns, module => NsModule, vars => Vars, aliases => Aliases,
      refers => Refers, externals => Ext}.

info_or_fail(Ns) ->
    case clj2_ns:info(Ns) of
        {ok, Info} -> Info;
        error -> erlang:error({clj2_compile, {0, 0}, {ns_not_found, Ns}})
    end.

pass_opts(Opts, St) -> (maps:with([check, trace, trace_fun], Opts))#{state => St}.

file(Opts, M) -> maps:get(file, Opts, atom_to_list(M) ++ ".clj").

fail(A, Why) -> erlang:error({clj2_compile, erl_anno:location(A), {driver, Why}}).
