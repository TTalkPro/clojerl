%%%-------------------------------------------------------------------
%%% @doc clj2_rt_eval — evaluation at run time (clojerl2-023): the
%%% current namespace (*ns*), in-ns, eval, read-string, load-string,
%%% macroexpand and require, for clojure.core and the REPL.
%%%
%%% *ns* is the dynamic var clojure.core/*ns* (root `user'); in-ns sets
%%% this process's binding of it, so each REPL process has its own
%%% current namespace (dynamic bindings are per process, designs/03 §3).
%%% A namespace is a symbol here, not a Namespace object.
%%%
%%% load-file evaluates a file form at a time, like the REPL (a script
%%% need not be a namespace). require compiles a namespace file into its
%%% module (load_ns), from the source path: `foo.bar-baz' is
%%% `foo/bar_baz.clj' (or .cljc) under one of its directories
%%% (set_source_path/1; default ["src", "."]).
%%%-------------------------------------------------------------------
-module(clj2_rt_eval).

-export([current_ns/0, set_current_ns/1, in_ns/1, save_ns/0, restore_ns/1]).
-export([eval/1, read_string/1, load_string/1, macroexpand_1/1, macroexpand/1]).
-export([require/1, ensure_loaded/1, load_file/1, load_ns_file/1,
         source_path/0, set_source_path/1, find_source/1]).

-define(NS_KEY, {clj2_dyn, 'clojure.core', '*ns*'}).

%%====================================================================
%% The current namespace
%%====================================================================

current_ns() ->
    case get(?NS_KEY) of
        [Ns | _] -> Ns;
        _ -> try clj2_var:root('clojure.core', '*ns*')
             catch error:_ -> user
             end
    end.

%% Replace this process's binding of *ns* (establish one if none).
set_current_ns(Ns) when is_atom(Ns) ->
    case get(?NS_KEY) of
        [_ | Outer] -> put(?NS_KEY, [Ns | Outer]);
        _ -> put(?NS_KEY, [Ns])
    end,
    ok.

%% @doc (in-ns 'foo): switch to `foo', creating it when it does not exist.
in_ns(Ns) when is_atom(Ns) ->
    clj2_ns:ensure(Ns),
    set_current_ns(Ns),
    Ns.

save_ns() -> get(?NS_KEY).

restore_ns(undefined) -> erase(?NS_KEY), ok;
restore_ns(Saved) -> put(?NS_KEY, Saved), ok.

%%====================================================================
%% eval and friends
%%====================================================================

%% @doc (eval form), in the current namespace.
eval(Form) -> clj2_compiler:eval({forms, [clj2_form:from_value(Form)]}).

%% @doc (read-string s): the first form of `s' as data.
read_string(S) when is_binary(S) ->
    case clj2_reader:read_all(S) of
        {ok, [F | _], _} -> clj2_form:to_data(F);
        {ok, [], _} -> erlang:error({clj2_read, <<"EOF while reading">>});
        {error, Where, Msg} -> erlang:error({clj2_read, Where, Msg})
    end.

%% @doc (load-string s): evaluate every form; the last value.
load_string(S) when is_binary(S) -> clj2_compiler:eval(S).

macroexpand_1(Form) -> clj2_compiler:macroexpand_1(clj2_form:from_value(Form), current_ns()).

macroexpand(Form) ->
    case macroexpand_1(Form) of
        Form -> Form;
        X -> macroexpand(X)
    end.

%%====================================================================
%% require
%%====================================================================

%% @doc (require & args): each arg a namespace symbol or a libspec vector
%% `[ns :as alias :refer [syms] | :all]'; a bare `:reload' reloads them.
%% Aliases and refers are added to the current namespace.
require(Args) ->
    Specs = clj2_coll:to_list(Args),
    Reload = lists:member(':reload', Specs) orelse lists:member(':reload-all', Specs),
    Cur = current_ns(),
    lists:foreach(
      fun(Flag) when Flag =:= ':reload'; Flag =:= ':reload-all' -> ok;
         (Spec) ->
              {Ns, Opts} = libspec(Spec),
              load(Ns, Reload orelse maps:is_key(':reload', Opts)),
              Aliases = case Opts of
                            #{':as' := As} -> #{As => Ns};
                            _ -> #{}
                        end,
              Refers = case Opts of
                           #{':refer' := ':all'} -> maps:from_keys(public_names(Ns), Ns);
                           #{':refer' := Syms} -> maps:from_keys(clj2_coll:to_list(Syms), Ns);
                           _ -> #{}
                       end,
              case Ns =:= Cur orelse (Aliases =:= #{} andalso Refers =:= #{}) of
                  true -> ok;
                  false -> clj2_ns:put_ctx(Cur, Aliases, Refers)
              end
      end, Specs),
    nil.

libspec(Ns) when is_atom(Ns) -> {Ns, #{}};
libspec(Spec) ->
    case clj2_coll:to_list(Spec) of
        [Ns | Rest] when is_atom(Ns) -> {Ns, opts(Rest, #{})};
        _ -> erlang:error({clj2_require, {bad_libspec, Spec}})
    end.

opts([K, V | Rest], Acc) -> opts(Rest, Acc#{K => V});
opts([':reload' | Rest], Acc) -> opts(Rest, Acc#{':reload' => true});
opts([], Acc) -> Acc;
opts(Bad, _) -> erlang:error({clj2_require, {bad_libspec_options, Bad}}).

public_names(Ns) ->
    case clj2_ns:info(Ns) of
        {ok, #{vars := Vars}} -> [N || {N, I} <- maps:to_list(Vars), not maps:get(private, I, false)];
        error -> []
    end.

load(Ns, Reload) ->
    case not Reload andalso clj2_ns:info(Ns) =/= error of
        true -> ok;
        false ->
            case find_source(Ns) of
                {ok, Path} -> load_ns_file(Path);
                error -> erlang:error({clj2_require, {not_found, Ns, source_path() -- [stdlib_dir()]}})
            end
    end.

%% @doc Load `Ns' from the source path unless it is already known;
%% quietly does nothing when there is no source for it (the caller
%% reports the missing namespace).
ensure_loaded(Ns) ->
    case clj2_ns:info(Ns) of
        {ok, _} -> ok;
        error ->
            case find_source(Ns) of
                {ok, Path} -> load_ns_file(Path);
                error -> ok
            end
    end.

%% @doc (load-file path): evaluate the file's forms in order, in the
%% current namespace (an `ns' form switches it). The last value.
load_file(Path) ->
    {ok, Bin} = file:read_file(Path),
    clj2_compiler:eval(Bin, #{file => unicode:characters_to_list(Path)}).

%% @doc Compile and load a namespace source file. → the namespace.
load_ns_file(Path) ->
    {ok, Bin} = file:read_file(Path),
    try clj2_compiler:load_ns(Bin, #{file => unicode:characters_to_list(Path)}) of
        {ok, Ns} -> Ns;
        {error, Why} -> erlang:error({clj2_load, Path, Why})
    catch
        %% a compile error names its place in the file (the innermost
        %% file, when the error is in a namespace this one requires)
        error:{clj2_compile, {L, C}, Why2} when is_integer(L) ->
            erlang:error({clj2_compile, {Path, {L, C}}, Why2})
    end.

%% the user's directories, then clojerl2's own standard library
%% (priv/clj2/stdlib: clojure.string ...), which is always searched
source_path() ->
    persistent_term:get({?MODULE, source_path}, ["src", "."]) ++ [stdlib_dir()].

stdlib_dir() ->
    filename:join([filename:dirname(code:which(?MODULE)), "..", "priv", "clj2", "stdlib"]).

set_source_path(Dirs) ->
    persistent_term:put({?MODULE, source_path}, [unicode:characters_to_list(D) || D <- Dirs]).

%% @doc `foo.bar-baz' → the first existing `<dir>/foo/bar_baz.clj[c]'.
find_source(Ns) ->
    Rel = [case C of $. -> $/; $- -> $_; _ -> C end || C <- atom_to_list(Ns)],
    Cands = [filename:join(D, Rel ++ Ext) || D <- source_path(), Ext <- [".clj", ".cljc"]],
    case [P || P <- Cands, filelib:is_regular(P)] of
        [P | _] -> {ok, P};
        [] -> error
    end.
