%%%-------------------------------------------------------------------
%%% @doc `rebar3 clojerl2 compile': build each app's namespaces through
%%% the compile cache (clj2_build; designs/02 §6) into its ebin.
%%%-------------------------------------------------------------------
-module(rebar3_clojerl2_prv_compile).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, compile).

init(State) ->
    Provider = providers:create([{namespace, rebar3_clojerl2_utils:namespace()},
                                 {name, ?PROVIDER},
                                 {module, ?MODULE},
                                 {bare, true},
                                 {deps, [{default, compile}]},
                                 {example, "rebar3 clojerl2 compile"},
                                 {opts, []},
                                 {short_desc, "Compile a clojerl2 project (cached)"},
                                 {desc, "Compile the project's clojerl2 namespaces. A namespace whose "
                                        "source, compiler, OTP release, options and required "
                                        "namespaces' interfaces are unchanged comes from "
                                        "_build/<profile>/clojerl2_cache."}]),
    {ok, rebar_state:add_provider(State, Provider)}.

do(State) ->
    try
        rebar3_clojerl2_utils:add_code_paths(State),
        ok = rebar3_clojerl2_utils:ensure_clojerl2(),
        [build(App, State) || App <- rebar3_clojerl2_utils:apps(State)],
        {ok, State}
    catch
        throw:{error, _} = E -> E
    end.

build(App, State) ->
    Name = rebar_app_info:name(App),
    try rebar3_clojerl2_utils:build(App, State) of
        #{compiled := C, cached := K, removed := R, ms := Ms} ->
            rebar_api:info("clojerl2 ~ts: ~b compiled, ~b cached~ts (~b ms)",
                           [Name, length(C), length(K),
                            case R of [] -> ""; _ -> io_lib:format(", ~b removed", [length(R)]) end, Ms])
    catch
        Class:Reason:Stack ->
            throw({error, {rebar3_clojerl2_utils, {build_failed, Name, Class, Reason, Stack}}})
    end.

format_error(Reason) -> rebar3_clojerl2_utils:format_error(Reason).
