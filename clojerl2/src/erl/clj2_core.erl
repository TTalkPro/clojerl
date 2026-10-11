%%%-------------------------------------------------------------------
%%% @doc clj2_core — loads clojure.core from its layers (designs/04 §6,
%%% clojerl2-014).
%%%
%%% `core/boot-order.edn' declares the layers, their files, the layers
%%% each depends on, and which namespaces each may use. clojure.core is
%%% one namespace and so one module: the selected layers' forms are
%%% compiled together, in declared order, form at a time (macros defined
%%% in a layer are usable by the forms after them).
%%%
%%% Lint: a layer's `:allowed-ns' is enforced by the compiler
%%% (`allowed_ns'); the kernel's is [] — only Erlang modules.
%%%-------------------------------------------------------------------
-module(clj2_core).

-export([boot/0, boot/1, ensure/0, build/1, layers/0, layer_vars/0, source_dir/0]).

%% @doc Compile and load clojure.core (all layers).
boot() -> boot(#{}).

%% Opts: `upto' — the last layer to load (e.g. '00-kernel'); `dir' —
%% where the sources are; plus compiler options (mode, check).
boot(Opts) ->
    {Src, CompileOpts} = source(Opts),
    clj2_compiler:load_ns(Src, CompileOpts).

%% @doc clojure.core, loaded: the prebuilt modules on the code path
%% (`make' writes them to ebin/, build/1) when they are there, else
%% compiled from source (boot/0). The CLI starts with this.
ensure() ->
    case code:ensure_loaded('clojure.core') of
        {module, _} -> {ok, 'clojure.core'};          % its on_load registered it
        {error, _} -> boot()
    end.

%% @doc Compile clojure.core (all layers) and write its modules — the
%% namespace module and its protocol impl modules — as .beam files to
%% `Dir'. Impl modules load on first dispatch (clj2_proto).
build(Dir) ->
    {Src, CompileOpts} = source(#{}),
    case clj2_compiler:compile_ns_modules(Src, CompileOpts) of
        {ok, Ns, Mods} ->
            [ok = file:write_file(filename:join(Dir, atom_to_list(M) ++ ".beam"), Bin) || {M, Bin} <- Mods],
            {ok, Ns, [M || {M, _} <- Mods]};
        {error, Es, _} -> {error, Es}
    end.

source(Opts) ->
    Dir = maps:get(dir, Opts, source_dir()),
    #{ns := Ns, layers := Layers} = boot_order(Dir),
    Selected = select(Layers, maps:get(upto, Opts, all)),
    Forms = lists:append([layer_forms(Dir, L, I) || {I, L} <- enumerate(Selected)]),
    Allowed = lists:usort(lists:append([A || #{allowed_ns := A} <- Selected])),
    {{forms, Forms},
     (maps:without([dir, upto], Opts))#{allowed_ns => Allowed,
                                        %% core is below clojure.core
                                        refer_clojure => false,
                                        file => "clojure/core.clj",
                                        ns => Ns}}.

%% @doc The declared layers, in load order.
layers() ->
    #{layers := Ls} = boot_order(source_dir()),
    [N || #{name := N} <- Ls].

%% @doc The layer that defines each clojure.core var (a top-level def*
%% form), as #{Sym => Layer}; a later layer's redefinition wins. Used to
%% tag corpus entries by layer (designs/04 §5.2).
layer_vars() ->
    Dir = source_dir(),
    #{layers := Layers} = boot_order(Dir),
    maps:from_list([{Name, N} || {I, #{name := N} = L} <- enumerate(Layers),
                                 F <- layer_forms(Dir, L, I),
                                 Name <- defined(F)]).

defined(F) ->
    case unloc(F) of
        [H, Nm | _] ->
            case {unloc(H), unloc(Nm)} of
                {Def, Sym} when is_atom(Def), is_atom(Sym) ->
                    case atom_to_list(Def) of
                        "def" ++ _ -> [Sym];
                        _ -> []
                    end;
                _ -> []
            end;
        _ -> []
    end.

unloc({clj2_loc, _, _, F, _}) -> F;
unloc(F) -> F.

source_dir() ->
    filename:join([filename:dirname(code:which(?MODULE)), "..", "src", "clj2", "core"]).

%%====================================================================
%% boot-order.edn
%%====================================================================

boot_order(Dir) ->
    {ok, Bin} = file:read_file(filename:join(Dir, "boot-order.edn")),
    {ok, [Form], _} = clj2_reader:read_all(Bin),
    Edn = clj2_form:to_data(Form),
    Ns = clj2_coll:get(Edn, ':ns'),
    Layers = [layer(L) || L <- clj2_coll:to_list(clj2_coll:get(Edn, ':layers'))],
    check_order(Layers),
    #{ns => Ns, layers => Layers}.

layer(L) ->
    #{name => kw_name(clj2_coll:get(L, ':name')),
      files => [binary_to_list(F) || F <- clj2_coll:to_list(clj2_coll:get(L, ':files'))],
      deps => [kw_name(D) || D <- clj2_coll:to_list(clj2_coll:get(L, ':deps'))],
      allowed_ns => clj2_coll:to_list(clj2_coll:get(L, ':allowed-ns', clj2_coll:vector([])))}.

kw_name(K) -> binary_to_atom(clj2_rt:name(K)).

%% every dependency must be declared earlier: no implicit file order
check_order(Layers) ->
    lists:foldl(fun(#{name := N, deps := Ds}, Seen) ->
                        [erlang:error({clj2_boot_order, {N, depends_on_later_or_unknown, D}})
                         || D <- Ds, not lists:member(D, Seen)],
                        [N | Seen]
                end, [], Layers),
    ok.

select(Layers, all) -> Layers;
select(Layers, Upto) ->
    case lists:splitwith(fun(#{name := N}) -> N =/= Upto end, Layers) of
        {Before, [Last | _]} -> Before ++ [Last];
        {_, []} -> erlang:error({clj2_boot_order, {unknown_layer, Upto}})
    end.

enumerate(L) -> lists:zip(lists:seq(1, length(L)), L).

%% Forms of a layer; only the very first file keeps its `ns' form, the
%% others must open with (in-ns 'clojure.core), which is dropped.
layer_forms(Dir, #{files := Files}, LayerIndex) ->
    lists:append(
      [begin
           Path = filename:join(Dir, F),
           {ok, Bin} = file:read_file(Path),
           {ok, Forms, _} = clj2_reader:read_all(Bin, #{file => Path}),
           case {LayerIndex, FileIndex} of
               {1, 1} -> Forms;
               _ -> drop_in_ns(Path, Forms)
           end
       end || {FileIndex, F} <- enumerate(Files)]).

drop_in_ns(Path, [F | Rest]) ->
    case clj2_form:to_data(F) of
        ['in-ns', [quote, _]] -> Rest;
        _ -> erlang:error({clj2_boot_order, {missing_in_ns, Path}})
    end.
