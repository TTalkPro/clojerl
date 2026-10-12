%%%-------------------------------------------------------------------
%%% @doc clj2_ns — namespace registry (designs/03 §2.1, D7).
%%%
%%% One NS = one BEAM module. The registry is one ETS table
%%% (`clj2_ns', named, read_concurrency) holding
%%% `{Ns, #{module => M, vars => #{Name => VarInfo}}}'. Reads go straight
%%% to ETS; writes are serialised through this gen_server, which also
%%% owns the var-root table of {@link clj2_var}.
%%%
%%% A compiled NS module registers itself from its `-on_load'
%%% function `__ns_init__/0', so a module loaded from the code path
%%% is registered exactly like one loaded by the compiler.
%%%
%%% VarInfo:
%%%   #{kind := fn,  arities := [N], variadic := Min | nil, ...}
%%%   #{kind := const | cell | indirect, dynamic := boolean(), ...}
%%% plus `module' when the var lives in a module of its own rather than
%%% the namespace's (a var defined at the REPL, designs/02 §5).
%%%
%%% An entry may also carry `aliases' and `refers' (#{Sym => Ns}): what
%%% `require'/`ns' evaluated at the REPL added to the namespace. They
%%% survive a reload of the namespace module.
%%%-------------------------------------------------------------------
-module(clj2_ns).

-behaviour(gen_server).

-export([ ensure_started/0
        , register/3
        , register/4
        , remove_var/2
        , remove_alias/2
        , ensure/2
        , refers/1
        , core_refers/1
        , core_refers/2
        , refer_map/3
        , refer_target/2
        , set_core_refer/2
        , add_core_refer/2
        , ensure/1
        , find_ns/1
        , put_var/3
        , put_ctx/3
        , set_var_meta/2
        , remove/1
        , info/1
        , module/1
        , all/0
        , init_failed/2
        , take_init_failure/1
        , find_var/1
        , public_vars/1
        , all_vars/0
        ]).

-export([init/1, handle_call/3, handle_cast/2]).

-define(TAB, clj2_ns).
-define(FAIL_TAB, clj2_ns_fail).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the registry if it is not running. Not linked to the
%% caller: on_load runs in a short-lived process.
ensure_started() ->
    case whereis(?MODULE) of
        undefined ->
            case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok
            end;
        _ -> ok
    end.

%% @doc Register (or re-register, on reload) a namespace.
register(Ns, Module, Vars) ->
    register(Ns, Module, Vars, #{}).

%% @doc Register a namespace with the aliases and refers its `ns' form
%% declared (`#{aliases => #{Alias => Ns}, refers => #{Sym => Ns}}'), so
%% ns-aliases / ns-refers / resolve see them at run time.
register(Ns, Module, Vars, Ctx) when is_atom(Ns), is_atom(Module), is_map(Vars), is_map(Ctx) ->
    ensure_started(),
    gen_server:call(?MODULE, {register, Ns, maps:merge(maps:with([aliases, refers], Ctx),
                                                       #{module => Module, vars => Vars})}).

%% @doc Make sure `Ns' has an entry; a namespace that has none yet gets an
%% empty one (no module of its own) that refers all of clojure.core.
ensure(Ns) -> ensure(Ns, refer_all).

%% @doc ensure/1, choosing what a new namespace refers: `refer_all', or
%% `bare' (nothing: what (in-ns 'x) and (create-ns 'x) make on the JVM,
%% until a refer-clojure).
ensure(Ns, Kind) when is_atom(Ns), (Kind =:= refer_all orelse Kind =:= bare) ->
    case info(Ns) of
        {ok, _} -> ok;
        error -> ensure_started(), gen_server:call(?MODULE, {ensure, Ns, Kind})
    end.

%%--------------------------------------------------------------------
%% Refers
%%
%% A namespace's entry may carry
%%   core_refer  [Spec]: its (refer 'clojure.core ...) calls -- the ns
%%               form's :refer-clojure clauses, then any refer-clojure
%%               made at run time; absent means [#{}], refer everything
%%               (the user namespace); [] refers nothing (a bare in-ns)
%%   refers      #{Sym => Target}: what it refers from other namespaces
%%   unmapped    #{Sym => true}: names ns-unmap took away from both
%% A Spec is #{exclude => [Sym], only => all | [Sym], rename => #{Sym => Sym}}
%% and a Target is the namespace (same name) or {Ns, Name} (renamed).
%%--------------------------------------------------------------------

%% @doc Everything `Ns' refers: Sym => Target.
refers(Ns) ->
    case lookup(Ns) of
        {ok, E} ->
            Core = core_refers(Ns, maps:get(core_refer, E, [#{}])),
            maps:without(maps:keys(maps:get(unmapped, E, #{})),
                         maps:merge(Core, maps:get(refers, E, #{})));
        error -> core_refers(Ns, [#{}])
    end.

%% @doc What `Ns' refers from clojure.core (no explicit refers).
core_refers(Ns) ->
    case lookup(Ns) of
        {ok, E} -> core_refers(Ns, maps:get(core_refer, E, [#{}]));
        error -> core_refers(Ns, [#{}])
    end.

core_refers('clojure.core', _) -> #{};
core_refers(_Ns, Specs) ->
    %% in-ns and ns stay reachable whatever a namespace refers, as on the
    %% JVM (a bare namespace still needs a way out)
    Always = maps:from_list([{N, 'clojure.core'} || N <- ['in-ns', ns], is_core_var(N)]),
    lists:foldl(fun(Spec, Acc) -> maps:merge(Acc, refer_map('clojure.core', Spec, lenient)) end,
                Always, Specs).

is_core_var(N) ->
    case lookup('clojure.core') of
        {ok, #{vars := #{N := _}}} -> true;
        _ -> false
    end.

%% @doc The names (refer From & filters) maps, as Sym => Target. `strict'
%% raises the JVM's IllegalAccessError for a listed name that is missing
%% or private; `lenient' skips it.
refer_map(From, Spec, Mode) ->
    {Publics, Interns} = case lookup(From) of
                             {ok, #{vars := Vars}} ->
                                 {maps:filter(fun(_, I) -> not maps:get(private, I, false) end, Vars), Vars};
                             error -> {#{}, #{}}
                         end,
    ToDo = case maps:get(only, Spec, all) of
               all -> maps:keys(Publics);
               Only -> Only
           end,
    Exclude = maps:get(exclude, Spec, []),
    Rename = maps:get(rename, Spec, #{}),
    lists:foldl(
      fun(S, Acc) ->
              case lists:member(S, Exclude) of
                  true -> Acc;
                  false when is_map_key(S, Publics) ->
                      New = maps:get(S, Rename, S),
                      Acc#{New => target(From, S, New)};
                  false when Mode =:= lenient -> Acc;
                  false -> illegal_access(S, is_map_key(S, Interns))
              end
      end, #{}, ToDo).

target(From, S, S) -> From;
target(From, S, _New) -> {From, S}.

%% @doc The var a refer entry names: {Ns, Name}.
refer_target(S, {Ns, Name}) when is_atom(S) -> {Ns, Name};
refer_target(S, Ns) when is_atom(Ns) -> {Ns, S}.

illegal_access(S, Private) ->
    Msg = case Private of
              true -> <<" is not public">>;
              false -> <<" does not exist">>
          end,
    erlang:error(clj2_rt:ex_info(<<(atom_to_binary(S))/binary, Msg/binary>>,
                                 clj2_coll:hash_map_kv([':type', ':IllegalAccessError']), nil)).

%% @doc The ns form's :refer-clojure clauses: what `Ns' refers from
%% clojure.core from now on (replacing what an earlier ns form said).
set_core_refer(Ns, Specs) when is_atom(Ns), is_list(Specs) ->
    ensure(Ns),
    gen_server:call(?MODULE, {core_refer, Ns, set, Specs}).

%% @doc A (refer-clojure ...) at run time: its names add to what `Ns'
%% refers (a later :exclude does not withdraw a mapped name).
add_core_refer(Ns, Spec) when is_atom(Ns), is_map(Spec) ->
    ensure(Ns),
    gen_server:call(?MODULE, {core_refer, Ns, add, Spec}).

%% @doc Whether `Ns' is a known namespace (find-ns).
find_ns(Ns) when is_atom(Ns) -> info(Ns) =/= error;
find_ns(_) -> false.

%% @doc Add or replace one var of `Ns' (a REPL definition, whose
%% VarInfo names its own module).
put_var(Ns, Name, Info) when is_atom(Ns), is_atom(Name), is_map(Info) ->
    ensure(Ns),
    gen_server:call(?MODULE, {put_var, Ns, Name, Info}).

%% @doc (reset-meta! #'v m): the var's metadata becomes m (kept in its
%% VarInfo as `meta', over what the registry knows)
set_var_meta({var, _, {Ns, Name}}, M) ->
    {ok, #{vars := #{Name := I}}} = info(Ns),
    Meta = element(3, M),
    %% :macro in the metadata makes the var a macro from now on, as on
    %% the JVM (the compiler reads `macro')
    I1 = case maps:find(':macro', Meta) of
             {ok, Flag} -> I#{macro => Flag =:= true};
             error -> I
         end,
    put_var(Ns, Name, I1#{meta => Meta}).

%% @doc Merge aliases and refers (#{Sym => Ns}) into `Ns''s REPL context.
put_ctx(Ns, Aliases, Refers) ->
    ensure(Ns),
    gen_server:call(?MODULE, {put_ctx, Ns, Aliases, Refers}).

%% @doc (ns-unmap ns sym): forget one var of `Ns', and the refer of that
%% name (clojure.core's implicit ones included).
remove_var(Ns, Name) when is_atom(Ns), is_atom(Name) ->
    ensure_started(),
    gen_server:call(?MODULE, {remove_var, Ns, Name}).

%% @doc (ns-unalias ns sym): forget one alias of `Ns'.
remove_alias(Ns, Alias) when is_atom(Ns), is_atom(Alias) ->
    ensure_started(),
    gen_server:call(?MODULE, {remove_alias, Ns, Alias}).

%% @doc Forget a namespace and its var roots.
remove(Ns) ->
    ensure_started(),
    gen_server:call(?MODULE, {remove, Ns}).

%% @doc Registry entry of `Ns'. A namespace compiled earlier but not
%% loaded yet is loaded from the code path (its on_load registers it).
-spec info(atom()) -> {ok, map()} | error.
info(Ns) ->
    ensure_started(),
    case lookup(Ns) of
        {ok, _} = Ok -> Ok;
        error ->
            case code:ensure_loaded(module(Ns)) of
                {module, _} -> lookup(Ns);
                {error, _} -> error
            end
    end.

%% @doc The BEAM module of a namespace (identity: `foo.bar' → 'foo.bar').
module(Ns) -> Ns.

all() ->
    ensure_started(),
    [Ns || {Ns, _} <- ets:tab2list(?TAB)].

%% @doc Called by a failing `__ns_init__' (the on_load process cannot
%% hand its exception to the loader any other way).
init_failed(Ns, Reason) ->
    ensure_started(),
    gen_server:call(?MODULE, {init_failed, Ns, Reason}).

take_init_failure(Ns) ->
    ensure_started(),
    gen_server:call(?MODULE, {take_init_failure, Ns}).

%% @doc REPL helpers (04-repl): a var by symbol → [ns name info] as
%% Clojure data, or nil. An unqualified symbol is looked up in
%% clojure.core first, then in every namespace.
find_var(Sym) ->
    ensure_started(),
    Cands = case string:split(atom_to_list(Sym), "/") of
                [[_ | _] = Q, [_ | _] = Nm] -> [{list_to_atom(Q), list_to_atom(Nm)}];
                _ -> [{'clojure.core', Sym} | [{Ns, Sym} || Ns <- all(), Ns =/= 'clojure.core']]
            end,
    case [{Ns, N, I} || {Ns, N} <- Cands, {ok, #{vars := #{N := I}}} <- [lookup(Ns)]] of
        [{FNs, FN, FI} | _] -> clj2_coll:vector([FNs, FN, info_map(FI)]);
        [] -> nil
    end.

public_vars(Ns) ->
    case lookup(Ns) of
        {ok, #{vars := Vars}} ->
            [clj2_coll:vector([N, info_map(I)]) || {N, I} <- maps:to_list(Vars),
                                                    not maps:get(private, I, false)];
        error -> []
    end.

all_vars() ->
    ensure_started(),
    [clj2_coll:vector([Ns, N, info_map(I)])
     || {Ns, #{vars := Vars}} <- ets:tab2list(?TAB), {N, I} <- maps:to_list(Vars)].

info_map(I) ->
    clj2_coll:hash_map_kv(lists:append([[list_to_atom(":" ++ atom_to_list(K)), V]
                                        || {K, V} <- maps:to_list(I)])).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    ?TAB = ets:new(?TAB, [named_table, protected, set, {read_concurrency, true}]),
    ?FAIL_TAB = ets:new(?FAIL_TAB, [named_table, protected, set]),
    clj2_var:new_table(),
    clj2_proto:new_table(),
    clj2_ref:new_tables(),
    clj2_re:new_table(),
    clj2_multi:new_table(),
    clj2_lazy:new_table(),
    clj2_eval = ets:new(clj2_eval, [named_table, public, ordered_set]),
    %% the beams of namespaces loaded from memory (clj2_compiler:load_ns),
    %% for clj2_rt_eval:redirect/3
    clj2_beam = ets:new(clj2_beam, [named_table, public, set]),
    %% `user' always exists, as in Clojure: the REPL's first namespace. It
    %% has no module of its own (OTP's kernel has a module `user'); its
    %% vars, defined at the REPL, each have theirs.
    true = ets:insert(?TAB, {user, #{module => user, vars => #{}}}),
    {ok, #{}}.

handle_call({register, Ns, Entry}, _From, S) ->
    %% what the module declares, over what was added at the REPL before
    Old = case lookup(Ns) of
              {ok, O} -> O;
              error -> #{}
          end,
    Ctx0 = #{aliases => maps:merge(maps:get(aliases, Old, #{}), maps:get(aliases, Entry, #{})),
             refers => maps:merge(maps:get(refers, Old, #{}), maps:get(refers, Entry, #{})),
             unmapped => maps:get(unmapped, Old, #{})},
    %% the module's ns form says what it refers from clojure.core
    Ctx = case Entry of
              #{core_refer := _} -> Ctx0;
              _ -> maps:merge(Ctx0, maps:with([core_refer], Old))
          end,
    true = ets:insert(?TAB, {Ns, remap(maps:merge(Entry, Ctx), maps:keys(maps:get(refers, Entry, #{})))}),
    true = ets:delete(?FAIL_TAB, Ns),
    {reply, ok, S};
handle_call({ensure, Ns, Kind}, _From, S) ->
    case lookup(Ns) of
        {ok, _} -> ok;
        error ->
            %% user always refers clojure.core (the JVM creates it so)
            Core = case Kind of
                       bare when Ns =/= user -> #{core_refer => []};
                       _ -> #{}
                   end,
            true = ets:insert(?TAB, {Ns, Core#{module => module(Ns), vars => #{}}})
    end,
    {reply, ok, S};
handle_call({core_refer, Ns, How, X}, _From, S) ->
    {ok, E} = lookup(Ns),
    Specs = case How of
                set -> X;
                add -> maps:get(core_refer, E, [#{}]) ++ [X]
            end,
    Mapped = case How of
                 set -> maps:keys(core_refers(Ns, Specs));
                 add -> maps:keys(refer_map('clojure.core', X, lenient))
             end,
    true = ets:insert(?TAB, {Ns, remap(E#{core_refer => Specs}, Mapped)}),
    {reply, ok, S};
handle_call({put_var, Ns, Name, Info}, _From, S) ->
    {ok, E = #{vars := Vars}} = lookup(Ns),
    true = ets:insert(?TAB, {Ns, E#{vars := Vars#{Name => Info}}}),
    {reply, ok, S};
handle_call({put_ctx, Ns, Aliases, Refers}, _From, S) ->
    {ok, E} = lookup(Ns),
    true = ets:insert(?TAB, {Ns, remap(E#{aliases => maps:merge(maps:get(aliases, E, #{}), Aliases),
                                          refers => maps:merge(maps:get(refers, E, #{}), Refers)},
                                    maps:keys(Refers))}),
    {reply, ok, S};
handle_call({remove_var, Ns, Name}, _From, S) ->
    case lookup(Ns) of
        {ok, E = #{vars := Vars}} ->
            true = ets:insert(?TAB, {Ns, E#{vars := maps:remove(Name, Vars),
                                            refers => maps:remove(Name, maps:get(refers, E, #{})),
                                            unmapped => (maps:get(unmapped, E, #{}))#{Name => true}}});
        error -> ok
    end,
    {reply, ok, S};
handle_call({remove_alias, Ns, Alias}, _From, S) ->
    case lookup(Ns) of
        {ok, E} -> true = ets:insert(?TAB, {Ns, E#{aliases => maps:remove(Alias, maps:get(aliases, E, #{}))}});
        error -> ok
    end,
    {reply, ok, S};
handle_call({remove, Ns}, _From, S) ->
    case ets:lookup(?TAB, Ns) of
        [{Ns, #{module := M, vars := Vars}}] ->
            [clj2_var:delete_roots(VM) || VM <- lists:usort([M | [VM || #{module := VM} <- maps:values(Vars)]])];
        [] -> ok
    end,
    true = ets:delete(?TAB, Ns),
    {reply, ok, S};
handle_call({init_failed, Ns, Reason}, _From, S) ->
    true = ets:insert(?FAIL_TAB, {Ns, Reason}),
    true = ets:delete(?TAB, Ns),
    {reply, ok, S};
handle_call({take_init_failure, Ns}, _From, S) ->
    R = case ets:take(?FAIL_TAB, Ns) of
            [{Ns, Reason}] -> {ok, Reason};
            [] -> error
        end,
    {reply, R, S}.

handle_cast(_Msg, S) -> {noreply, S}.

%%====================================================================
%% Internal
%%====================================================================

%% names referred again are mapped again
remap(E, []) -> E;
remap(E = #{unmapped := U}, Names) -> E#{unmapped := maps:without(Names, U)};
remap(E, _) -> E.

lookup(Ns) ->
    case ets:lookup(?TAB, Ns) of
        [{Ns, Info}] -> {ok, Info};
        [] -> error
    end.
