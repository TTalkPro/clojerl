%%%-------------------------------------------------------------------
%%% @doc Shared by the rebar3_clojerl2 providers.
%%%-------------------------------------------------------------------
-module(rebar3_clojerl2_utils).

-export([namespace/0, add_code_paths/1, ensure_clojerl2/0, apps/1, src_dirs/1,
         cache_dir/1, build/2, format_error/1]).

namespace() -> clojerl2.

%% deps and project apps on the code path (the compiler, the runtime and
%% whatever the project's namespaces call)
add_code_paths(State) ->
    ok = code:add_pathsa(rebar_state:code_paths(State, all_deps)),
    ok = code:add_pathsa([rebar_app_info:ebin_dir(A) || A <- rebar_state:project_apps(State)]).

ensure_clojerl2() ->
    case code:ensure_loaded(clj2_build) of
        {module, _} ->
            [{ok, _} = application:ensure_all_started(A) || A <- [crypto, compiler]],
            ok;
        _ -> throw({error, {rebar3_clojerl2_utils, clojerl2_missing}})
    end.

%% The apps whose namespaces are built: the project's, and any dep that
%% configures clj2_src_dirs (a clojerl2 library). clojerl2 itself is not
%% one (clojure.core is built by its own loader).
apps(State) ->
    Deps = [A || A <- rebar_state:all_deps(State),
                 rebar_app_info:name(A) =/= <<"clojerl2">>,
                 rebar_app_info:get(A, clj2_src_dirs, undefined) =/= undefined],
    {ok, Ordered} = rebar_digraph:compile_order(Deps),
    Ordered ++ rebar_state:project_apps(State).

src_dirs(App) ->
    Dir = rebar_app_info:dir(App),
    [filename:join(Dir, D) || D <- rebar_app_info:get(App, clj2_src_dirs, ["src"])].

%% _build/<profile>/clojerl2_cache (designs/02 §6)
cache_dir(State) -> filename:join(rebar_dir:base_dir(State), "clojerl2_cache").

build(App, State) ->
    Mode = rebar_app_info:get(App, clj2_mode, dev),
    clj2_build:build(#{src_dirs => src_dirs(App),
                       ebin_dir => rebar_app_info:ebin_dir(App),
                       cache_dir => cache_dir(State),
                       compile_opts => #{mode => Mode},
                       log => fun(F, A) -> rebar_api:info("  " ++ F, A) end}).

format_error(clojerl2_missing) ->
    "clojerl2 is not on the code path: add it to the project's deps";
format_error({build_failed, App, C, R, S}) ->
    Report = try clj2_repl:format_error(C, R, S)
             catch _:_ -> io_lib:format("~tp", [R])
             end,
    io_lib:format("clojerl2 build of ~ts failed:~n~ts", [App, Report]);
format_error(Reason) -> io_lib:format("~tp", [Reason]).
