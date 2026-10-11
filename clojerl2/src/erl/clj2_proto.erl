%%%-------------------------------------------------------------------
%%% @doc clj2_proto — protocol runtime (designs/03 §4, D9, clojerl2-016).
%%%
%%% A protocol method call is
%%%
%%%   dispatch(Protocol, Method, This, Args) ->
%%%       Mod = impl(Protocol, type_tag(This)) (else the `default' impl),
%%%       apply(Mod, Method, [This | Args])
%%%
%%% where Mod is the impl module `<Protocol>__<Tag>' compiled by
%%% `extend-type'. Extending compiles and loads only that module: the
%%% protocol and every other impl stay untouched (no clojerl 1.0 O(n²)
%%% recompilation). Spike 002 measured this shape at 0.61× a direct
%%% remote call (threshold 1/3).
%%%
%%% Existence cache: ETS `clj2_proto' {{Protocol, Tag}, {ok, Mod} | none}.
%%% A miss probes `code:ensure_loaded' (an impl module on the code path
%%% registers itself) and stores a negative entry; an impl module's
%%% on_load calls `loaded/3', which overwrites any negative entry, so an
%%% extend made after a failed lookup is seen at once (03 §9 open
%%% question 3).
%%%
%%% Type tags: built-in values map to fixed tags (`type_tag/1'); a
%%% deftype/defrecord value `{Tag, Meta, Fields}' carries its own,
%%% the namespace-qualified type name.
%%%-------------------------------------------------------------------
-module(clj2_proto).

-export([ new_table/0
        , type_tag/1
        , designator/2
        , impl_module/2
        , impl/2
        , dispatch/4
        , loaded/3
        , satisfies/2
        , is_type_value/1
        , record/3
        , record_field/2
        ]).

-define(TAB, clj2_proto).

%% @private created by the clj2_ns server, which owns it
new_table() ->
    ?TAB = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]).

%%====================================================================
%% Types
%%====================================================================

-define(BUILTIN, [nil, boolean, keyword, symbol, integer, float, string, list,
                  lazy_seq, delay, vector, map, set, fn, ratio, tuple, pid, reference,
                  port, default]).

%% @doc The dispatch tag of a value.
type_tag(nil) -> nil;
type_tag(true) -> boolean;
type_tag(false) -> boolean;
type_tag(X) when is_atom(X) ->
    case clj2_rt:is_keyword(X) of
        true -> keyword;
        false -> symbol
    end;
type_tag(X) when is_integer(X) -> integer;
type_tag(X) when is_float(X) -> float;
type_tag(X) when is_binary(X) -> string;
type_tag(X) when is_list(X) -> list;
type_tag(X) when is_function(X) -> fn;
type_tag({vector, _, T}) when is_tuple(T) -> vector;
type_tag({map, _, M}) when is_map(M) -> map;
type_tag({set, _, M}) when is_map(M) -> set;
type_tag({clj2_fn, _, _}) -> fn;
type_tag({ratio, _, _}) -> ratio;
type_tag({lazy_seq, _, _}) -> lazy_seq;
type_tag({delay, _, _}) -> delay;
type_tag({Tag, _, _}) when is_atom(Tag) -> Tag;      % deftype / defrecord
type_tag(X) when is_tuple(X) -> tuple;
type_tag(X) when is_pid(X) -> pid;
type_tag(X) when is_reference(X) -> reference;
type_tag(X) when is_port(X) -> port.

%% @doc The tag a type designator in `extend-type' names, in namespace
%% Ns: a built-in tag (`string', `vector', ... `default'), a JVM-style
%% alias (String, Long, Object ...), a qualified type name (`a.b.T'), or
%% a type defined in Ns (`T' → `Ns.T').
designator(S, Ns) ->
    case lists:member(S, ?BUILTIN) of
        true -> S;
        false ->
            case jvm_alias(S) of
                none ->
                    case lists:member($., atom_to_list(S)) of
                        true -> S;
                        false -> list_to_atom(atom_to_list(Ns) ++ "." ++ atom_to_list(S))
                    end;
                T -> T
            end
    end.

jvm_alias('Object') -> default;
jvm_alias('String') -> string;
jvm_alias('Long') -> integer;
jvm_alias('Integer') -> integer;
jvm_alias('Double') -> float;
jvm_alias('Boolean') -> boolean;
jvm_alias('Keyword') -> keyword;
jvm_alias('Symbol') -> symbol;
jvm_alias(_) -> none.

impl_module(Protocol, Tag) ->
    list_to_atom(atom_to_list(Protocol) ++ "__" ++ atom_to_list(Tag)).

%%====================================================================
%% Dispatch
%%====================================================================

%% @doc The impl module of Protocol for Tag, through the cache.
impl(Protocol, Tag) ->
    Key = {Protocol, Tag},
    try ets:lookup_element(?TAB, Key, 2) of
        {ok, _} = Ok -> Ok;
        none -> error
    catch
        error:badarg -> probe(Protocol, Tag, Key)
    end.

probe(Protocol, Tag, Key) ->
    clj2_ns:ensure_started(),
    Mod = impl_module(Protocol, Tag),
    case code:ensure_loaded(Mod) of
        {module, Mod} -> {ok, Mod};               % its on_load filled the cache
        {error, _} ->
            %% insert_new: never overwrite an entry a concurrent load just made
            _ = ets:insert_new(?TAB, {Key, none}),
            case ets:lookup_element(?TAB, Key, 2) of
                {ok, _} = Ok -> Ok;
                none -> error
            end
    end.

dispatch(Protocol, Method, This, Args) ->
    Tag = type_tag(This),
    case impl(Protocol, Tag) of
        {ok, Mod} -> erlang:apply(Mod, Method, [This | Args]);
        error ->
            case impl(Protocol, default) of
                {ok, Mod} -> erlang:apply(Mod, Method, [This | Args]);
                error -> erlang:error({clj2_no_protocol_impl, Protocol, Method, Tag})
            end
    end.

%% @doc Called by an impl module's on_load: positive entry, replacing
%% any negative one.
loaded(Protocol, Tag, Mod) ->
    clj2_ns:ensure_started(),
    true = ets:insert(?TAB, {{Protocol, Tag}, {ok, Mod}}),
    ok.

satisfies(Protocol, X) ->
    impl(Protocol, type_tag(X)) =/= error orelse impl(Protocol, default) =/= error.

%%====================================================================
%% deftype / defrecord values
%%====================================================================

is_type_value({Tag, _, _}) when is_atom(Tag) ->
    not lists:member(Tag, [vector, map, set, clj2_fn, ratio, lazy_seq, delay]);
is_type_value(_) -> false.

%% @doc A record of type Tag: declared fields (keywords, in order) from
%% a value list, plus any extra entries of the map Ext.
record(Tag, Fields, Values) when is_list(Values) ->
    {Tag, nil, maps:from_list(lists:zip(Fields, Values))};
record(Tag, _Fields, {map, _, M}) ->
    {Tag, nil, M}.

record_field({_Tag, _, M}, K) when is_map(M) -> maps:get(K, M, nil);
record_field({_Tag, _, T}, I) when is_tuple(T) -> element(I, T).
