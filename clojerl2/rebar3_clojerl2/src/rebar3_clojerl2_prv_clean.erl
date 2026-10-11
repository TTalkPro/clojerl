%%%-------------------------------------------------------------------
%%% @doc `rebar3 clojerl2 clean': remove the compile cache and the
%%% modules clojerl2 builds wrote to the apps' ebin dirs.
%%%-------------------------------------------------------------------
-module(rebar3_clojerl2_prv_clean).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, clean).

init(State) ->
    Provider = providers:create([{namespace, rebar3_clojerl2_utils:namespace()},
                                 {name, ?PROVIDER},
                                 {module, ?MODULE},
                                 {bare, true},
                                 {deps, [{default, app_discovery}]},
                                 {example, "rebar3 clojerl2 clean"},
                                 {opts, []},
                                 {short_desc, "Remove clojerl2 build output and cache"},
                                 {desc, "Remove _build/<profile>/clojerl2_cache and the modules "
                                        "clojerl2 wrote to the apps' ebin dirs."}]),
    {ok, rebar_state:add_provider(State, Provider)}.

do(State) ->
    Cache = rebar3_clojerl2_utils:cache_dir(State),
    rebar_api:info("Removing ~ts", [Cache]),
    _ = case filelib:is_dir(Cache) of
            true -> file:del_dir_r(Cache);
            false -> ok
        end,
    [clean_ebin(rebar_app_info:ebin_dir(A)) || A <- rebar_state:project_apps(State)],
    {ok, State}.

%% the modules listed in the build manifest (clj2_build)
clean_ebin(Ebin) ->
    Manifest = filename:join(Ebin, "clj2_build.manifest"),
    case file:consult(Manifest) of
        {ok, [Mods]} ->
            [file:delete(filename:join(Ebin, atom_to_list(M) ++ ".beam")) || M <- Mods],
            file:delete(Manifest);
        _ -> ok
    end.

format_error(Reason) -> rebar3_clojerl2_utils:format_error(Reason).
