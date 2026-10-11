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
        , ensure/1
        , find_ns/1
        , put_var/3
        , put_ctx/3
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
register(Ns, Module, Vars) when is_atom(Ns), is_atom(Module), is_map(Vars) ->
    ensure_started(),
    gen_server:call(?MODULE, {register, Ns, #{module => Module, vars => Vars}}).

%% @doc Make sure `Ns' has an entry (in-ns, ns at the REPL); a namespace
%% that has none yet gets an empty one (no module of its own).
ensure(Ns) when is_atom(Ns) ->
    case info(Ns) of
        {ok, _} -> ok;
        error -> ensure_started(), gen_server:call(?MODULE, {ensure, Ns})
    end.

%% @doc Whether `Ns' is a known namespace (find-ns).
find_ns(Ns) when is_atom(Ns) -> info(Ns) =/= error;
find_ns(_) -> false.

%% @doc Add or replace one var of `Ns' (a REPL definition, whose
%% VarInfo names its own module).
put_var(Ns, Name, Info) when is_atom(Ns), is_atom(Name), is_map(Info) ->
    ensure(Ns),
    gen_server:call(?MODULE, {put_var, Ns, Name, Info}).

%% @doc Merge aliases and refers (#{Sym => Ns}) into `Ns''s REPL context.
put_ctx(Ns, Aliases, Refers) ->
    ensure(Ns),
    gen_server:call(?MODULE, {put_ctx, Ns, Aliases, Refers}).

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
    clj2_lazy:new_table(),
    clj2_eval = ets:new(clj2_eval, [named_table, public, ordered_set]),
    %% `user' always exists, as in Clojure: the REPL's first namespace. It
    %% has no module of its own (OTP's kernel has a module `user'); its
    %% vars, defined at the REPL, each have theirs.
    true = ets:insert(?TAB, {user, #{module => user, vars => #{}}}),
    {ok, #{}}.

handle_call({register, Ns, Entry}, _From, S) ->
    Ctx = case lookup(Ns) of
              {ok, Old} -> maps:with([aliases, refers], Old);
              error -> #{}
          end,
    true = ets:insert(?TAB, {Ns, maps:merge(Entry, Ctx)}),
    true = ets:delete(?FAIL_TAB, Ns),
    {reply, ok, S};
handle_call({ensure, Ns}, _From, S) ->
    case lookup(Ns) of
        {ok, _} -> ok;
        error -> true = ets:insert(?TAB, {Ns, #{module => module(Ns), vars => #{}}})
    end,
    {reply, ok, S};
handle_call({put_var, Ns, Name, Info}, _From, S) ->
    {ok, E = #{vars := Vars}} = lookup(Ns),
    true = ets:insert(?TAB, {Ns, E#{vars := Vars#{Name => Info}}}),
    {reply, ok, S};
handle_call({put_ctx, Ns, Aliases, Refers}, _From, S) ->
    {ok, E} = lookup(Ns),
    true = ets:insert(?TAB, {Ns, E#{aliases => maps:merge(maps:get(aliases, E, #{}), Aliases),
                                    refers => maps:merge(maps:get(refers, E, #{}), Refers)}}),
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

lookup(Ns) ->
    case ets:lookup(?TAB, Ns) of
        [{Ns, Info}] -> {ok, Info};
        [] -> error
    end.
