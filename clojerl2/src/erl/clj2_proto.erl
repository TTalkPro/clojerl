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

-export([type_method/3, object_method/2, extend_tag/1, new_table/0
        , type_tag/1
        , designator/2
        , impl_module/2
        , impl/2
        , dispatch/4
        , loaded/3, loaded/4
        , satisfies/2
        , is_type_value/1
        , record/3
        , record_field/2
        , record_fields/1
        , extend_fns/3
        , extenders/1
        , declared_interfaces/1
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
type_tag(M) when is_map(M) -> map;
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
                        false ->
                            %% a type of Ns, else a JVM class or interface
                            %% (Map, Number, IPersistentVector ...):
                            %% dispatch finds it among the value's supers
                            Own = list_to_atom(atom_to_list(Ns) ++ "." ++ atom_to_list(S)),
                            case clj2_class:is_class(Own) orelse clj2_class:resolve_simple(S) of
                                {ok, C} -> C;
                                _ -> Own
                            end
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
    case find_impl(Protocol, This) of
        {ok, {fns, Fns}} ->
            case Fns of
                #{Method := F} -> clj2_rt:invoke(F, [This | Args]);
                _ -> no_impl(Protocol, Method, This)
            end;
        {ok, Mod} -> erlang:apply(Mod, Method, [This | Args]);
        error -> no_impl(Protocol, Method, This)
    end.

%% @doc (extend Type Proto {:m (fn ...) ...}) at run time: the impl is the
%% map of fns, kept in the dispatch table like a loaded impl module
extend_fns(TypeVal, ProtoVal, MethodMap) ->
    clj2_ns:ensure_started(),
    Protocol = clj2_coll:get(ProtoVal, ':name'),
    Fns = maps:from_list([{binary_to_atom(clj2_rt:name(K)), F}
                          || {vector, _, {K, F}} <- clj2_coll:to_list(MethodMap)]),
    Tag = extend_tag(TypeVal),
    true = ets:insert(?TAB, {{Protocol, Tag}, {ok, {fns, Fns}}}),
    true = ets:match_delete(?TAB, {{via, Protocol, '_'}, '_'}),
    nil.

%% @doc The dispatch tag of a type value as extend and extends? take it:
%% a class, or its simple name ((extend 'String P {...}))
extend_tag(TypeVal) ->
    Class = case is_atom(TypeVal) andalso TypeVal =/= nil andalso clj2_class:resolve(TypeVal) of
                {ok, C} -> C;
                _ -> TypeVal
            end,
    tag_of_class(Class).

%% @doc (extenders P): the types with an impl of P, as classes
extenders(ProtoVal) ->
    Protocol = clj2_coll:get(ProtoVal, ':name'),
    [class_of_tag(Tag) || {{P, Tag}, {ok, _}} <- ets:tab2list(?TAB), P =:= Protocol,
                          not ets:member(?TAB, {inline, P, Tag})].

%% a class value (or nil) as extend-type would name it → its dispatch tag
tag_of_class(nil) -> nil;
tag_of_class(C) ->
    case [T || {T, Cls} <- tag_classes(), Cls =:= C] of
        [T | _] -> T;
        [] -> C
    end.

class_of_tag(T) ->
    case lists:keyfind(T, 1, tag_classes()) of
        {_, C} -> C;
        false -> T
    end.

tag_classes() ->
    [{string, 'java.lang.String'}, {integer, 'java.lang.Long'}, {float, 'java.lang.Double'},
     {boolean, 'java.lang.Boolean'}, {keyword, 'clojure.lang.Keyword'}, {symbol, 'clojure.lang.Symbol'},
     {default, 'java.lang.Object'}, {vector, 'clojure.lang.PersistentVector'},
     {map, 'clojure.lang.PersistentArrayMap'}, {map, 'clojure.lang.PersistentHashMap'},
     {set, 'clojure.lang.PersistentHashSet'}, {list, 'clojure.lang.PersistentList'},
     {lazy_seq, 'clojure.lang.LazySeq'}, {fn, 'clojure.lang.AFunction'}, {ratio, 'clojure.lang.Ratio'}].

%% as the JVM words it: "No implementation of method: :area of protocol:
%% #'user/Shape found for class: java.lang.String"
no_impl(Protocol, Method, This) ->
    PStr = atom_to_list(Protocol),
    Dot = string:rchr(PStr, $.),
    Var = [lists:sublist(PStr, Dot - 1), "/", lists:nthtail(Dot, PStr)],
    Class = case clj2_class:class_of(This) of nil -> <<"nil">>; C -> atom_to_binary(C) end,
    erlang:error(clj2_rt:ex_info(
                   iolist_to_binary(["No implementation of method: :", atom_to_binary(Method),
                                     " of protocol: #'", Var, " found for class: ", Class]),
                   clj2_coll:hash_map_kv([':type', ':IllegalArgumentException']), nil)).

%% the impl for x's tag, else for a class or interface above x's class
%% (nearest first; memoized per tag), else the default one
find_impl(Protocol, This) ->
    Tag = type_tag(This),
    case impl(Protocol, Tag) of
        {ok, _} = Ok -> Ok;
        error ->
            case via_class(Protocol, Tag, This) of
                {ok, _} = Ok -> Ok;
                %% nil is no Object: only an impl for nil takes it
                error when This =:= nil -> error;
                error -> impl(Protocol, default)
            end
    end.

via_class(Protocol, Tag, This) ->
    Key = {via, Protocol, Tag},
    case ets:lookup(?TAB, Key) of
        [{_, R}] -> R;
        [] ->
            R = first_impl(Protocol, clj2_class:ancestry(clj2_class:class_of(This))),
            %% a record's tag is its class; other tags may span classes
            %% (array/hash maps share their interfaces)
            ets:insert(?TAB, {Key, R}),
            R
    end.

first_impl(_, []) -> error;
first_impl(Protocol, [C | Cs]) ->
    case impl(Protocol, C) of
        {ok, _} = Ok -> Ok;
        error -> first_impl(Protocol, Cs)
    end.

%% @doc Called by an impl module's on_load: positive entry, replacing
%% any negative one.
loaded(Protocol, Tag, Mod) ->
    clj2_ns:ensure_started(),
    true = ets:insert(?TAB, {{Protocol, Tag}, {ok, Mod}}),
    true = ets:match_delete(?TAB, {{via, Protocol, '_'}, '_'}),      % class lookups may change
    ok.

%% @doc An inline impl (deftype/defrecord's own methods): dispatched like
%% any, but not an extender
loaded(Protocol, Tag, Mod, inline) ->
    clj2_ns:ensure_started(),
    true = ets:insert(?TAB, {{inline, Protocol, Tag}, true}),
    loaded(Protocol, Tag, Mod).

satisfies(Protocol, X) -> find_impl(Protocol, X) =/= error.

%% @doc The JVM interfaces a deftype/defrecord Tag declares (it has an
%% impl under the interface's name): supers of the type
declared_interfaces(Tag) ->
    try
        load_impls(Tag),
        [P || {{P, T}, {ok, _}} <- ets:tab2list(?TAB), T =:= Tag, clj2_class:is_class(P)]
    catch error:badarg -> []
    end.

%% a type's impl modules on the code path (`<P>__<Tag>') not loaded yet
%% (a library's types: they load on first dispatch), loaded once
load_impls(Tag) ->
    case ets:member(?TAB, {impls_loaded, Tag}) of
        true -> ok;
        false ->
            Suffix = "__" ++ atom_to_list(Tag),
            [code:ensure_loaded(list_to_atom(M)) || {M, _, false} <- code:all_available(),
                                                    lists:suffix(Suffix, M)],
            ets:insert(?TAB, {{impls_loaded, Tag}, true}),
            ok
    end.

%% @doc (.m x args) on a deftype or defrecord: the method m of a protocol
%% (or interface) its type implements, as a JVM class's method is
%% {ok, Result} | error
type_method(X, Method, Args) ->
    Tag = type_tag(X),
    is_atom(Tag) andalso lists:member($., atom_to_list(Tag)) andalso load_impls(Tag),
    Arity = length(Args) + 1,
    Impls = [I || {{_P, T}, {ok, I}} <- ets:tab2list(?TAB), T =:= Tag],
    call_first(Impls, Method, Arity, [X | Args]).

call_first([], _, _, _) -> error;
call_first([{fns, Fns} | Rest], M, Arity, All) ->
    case Fns of
        #{M := F} -> {ok, clj2_rt:invoke(F, All)};
        _ -> call_first(Rest, M, Arity, All)
    end;
call_first([Mod | Rest], M, Arity, All) when is_atom(Mod) ->
    _ = code:ensure_loaded(Mod),
    case erlang:function_exported(Mod, M, Arity) of
        true -> {ok, erlang:apply(Mod, M, All)};
        false -> call_first(Rest, M, Arity, All)
    end;
call_first([_ | Rest], M, Arity, All) -> call_first(Rest, M, Arity, All).

%% @doc A deftype/defrecord's own Object method (toString, hashCode,
%% equals) → {ok, Fun} taking the value (and the other arguments)
object_method({Tag, _, _} = X, Method) when is_atom(Tag) ->
    case binary:match(atom_to_binary(Tag), <<".">>) =/= nomatch andalso find_impl('java.lang.Object', X) of
        {ok, {fns, Fns}} -> case Fns of #{Method := F} -> {ok, F}; _ -> error end;
        {ok, Mod} when is_atom(Mod) ->
            case [A || {M, A} <- Mod:module_info(exports), M =:= Method] of
                [Ar | _] -> {ok, erlang:make_fun(Mod, Method, Ar)};
                [] -> error
            end;
        _ -> error
    end;
object_method(_, _) -> error.

%%====================================================================
%% deftype / defrecord values
%%====================================================================

is_type_value({Tag, _, _}) when is_atom(Tag) ->
    not lists:member(Tag, [vector, map, set, clj2_fn, ratio, lazy_seq, delay]);
is_type_value(_) -> false.

%% @doc A record of type Tag: declared fields (keywords, in order) from
%% a value list, plus any extra entries of the map Ext.
record(Tag, Fields, Values) when is_list(Values) ->
    note_fields(Tag, Fields),
    {Tag, nil, maps:from_list(lists:zip(Fields, Values))};
record(Tag, Fields, {map, _, M}) ->
    note_fields(Tag, Fields),
    {Tag, nil, M}.

%% the declared fields of each record type, for dissoc (a declared field
%% removed makes a plain map); written once per definition
note_fields(Tag, Fields) ->
    Key = {clj2_record_fields, Tag},
    case persistent_term:get(Key, undefined) of
        Fields -> ok;
        _ -> persistent_term:put(Key, Fields)
    end.

%% @doc A record type's declared fields (keywords), [] when unknown
record_fields(Tag) -> persistent_term:get({clj2_record_fields, Tag}, []).

record_field({_Tag, _, M}, K) when is_map(M) -> maps:get(K, M, nil);
record_field({_Tag, _, T}, I) when is_tuple(T) -> element(I, T).
