%%%-------------------------------------------------------------------
%%% @doc `rebar3 clojerl2 repl': compile, then a clojerl2 REPL with the
%%% project's code path; `require' also finds namespaces in the apps'
%%% clj2_src_dirs.
%%%-------------------------------------------------------------------
-module(rebar3_clojerl2_prv_repl).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, repl).

init(State) ->
    Provider = providers:create([{namespace, rebar3_clojerl2_utils:namespace()},
                                 {name, ?PROVIDER},
                                 {module, ?MODULE},
                                 {bare, true},
                                 {deps, [{rebar3_clojerl2_utils:namespace(), compile}]},
                                 {example, "rebar3 clojerl2 repl"},
                                 {opts, []},
                                 {short_desc, "Start a clojerl2 REPL"},
                                 {desc, "Start a clojerl2 REPL on the project's code path."}]),
    {ok, rebar_state:add_provider(State, Provider)}.

do(State) ->
    rebar3_clojerl2_utils:add_code_paths(State),
    ok = rebar3_clojerl2_utils:ensure_clojerl2(),
    {ok, _} = clj2_build:ensure_core(rebar3_clojerl2_utils:cache_dir(State)),
    clj2_rt_eval:set_source_path(lists:append([rebar3_clojerl2_utils:src_dirs(A)
                                               || A <- rebar3_clojerl2_utils:apps(State)])),
    clj2_repl:start(),
    {ok, State}.

format_error(Reason) -> rebar3_clojerl2_utils:format_error(Reason).
