%%%-------------------------------------------------------------------
%%% @doc clj2_build — project builds with a compile cache (designs/02 §6,
%%% clojerl2-024). The rebar3 plugin (rebar3_clojerl2) drives this; it
%%% does not need rebar3.
%%%
%%% A build finds the namespace files (.clj, .cljc) under the source
%%% dirs, orders them by their `(ns ... (:require ...))' dependencies,
%%% and for each namespace either takes its modules from the cache or
%%% compiles it; either way they are loaded (a namespace's dependents
%%% compile against it) and written to the ebin dir.
%%%
%%% Cache key, per namespace:
%%%   sha256(source) + compiler fingerprint + OTP major + options
%%%   + the interface of each namespace it requires
%%% The compiler fingerprint covers the compiler's modules and
%%% clojure.core (whose macros shape every expansion). A required
%%% namespace's interface is what a dependent's code is compiled
%%% against: its vars' kinds, arities, dynamic/private flags (direct
%%% linking, designs/03 §2.1) and, when it defines macros, the code they
%%% can run while expanding: the macro functions and every function of
%%% their module they reach, as abstract code without line numbers
%%% (debug_info). So changing a fn body or a docstring
%%% recompiles that namespace only; changing an arity or a macro also
%%% recompiles its dependents. extend-type compiles into impl modules of
%%% the extending namespace (D9): nothing else is recompiled.
%%%
%%% Cache layout: `<cache_dir>/<key>/' holding the modules' .beam files
%%% and `modules' (their names, impl modules first). Entries are written
%%% to a temporary dir and renamed into place.
%%%-------------------------------------------------------------------
-module(clj2_build).

-export([build/1, clean/1, scan/1, compiler_fingerprint/0, ensure_core/1]).

-define(KEY_VERSION, 1).
-define(MANIFEST, "clj2_build.manifest").

%% @doc Build a project. Opts: src_dirs ([Dir]), ebin_dir, cache_dir,
%% compile_opts (#{mode => dev | release}), log (fun(Fmt, Args)).
%% → #{compiled => [Ns], cached => [Ns], removed => [Module], ms => N}
build(Opts) ->
    T0 = erlang:monotonic_time(millisecond),
    #{src_dirs := SrcDirs, ebin_dir := Ebin, cache_dir := Cache} = Opts,
    CompileOpts = maps:get(compile_opts, Opts, #{}),
    Log = maps:get(log, Opts, fun(_, _) -> ok end),
    ok = filelib:ensure_path(Ebin),
    ok = filelib:ensure_path(Cache),
    put({?MODULE, cache_dir}, Cache),
    clj2_rt_eval:set_source_path(SrcDirs),
    {ok, _} = ensure_core(Cache),
    Fp = compiler_fingerprint(),
    Nses = order(scan(SrcDirs)),
    Results = [build_ns(N, Fp, CompileOpts, Ebin, Cache, Log) || N <- Nses],
    Written = lists:append([Mods || {_, _, Mods} <- Results]),
    Removed = prune(Ebin, Written),
    #{compiled => [Ns || {compiled, Ns, _} <- Results],
      cached => [Ns || {cached, Ns, _} <- Results],
      removed => Removed,
      ms => erlang:monotonic_time(millisecond) - T0}.

%% @doc Remove the cache.
clean(CacheDir) ->
    case filelib:is_dir(CacheDir) of
        true -> file:del_dir_r(CacheDir);
        false -> ok
    end.

%%====================================================================
%% Finding and ordering namespaces
%%====================================================================

%% @doc The namespace files under `SrcDirs': [#{ns, file, requires, src}].
%% Files that do not start with an `ns' form (scripts) are skipped.
scan(SrcDirs) ->
    Files = lists:usort([F || D <- SrcDirs, Ext <- ["clj", "cljc"],
                              F <- filelib:wildcard(filename:join([D, "**", "*." ++ Ext]))]),
    lists:append([ns_file(F) || F <- Files]).

ns_file(File) ->
    {ok, Src} = file:read_file(File),
    case clj2_reader:read(Src) of                     % the first form only
        {ok, First, _, _} ->
            case clj2_form:to_data(First) of
                [ns, Ns | Clauses] when is_atom(Ns) ->
                    [#{ns => Ns, file => File, src => Src, requires => requires(Clauses)}];
                _ -> []
            end;
        _ -> []
    end.

%% the namespaces named by (:require ...) / (:use ...) clauses
requires(Clauses) ->
    lists:usort(
      [Ns || [K | Specs] <- Clauses, K =:= ':require' orelse K =:= ':use',
             Spec <- Specs, Ns <- libspec_ns(Spec)]).

libspec_ns(Ns) when is_atom(Ns), Ns =/= nil -> [Ns];
libspec_ns({vector, _, _} = V) ->
    case clj2_coll:to_list(V) of
        [Ns | _] when is_atom(Ns) -> [Ns];
        _ -> []
    end;
libspec_ns(_) -> [].

%% dependencies first; a cycle among project namespaces is an error
order(Nses) ->
    G = digraph:new(),
    try
        Known = maps:from_list([{Ns, N} || N = #{ns := Ns} <- Nses]),
        [digraph:add_vertex(G, Ns) || Ns <- maps:keys(Known)],
        [digraph:add_edge(G, R, Ns) || #{ns := Ns, requires := Rs} <- Nses, R <- Rs,
                                       maps:is_key(R, Known), R =/= Ns],
        case digraph_utils:topsort(G) of
            false ->
                Cyc = [C || C <- digraph_utils:cyclic_strong_components(G)],
                erlang:error({clj2_build, {cyclic_requires, Cyc}});
            Sorted -> [maps:get(Ns, Known) || Ns <- Sorted]
        end
    after
        digraph:delete(G)
    end.

%%====================================================================
%% One namespace
%%====================================================================

build_ns(#{ns := Ns, file := File, src := Src, requires := Reqs}, Fp, CompileOpts, Ebin, Cache, Log) ->
    [clj2_rt_eval:ensure_loaded(R) || R <- Reqs],
    Key = key(Src, Fp, CompileOpts, [interface(R) || R <- Reqs]),
    Entry = filename:join(Cache, Key),
    case read_entry(Entry) of
        {ok, Mods} ->
            load(Ns, Mods),
            write_ebin(Ebin, Mods),
            {cached, Ns, [M || {M, _} <- Mods]};
        error ->
            Log("Compiling ~ts~n", [Ns]),
            Mods = case clj2_compiler:compile_ns_modules(Src, CompileOpts#{file => File}) of
                       {ok, Ns, Ms} -> Ms;
                       {ok, Other, _} -> erlang:error({clj2_build, {ns_name_mismatch, File, Other}});
                       {error, Es, _} -> erlang:error({clj2_build, {lint, File, Es}})
                   end,
            write_entry(Entry, Mods),
            load(Ns, Mods),
            write_ebin(Ebin, Mods),
            {compiled, Ns, [M || {M, _} <- Mods]}
    end.

key(Src, Fp, CompileOpts, Ifaces) ->
    Term = {?KEY_VERSION, crypto:hash(sha256, Src), Fp, erlang:system_info(otp_release),
            lists:sort(maps:to_list(maps:without([file], CompileOpts))), Ifaces},
    hex(crypto:hash(sha256, term_to_binary(Term, [deterministic]))).

%% What a dependent is compiled against (see the module doc).
interface(Ns) ->
    case clj2_ns:info(Ns) of
        {ok, #{module := M, vars := Vars}} ->
            Iface = lists:sort([{N, lists:sort(maps:to_list(maps:without([doc, module], I)))}
                                || {N, I} <- maps:to_list(Vars)]),
            Macros = lists:usort([{maps:get(module, I, M), N} || {N, I} <- maps:to_list(Vars),
                                                                 maps:get(macro, I, false)]),
            ByMod = maps:groups_from_list(fun({MM, _}) -> MM end, fun({_, N}) -> N end, Macros),
            {Ns, Iface, [{MM, macro_digest(MM, Names)} || {MM, Names} <- lists:sort(maps:to_list(ByMod))]};
        error -> {Ns, missing}
    end.

%% The abstract code of functions `Names' (any arity) and of every local
%% function they reach, annotations erased; the module's md5 when it has
%% no debug_info. Memoized on disk by the module's md5 (decoding
%% debug_info is most of a fully cached build otherwise).
macro_digest(M, Names) ->
    Memo = filename:join([get({?MODULE, cache_dir}), "digests",
                          hex(crypto:hash(sha256, term_to_binary({md5(M), lists:sort(Names)})))]),
    case file:read_file(Memo) of
        {ok, D} -> D;
        {error, _} ->
            D = macro_digest1(M, Names),
            ok = filelib:ensure_dir(Memo),
            _ = file:write_file(Memo, D),
            D
    end.

macro_digest1(M, Names) ->
    case abstract_code(M) of
        {ok, Forms} ->
            Funs = maps:from_list([{{F, A}, erl_parse:map_anno(fun(_) -> 0 end, Form)}
                                   || {function, _, F, A, _} = Form <- Forms]),
            Start = [FA || {F, _} = FA <- maps:keys(Funs), lists:member(F, Names)],
            Reached = reach(Start, Funs, #{}),
            crypto:hash(sha256, term_to_binary(lists:sort(maps:to_list(Reached)), [deterministic]));
        error -> md5(M)
    end.

reach([], _Funs, Acc) -> Acc;
reach([FA | Rest], Funs, Acc) when is_map_key(FA, Acc) -> reach(Rest, Funs, Acc);
reach([FA | Rest], Funs, Acc) ->
    case Funs of
        #{FA := Form} -> reach(local_refs(Form) ++ Rest, Funs, Acc#{FA => Form});
        _ -> reach(Rest, Funs, Acc)
    end.

%% local calls and local fun references in a form
local_refs({call, _, {atom, _, F}, Args} = T) -> [{F, length(Args)} | subterm_refs(T)];
local_refs({'fun', _, {function, F, A}}) when is_atom(F), is_integer(A) -> [{F, A}];
local_refs(T) -> subterm_refs(T).

subterm_refs(T) when is_tuple(T) -> lists:append([local_refs(X) || X <- tuple_to_list(T)]);
subterm_refs(L) when is_list(L) -> lists:append([local_refs(X) || X <- L]);
subterm_refs(_) -> [].

abstract_code(M) ->
    Bin = case code:get_object_code(M) of
              {M, B, _} -> B;
              error -> get({?MODULE, beam, M})        % loaded by this build
          end,
    try
        {ok, {M, [{debug_info, {debug_info_v1, Backend, Data}}]}} = beam_lib:chunks(Bin, [debug_info]),
        {ok, Forms} = Backend:debug_info(erlang_v1, M, Data, []),
        {ok, Forms}
    catch _:_ -> error
    end.

md5(M) ->
    case code:ensure_loaded(M) of
        {module, M} -> M:module_info(md5);
        _ -> none
    end.

%% @doc The compiler's identity for cache keys: its modules' and
%% clojure.core's code (md5), so rebuilding the compiler or changing core
%% invalidates every entry.
compiler_fingerprint() ->
    Dir = filename:dirname(code:which(clj2_compiler)),
    Mods = [list_to_atom(filename:basename(F, ".beam"))
            || F <- filelib:wildcard(filename:join(Dir, "clj2_*.beam")),
               not lists:suffix("_tests.beam", F)],
    crypto:hash(sha256, term_to_binary(lists:sort([{M, md5(M)} || M <- ['clojure.core' | Mods]]))).

%%====================================================================
%% clojure.core
%%====================================================================

%% @doc clojure.core loaded: prebuilt on the code path, else from the
%% cache, else compiled from source and cached (keyed by its sources and
%% the compiler's own modules).
ensure_core(Cache) ->
    case code:which('clojure.core') of
        non_existing ->
            Dir = clj2_core:source_dir(),
            Srcs = [file:read_file(F) || F <- lists:sort(filelib:wildcard(filename:join(Dir, "*")))],
            Fp0 = compiler_fingerprint_without_core(),
            Entry = filename:join(Cache, "core-" ++ hex(crypto:hash(sha256, term_to_binary({?KEY_VERSION, Srcs, Fp0, erlang:system_info(otp_release)})))),
            case read_entry(Entry) of
                {ok, Mods} ->
                    load('clojure.core', Mods),
                    {ok, 'clojure.core'};
                error ->
                    case clj2_core:build_modules() of
                        {ok, Ns, Mods} ->
                            write_entry(Entry, Mods),
                            load(Ns, Mods),
                            {ok, Ns};
                        {error, _} = E -> E
                    end
            end;
        _ -> clj2_core:ensure()
    end.

compiler_fingerprint_without_core() ->
    Dir = filename:dirname(code:which(clj2_compiler)),
    crypto:hash(sha256, term_to_binary(lists:sort(
        [{F, element(2, beam_lib:md5(F))} || F <- filelib:wildcard(filename:join(Dir, "clj2_*.beam")),
                                             not lists:suffix("_tests.beam", F)]))).

%%====================================================================
%% Cache entries, loading, ebin
%%====================================================================

read_entry(Dir) ->
    case file:consult(filename:join(Dir, "modules")) of
        {ok, [Mods]} ->
            Beams = [{M, file:read_file(filename:join(Dir, atom_to_list(M) ++ ".beam"))} || M <- Mods],
            case [ok || {_, {error, _}} <- Beams] of
                [] -> {ok, [{M, Bin} || {M, {ok, Bin}} <- Beams]};
                _ -> error
            end;
        _ -> error
    end.

write_entry(Dir, Mods) ->
    Tmp = Dir ++ ".tmp" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = filelib:ensure_path(Tmp),
    [ok = file:write_file(filename:join(Tmp, atom_to_list(M) ++ ".beam"), Bin) || {M, Bin} <- Mods],
    ok = file:write_file(filename:join(Tmp, "modules"), io_lib:format("~p.~n", [[M || {M, _} <- Mods]])),
    case file:rename(Tmp, Dir) of
        ok -> ok;
        {error, _} -> file:del_dir_r(Tmp)      % a concurrent build wrote it first
    end.

%% impl modules first, the namespace module last (its top-level forms may
%% dispatch to them while it loads), as clj2_compiler:load_ns does
load(Ns, Mods) ->
    lists:foreach(
      fun({M, Bin}) ->
              put({?MODULE, beam, M}, Bin),
              code:soft_purge(M) orelse erlang:error({clj2_build, {old_code_in_use, M}}),
              case code:load_binary(M, atom_to_list(M) ++ ".clj", Bin) of
                  {module, M} -> ok;
                  {error, on_load_failure} ->
                      Why = case clj2_ns:take_init_failure(Ns) of
                                {ok, R} -> R;
                                error -> on_load_failure
                            end,
                      erlang:error({clj2_build, {load_failed, Ns, Why}});
                  {error, Why} -> erlang:error({clj2_build, {load_failed, M, Why}})
              end
      end, Mods).

write_ebin(Ebin, Mods) ->
    [begin
         F = filename:join(Ebin, atom_to_list(M) ++ ".beam"),
         case file:read_file(F) of
             {ok, Bin} -> ok;                         % unchanged
             _ -> ok = file:write_file(F, Bin)
         end
     end || {M, Bin} <- Mods],
    ok.

%% Delete the modules an earlier build wrote to ebin that this one did not
%% (a removed namespace, a dropped extend-type). → the removed modules
prune(Ebin, Written) ->
    Manifest = filename:join(Ebin, ?MANIFEST),
    Before = case file:consult(Manifest) of
                 {ok, [L]} -> L;
                 _ -> []
             end,
    Gone = Before -- Written,
    [file:delete(filename:join(Ebin, atom_to_list(M) ++ ".beam")) || M <- Gone],
    ok = file:write_file(Manifest, io_lib:format("~p.~n", [lists:usort(Written)])),
    Gone.

hex(Bin) -> binary_to_list(binary:encode_hex(Bin, lowercase)).
