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
-export([alias/2]).
-export([req_refers/1, refer/2, refer_clojure/1]).
-export([resolve/2, ns_publics/1, ns_interns/1, ns_map/1, ns_aliases/1, ns_refers/1,
         find_var/1, intern/2, intern/3, intern_value/2, ns_unmap/2, remove_ns/1,
         requiring_resolve/1]).
-export([require/1, load_specs/2, ensure_loaded/1, load_file/1, load_ns_file/1,
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

%% @doc (in-ns 'foo): switch to `foo', creating it when it does not exist
%% -- bare, as on the JVM: it refers nothing until a refer-clojure.
in_ns(Ns) when is_atom(Ns) ->
    clj2_ns:ensure(Ns, bare),
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
        {ok, [F | _], _} -> clj2_p_parse:data_form(F, current_ns());
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
    Cur = current_ns(),
    {Aliases, Refers} = load_specs(Args, Cur),
    case Aliases =:= #{} andalso Refers =:= #{} of
        true -> ok;
        false -> clj2_ns:put_ctx(Cur, Aliases, Refers)
    end,
    nil.

%% @doc Load what (require ...) names and → {Aliases, Refers} it adds to
%% namespace Cur, without recording them (the compiler runs a top-level
%% require at compile time and keeps them in its own context).
load_specs(Args, Cur) ->
    Specs = clj2_coll:to_list(Args),
    Reload = lists:member(':reload', Specs) orelse lists:member(':reload-all', Specs),
    lists:foldl(
      fun(Flag, Acc) when Flag =:= ':reload'; Flag =:= ':reload-all' -> Acc;
         (Spec, {AAcc, RAcc}) ->
              {Ns, Opts} = libspec(Spec),
              load(Ns, Reload orelse maps:is_key(':reload', Opts)),
              Aliases = case Opts of
                            #{':as' := As} when Ns =/= Cur -> #{As => Ns};
                            _ -> #{}
                        end,
              Refers = case Opts of
                           _ when Ns =:= Cur -> #{};
                           #{':refer' := ':all'} -> req_refers(#{ns => Ns, refer => all, rename => rename_opt(Opts)});
                           #{':refer' := Syms} ->
                               req_refers(#{ns => Ns, refer => clj2_coll:to_list(Syms), rename => rename_opt(Opts)});
                           _ -> #{}
                       end,
              {maps:merge(AAcc, Aliases), maps:merge(RAcc, Refers)}
      end, {#{}, #{}}, Specs).

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

rename_opt(#{':rename' := M}) -> maps:from_list([{K, V} || [K, V] <- [clj2_coll:to_list(P) || P <- clj2_coll:to_list(M)]]);
rename_opt(_) -> #{}.

%% @doc What a libspec's :refer (a list, or `all') maps in the namespace
%% that requires it: Sym => Target (clj2_ns refer targets). A name the
%% namespace does not have, or has private, is the JVM's
%% IllegalAccessError.
req_refers(#{ns := R, refer := Ss} = Req) ->
    _ = ensure_loaded(R),
    clj2_ns:refer_map(R, #{only => Ss, rename => maps:get(rename, Req, #{}),
                           exclude => maps:get(exclude, Req, [])}, strict).

%% @doc (refer ns-sym & filters): maps the public vars of ns-sym (the
%% filters :exclude, :only and :rename select and rename them) into the
%% current namespace. Referring clojure.core is refer-clojure.
refer(NsSym, Filters) when is_atom(NsSym) ->
    Spec = refer_spec(clj2_coll:to_list(Filters)),
    Cur = current_ns(),
    case NsSym of
        'clojure.core' ->
            _ = clj2_ns:refer_map('clojure.core', Spec, strict),
            clj2_ns:add_core_refer(Cur, Spec);
        _ ->
            clj2_ns:info(NsSym) =/= error orelse
                erlang:error(clj2_rt:ex_info(<<"No namespace: ", (atom_to_binary(NsSym))/binary>>,
                                             clj2_coll:hash_map_kv([':type', ':Exception']), nil)),
            clj2_ns:put_ctx(Cur, #{}, clj2_ns:refer_map(NsSym, Spec, strict))
    end,
    nil.

%% @doc (refer-clojure & filters)
refer_clojure(Filters) -> refer('clojure.core', Filters).

refer_spec(Fs) -> refer_spec(Fs, #{}).
refer_spec([], Spec) -> Spec;
refer_spec([':exclude', L | Rest], Spec) -> refer_spec(Rest, Spec#{exclude => clj2_coll:to_list(L)});
refer_spec([':only', L | Rest], Spec) ->
    is_seqable(L) orelse illegal_argument(<<"Arg to refer must be sequential">>),
    refer_spec(Rest, Spec#{only => clj2_coll:to_list(L)});
refer_spec([':refer', ':all' | Rest], Spec) -> refer_spec(Rest, Spec);
refer_spec([':refer', L | Rest], Spec) -> refer_spec([':only', L | Rest], Spec);
refer_spec([':rename', M | Rest], Spec) -> refer_spec(Rest, Spec#{rename => rename_opt(#{':rename' => M})});
refer_spec([_K, _V | Rest], Spec) -> refer_spec(Rest, Spec);
refer_spec(_, Spec) -> Spec.

is_seqable(L) -> is_list(L) orelse clj2_coll:is_vector(L) orelse
                     (is_tuple(L) andalso element(1, L) =:= lazy_seq).

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

%% @doc (alias 'a 'some.ns): a names some.ns in the current namespace
alias(As, Ns) ->
    clj2_ns:info(Ns) =/= error orelse erlang:error({clj2_require, {not_found, Ns, source_path()}}),
    clj2_ns:put_ctx(current_ns(), #{As => Ns}, #{}),
    nil.

%%====================================================================
%% Namespace reflection (resolve, ns-publics ...)
%%====================================================================

%% @doc (ns-resolve ns sym): the var `sym' names in `ns' -- its own, one
%% it refers, one reached through an alias, or clojure.core's public one
%% -- as the compiler would resolve it; a class for a class name; else
%% nil. The namespace is a symbol (there are no Namespace objects).
resolve(Ns, Sym) when is_atom(Ns), is_atom(Sym) ->
    case string:split(atom_to_list(Sym), "/") of
        [[_ | _] = Q, [_ | _] = N] ->
            QA = list_to_atom(Q),
            var_of(maps:get(QA, ctx(Ns, aliases), QA), list_to_atom(N));
        _ ->
            case var_of(Ns, Sym) of
                nil ->
                    case maps:find(Sym, clj2_ns:refers(Ns)) of
                        {ok, T} ->
                            {RNs, RName} = clj2_ns:refer_target(Sym, T),
                            var_of(RNs, RName);
                        error ->
                            case clj2_class:resolve(Sym) of
                                {ok, C} -> C;
                                error -> nil
                            end
                    end;
                V -> V
            end
    end.

%% the var Ns/Name, or nil
var_of(Ns, Name) ->
    case clj2_ns:info(Ns) of
        {ok, #{vars := #{Name := _}}} -> clj2_rt:var(Ns, Name);
        _ -> nil
    end.

ctx(Ns, Key) ->
    case clj2_ns:info(Ns) of
        {ok, E} -> maps:get(Key, E, #{});
        error -> #{}
    end.

vars_of(Ns, Pred) ->
    case clj2_ns:info(Ns) of
        {ok, #{vars := Vars}} -> [{N, clj2_rt:var(Ns, N)} || {N, I} <- lists:sort(maps:to_list(Vars)), Pred(I)];
        error -> []
    end.

sym_map(Pairs) -> clj2_coll:hash_map_kv(lists:append([[K, V] || {K, V} <- Pairs])).

%% @doc (ns-publics ns): symbol → var of the public vars
ns_publics(Ns) -> sym_map(vars_of(Ns, fun(I) -> not maps:get(private, I, false) end)).

%% @doc (ns-interns ns): symbol → var of every var
ns_interns(Ns) -> sym_map(vars_of(Ns, fun(_) -> true end)).

%% @doc (ns-aliases ns): alias symbol → namespace symbol
ns_aliases(Ns) -> sym_map(maps:to_list(ctx(Ns, aliases))).

%% @doc (ns-refers ns): symbol → var of what `ns' refers, clojure.core's
%% public vars (the implicit refer-clojure) included
ns_refers(Ns) -> sym_map(refer_pairs(Ns)).

refer_pairs(Ns) ->
    [{S, clj2_rt:var(RNs, RName)} || {S, T} <- maps:to_list(clj2_ns:refers(Ns)),
                                     {RNs, RName} <- [clj2_ns:refer_target(S, T)]].



%% @doc (ns-map ns): the refers under the interns
ns_map(Ns) ->
    sym_map(maps:to_list(maps:merge(maps:from_list(refer_pairs(Ns)),
                                    maps:from_list(vars_of(Ns, fun(_) -> true end))))).

%% @doc (find-var 'ns/name): the var, nil when the namespace has no such
%% var; an unqualified symbol or an unknown namespace is an
%% IllegalArgumentException
find_var(Sym) when is_atom(Sym) ->
    case string:split(atom_to_list(Sym), "/") of
        [[_ | _] = Q, [_ | _] = N] ->
            Ns = list_to_atom(Q),
            case clj2_ns:info(Ns) of
                {ok, _} -> var_of(Ns, list_to_atom(N));
                error -> illegal_argument(<<"No such namespace: ", (atom_to_binary(Ns))/binary>>)
            end;
        _ -> illegal_argument(<<"Symbol must be namespace-qualified">>)
    end.

illegal_argument(Msg) ->
    erlang:error(clj2_rt:ex_info(Msg, clj2_coll:hash_map_kv([':type', ':IllegalArgumentException']), nil)).

%% @doc (intern ns name) / (intern ns name val): a var in `ns', as (def
%% name val) evaluated there would make it, so it compiles and links
%% like any other. The value travels through the var table: a module's
%% init cannot take a closure as a literal.
intern(Ns, Name) when is_atom(Ns), is_atom(Name) ->
    clj2_ns:ensure(Ns),
    _ = clj2_compiler:eval({forms, [[def, Name]]}, #{ns => Ns}),
    clj2_rt:var(Ns, Name).

intern(Ns, Name, Val) when is_atom(Ns), is_atom(Name) ->
    clj2_ns:ensure(Ns),
    Key = erlang:unique_integer([positive]),
    clj2_var:set_root({intern, Key}, Name, Val),
    _ = clj2_compiler:eval({forms, [[def, Name, ['clj2_rt_eval/intern_value', Key, [quote, Name]]]]}, #{ns => Ns}),
    clj2_rt:var(Ns, Name).

%% @private the value an interned var's init takes (once)
intern_value(Key, Name) ->
    clj2_var:take_root({intern, Key}, Name).

%% @doc (ns-unmap ns sym): the var is gone from the namespace
ns_unmap(Ns, Name) when is_atom(Ns), is_atom(Name) ->
    clj2_ns:remove_var(Ns, Name),
    nil.

%% @doc (remove-ns sym): the namespace symbol when it existed, else nil
remove_ns(Ns) when is_atom(Ns) ->
    case clj2_ns:find_ns(Ns) of
        true -> clj2_ns:remove(Ns), Ns;
        false -> nil
    end.

%% @doc (requiring-resolve 'ns/name): resolve, loading the namespace
%% when it is not loaded yet; an unqualified symbol is an
%% IllegalArgumentException
requiring_resolve(Sym) when is_atom(Sym) ->
    case string:split(atom_to_list(Sym), "/") of
        [[_ | _] = Q, [_ | _]] ->
            case resolve(current_ns(), Sym) of
                nil ->
                    load(list_to_atom(Q), false),
                    resolve(current_ns(), Sym);
                V -> V
            end;
        _ -> illegal_argument(<<"Not a qualified symbol: ", (atom_to_binary(Sym))/binary>>)
    end.
