%%%-------------------------------------------------------------------
%%% @doc rebar3_clojerl2 — rebar3 plugin for clojerl2 projects
%%% (clojerl2-024). Command surface as rebar3_clojerl's, under the
%%% `clojerl2' namespace:
%%%
%%%   rebar3 clojerl2 compile   build the project's namespaces (cached)
%%%   rebar3 clojerl2 repl      a clojerl2 REPL on the project's code path
%%%   rebar3 clojerl2 clean     drop the compile cache and the built modules
%%%
%%% rebar.config: `{clj2_src_dirs, ["src"]}' (where namespaces are,
%%% per app; like rebar3_clojerl's clje_src_dirs), `{clj2_mode, dev |
%%% release}'. The project must depend on clojerl2 (its runtime).
%%%-------------------------------------------------------------------
-module(rebar3_clojerl2).

-export([init/1]).

init(State0) ->
    lists:foldl(fun(Init, {ok, S}) -> Init(S) end, {ok, State0},
                [fun rebar3_clojerl2_prv_compile:init/1,
                 fun rebar3_clojerl2_prv_repl:init/1,
                 fun rebar3_clojerl2_prv_clean:init/1]).
