%%%-------------------------------------------------------------------
%%% @doc clj2 — embedding clojerl2 in an Erlang application
%%% (designs/10, clojerl2-044).
%%%
%%% A host hands clojerl2 Clojure source at run time, loads it as a
%%% namespace (compiled to a BEAM module), calls its fns, and loads it
%%% again when the source changes: the new version replaces the old one
%%% while the system runs.
%%%
%%%   ok = clj2:ensure(),
%%%   {ok, 'rules.demo'} = clj2:load(<<"(ns rules.demo) (defn score [x] (* 2 x))">>),
%%%   {ok, 42} = clj2:call('rules.demo', score, [21]),
%%%   {ok, 3} = clj2:eval(<<"(+ 1 2)">>).
%%%
%%% Errors come back as data, not exceptions:
%%%   {error, #{kind := read | syntax | load | runtime, message := binary(),
%%%             line => pos_integer(), column => pos_integer(), reason := term()}}
%%%
%%% Values cross the boundary as they are (docs/erlang-interop.md):
%%% Erlang maps, binaries and lists can be used by Clojure code directly.
%%%-------------------------------------------------------------------
-module(clj2).

-export([ensure/0, load/1, load/2, call/3, eval/1, eval/2, unload/1, gc/0, gc/1, is_loaded/1,
         module/1, error_info/3]).

-type error_info() :: #{kind := read | syntax | load | runtime, message := binary(),
                        line => pos_integer(), column => pos_integer(), reason := term()}.
-export_type([error_info/0]).

%% @doc Start the runtime and load clojure.core (idempotent).
-spec ensure() -> ok.
ensure() ->
    {ok, _} = clj2_core:ensure(),
    ok.

%% @doc Compile and load a namespace from source (one `ns' form first).
%% Loading a namespace again replaces it: calls made after the load run
%% the new code, a call already running finishes on the old one.
%% Opts: file (the name errors and stack traces show); versioned (true:
%% compile to a module of its own, <ns>$v<N>, so that a call still running
%% the previous version never blocks this load; gc/0,1 removes the
%% versions nothing runs any more).
-spec load(iodata()) -> {ok, atom()} | {error, error_info()}.
load(Src) -> load(Src, #{}).

-spec load(iodata(), map()) -> {ok, atom()} | {error, error_info()}.
load(Src, Opts) ->
    ensure(),
    try clj2_compiler:load_ns(to_bin(Src), Opts) of
        {ok, Ns} ->
            maps:get(versioned, Opts, false) andalso note_version(Ns),
            {ok, Ns};
        {error, {ns_init_failed, _Ns, {C, R, S}}} -> {error, error_info(C, R, S)};
        {error, {lint, Es}} -> {error, error_info(error, {clj2_lint, Es}, [])};
        {error, Why} -> {error, (error_info(error, Why, []))#{kind => load}}
    catch C:R:S -> {error, error_info(C, R, S)}
    end.

%% @doc Call the fn var Fn of namespace Ns with Args.
-spec call(atom(), atom() | binary(), [term()]) -> {ok, term()} | {error, error_info()}.
call(Ns, Fn, Args) when is_binary(Fn) -> call(Ns, binary_to_atom(Fn), Args);
call(Ns, Fn, Args) when is_atom(Ns), is_atom(Fn), is_list(Args) ->
    try {ok, clj2_rt:invoke(clj2_ref:deref(clj2_rt:var(Ns, Fn)), Args)}
    catch C:R:S -> {error, error_info(C, R, S)}
    end.

%% @doc Evaluate source (any number of forms) in namespace `user'; the
%% value of the last form.
-spec eval(iodata()) -> {ok, term()} | {error, error_info()}.
eval(Src) -> eval(Src, #{}).

%% Opts: ns (the namespace to evaluate in).
-spec eval(iodata(), map()) -> {ok, term()} | {error, error_info()}.
eval(Src, Opts) ->
    ensure(),
    try {ok, clj2_compiler:eval(to_bin(Src), Opts)}
    catch C:R:S -> {error, error_info(C, R, S)}
    end.

%% @doc Forget a namespace and remove its module(s): the plain one and
%% every version of a versioned one.
-spec unload(atom()) -> ok.
unload(Ns) when is_atom(Ns) ->
    Mods = lists:usort([clj2_ns:module(Ns) | versions(Ns)]),
    clj2_ns:remove(Ns),
    [remove_module(M) || M <- Mods],
    persistent_term:erase({?MODULE, versions, Ns}),
    ok.

%% @doc Remove the old versions of versioned namespaces that no process
%% runs any more; one still in use stays for a later gc. → the modules
%% still kept (besides each namespace's current one).
-spec gc() -> [module()].
gc() ->
    lists:append([gc(Ns) || {{?MODULE, versions, Ns}, _} <- persistent_term:get()]).

-spec gc(atom()) -> [module()].
gc(Ns) ->
    Current = current_module(Ns),
    {Keep, _Gone} = lists:partition(fun(M) -> M =:= Current orelse not try_remove(M) end, versions(Ns)),
    persistent_term:put({?MODULE, versions, Ns}, Keep),
    Keep -- [Current].

%% the module a namespace's vars live in now
current_module(Ns) ->
    case clj2_ns:info(Ns) of
        {ok, #{module := M}} -> M;
        _ -> none
    end.

versions(Ns) -> persistent_term:get({?MODULE, versions, Ns}, []).

note_version(Ns) ->
    persistent_term:put({?MODULE, versions, Ns}, lists:usort([current_module(Ns) | versions(Ns)])).

%% a module no process runs: deleted and purged → true; in use → false
try_remove(M) ->
    case erlang:module_loaded(M) of
        false -> code:soft_purge(M);
        true ->
            case code:soft_purge(M) of            % an old version of M itself
                false -> false;
                true -> code:delete(M), code:soft_purge(M)
            end
    end.

remove_module(M) ->
    _ = code:purge(M),
    _ = code:delete(M),
    _ = code:purge(M),
    ok.

%% @doc Is the namespace loaded?
-spec is_loaded(atom()) -> boolean().
is_loaded(Ns) -> clj2_ns:find_ns(Ns).

%% @doc The BEAM module of a namespace (its fns are that module's functions).
-spec module(atom()) -> module().
module(Ns) -> clj2_ns:module(Ns).

%% @doc An exception (class, reason, stacktrace) as error info.
-spec error_info(atom(), term(), list()) -> error_info().
error_info(C, R, S) ->
    Msg = unicode:characters_to_binary(string:trim(clj2_repl:format_error(C, R, S))),
    Base = #{kind => kind(R), message => Msg, reason => R},
    maps:merge(Base, position(R)).

kind({clj2_read, _}) -> read;
kind({clj2_read, _, _}) -> read;
kind({clj2_compile, _, {read, _}}) -> read;
kind({clj2_compile, _, _}) -> syntax;
kind({clj2_lint, _}) -> syntax;
kind(_) -> runtime.

position({clj2_compile, {L, C}, _}) when is_integer(L) -> #{line => L, column => C};
position({clj2_compile, {_File, {L, C}}, _}) -> #{line => L, column => C};
position({clj2_read, {L, C}, _}) -> #{line => L, column => C};
position(_) -> #{}.

to_bin(B) when is_binary(B) -> B;
to_bin(S) -> unicode:characters_to_binary(S).
