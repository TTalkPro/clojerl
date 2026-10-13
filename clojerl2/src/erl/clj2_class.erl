%%%-------------------------------------------------------------------
%%% @doc clj2_class — the JVM class model behind class, type, instance?,
%%% supers, bases and catch-by-class (clojerl2, aligning with Clojure).
%%%
%%% A class is its fully qualified name as a symbol: (class 1) is
%%% java.lang.Long, (class []) clojure.lang.PersistentVector, a record
%%% ns.Name. The graph of direct supers comes from
%%% priv/clj2/class-hierarchy.eterm (jolt's model of the JVM hierarchy,
%%% EPL-2.0); records and deftypes are added as they are asked about.
%%% Ancestry closures are memoized in persistent_term (the graph does not
%%% change after load).
%%%
%%% Exceptions: an Erlang error has a class too — badarith is
%%% java.lang.ArithmeticException, an ex-info clojure.lang.ExceptionInfo
%%% (or the JVM class its :type names, for the runtime's own errors) — so
%%% (catch ArithmeticException e ...) can select by class.
%%%-------------------------------------------------------------------
-module(clj2_class).

-export([class_of/1, type_of/1, is_instance/2, supers/1, bases/1, is_class/1,
         resolve/1, resolve_simple/1, ancestry/1, exception_class/1, exception_matches/2,
         is_subclass/2, supers_list/1]).

%%====================================================================
%% Values → classes
%%====================================================================

class_of(nil) -> nil;
class_of(B) when is_boolean(B) -> 'java.lang.Boolean';
class_of(I) when is_integer(I), I >= -16#8000000000000000, I =< 16#7FFFFFFFFFFFFFFF -> 'java.lang.Long';
class_of(I) when is_integer(I) -> 'clojure.lang.BigInt';
class_of(F) when is_float(F) -> 'java.lang.Double';
class_of(B) when is_binary(B) -> 'java.lang.String';
class_of(A) when is_atom(A) ->
    case clj2_rt:is_keyword(A) of
        true -> 'clojure.lang.Keyword';
        false -> 'clojure.lang.Symbol'
    end;
class_of([]) -> 'clojure.lang.PersistentList$EmptyList';
class_of(L) when is_list(L) -> 'clojure.lang.PersistentList';
class_of(F) when is_function(F) -> 'clojure.lang.AFunction';
class_of(P) when is_pid(P) -> 'java.lang.Thread';
class_of({lazy_seq, _, _}) -> 'clojure.lang.LazySeq';
class_of({vector, _, T}) when is_tuple(T) -> 'clojure.lang.PersistentVector';
class_of({map, _, M}) when is_map(M), map_size(M) =< 8 -> 'clojure.lang.PersistentArrayMap';
class_of({map, _, M}) when is_map(M) -> 'clojure.lang.PersistentHashMap';
class_of({set, _, M}) when is_map(M) -> 'clojure.lang.PersistentHashSet';
class_of({sorted_map, _, {_, _, _}}) -> 'clojure.lang.PersistentTreeMap';
class_of({sorted_set, _, {_, _, _}}) -> 'clojure.lang.PersistentTreeSet';
class_of({ratio, _, _}) -> 'clojure.lang.Ratio';
class_of({decimal, _, _}) -> 'java.math.BigDecimal';
class_of({'java.util.Date', _, Ms}) when is_integer(Ms) -> 'java.util.Date';
class_of({clj2_fn, _, _}) -> 'clojure.lang.AFunction';
class_of({fnmeta, _, _}) -> 'clojure.lang.AFunction';
class_of({clj2_reduced, _}) -> 'clojure.lang.Reduced';
class_of({atom, _, _}) -> 'clojure.lang.Atom';
class_of({volatile, _, _}) -> 'clojure.lang.Volatile';
class_of({agent, _, _}) -> 'clojure.lang.Agent';
class_of({delay, _, _}) -> 'clojure.lang.Delay';
class_of({var, _, _}) -> 'clojure.lang.Var';
class_of({regex, _, _}) -> 'java.util.regex.Pattern';
class_of({uuid, _, _}) -> 'java.util.UUID';
class_of({multifn, _, _}) -> 'clojure.lang.MultiFn';
class_of({array, _, {atom, _, _}} = A) -> clj2_array:class_of(A);
class_of({local_var, _, _}) -> 'clojure.lang.Var';
class_of({transient, _, {vector, _, _}}) -> 'clojure.lang.PersistentVector$TransientVector';
class_of({transient, _, {map, _, _}}) -> 'clojure.lang.PersistentHashMap$TransientHashMap';
class_of({transient, _, _}) -> 'clojure.lang.PersistentHashSet$TransientHashSet';
class_of({'clojure.lang.ExceptionInfo', _, _} = E) -> exception_class(E);
class_of({Host, nil, _}) when Host =:= 'java.lang.Thread'; Host =:= 'java.util.Iterator';
                              Host =:= 'java.util.concurrent.ExecutorService';
                              Host =:= 'java.util.concurrent.FutureTask' -> Host;
class_of({Tag, _, M}) when is_atom(Tag), is_map(M) -> Tag;                % a record
class_of({Tag, _, T}) when is_atom(Tag), is_tuple(T) -> Tag;              % a deftype
class_of(_) -> 'java.lang.Object'.

%% @doc (type x): the :type metadata, else the class
type_of(X) ->
    case clj2_rt:meta(X) of
        {map, _, #{':type' := T}} -> T;
        _ -> class_of(X)
    end.

%%====================================================================
%% The graph
%%====================================================================

graph() ->
    case persistent_term:get({?MODULE, graph}, undefined) of
        undefined ->
            File = filename:join([filename:dirname(code:which(?MODULE)), "..", "priv", "clj2", "class-hierarchy.eterm"]),
            {ok, Terms} = file:consult(File),
            G = maps:from_list([{binary_to_atom(N), [binary_to_atom(S) || S <- Ss]} || {class, N, Ss} <- Terms]),
            %% interfaces: declared ones, and any super only named as one
            I = maps:from_list([{binary_to_atom(N), true} || {interface, N} <- Terms]
                               ++ [{S, true} || Ss <- maps:values(G), S <- Ss, not is_map_key(S, G)]),
            persistent_term:put({?MODULE, graph}, {G, I}),
            {G, I};
        GI -> GI
    end.

%% a record or deftype: its supers as the JVM gives them
direct(C) ->
    {G, _} = graph(),
    case G of
        #{C := Ss} -> Ss;
        _ ->
            case record_or_type(C) of
                record -> clj2_proto:declared_interfaces(C) ++ ['clojure.lang.IRecord', 'clojure.lang.IPersistentMap', 'clojure.lang.IHashEq',
                           'clojure.lang.IObj', 'clojure.lang.ILookup', 'clojure.lang.IKeywordLookup',
                           'java.util.Map', 'java.io.Serializable', 'java.lang.Object'];
                deftype -> clj2_proto:declared_interfaces(C) ++ ['clojure.lang.IType', 'java.lang.Object'];
                none -> case C of 'java.lang.Object' -> []; _ -> ['java.lang.Object'] end
            end
    end.

%% a class name that is not in the graph: a record or a deftype when a
%% constructor ->Name is defined in namespace ns (for ns.Name)
record_or_type(C) ->
    Str = atom_to_list(C),
    case string:split(Str, ".", trailing) of
        [Ns, Name] when Ns =/= "" ->
            case clj2_ns:info(list_to_atom(Ns)) of
                {ok, #{vars := Vars}} ->
                    case {is_map_key(list_to_atom("map->" ++ Name), Vars), is_map_key(list_to_atom("->" ++ Name), Vars)} of
                        {true, _} -> record;
                        {false, true} -> deftype;
                        _ -> none
                    end;
                error -> none
            end;
        _ -> none
    end.

%% @doc (supers c): every class and interface above c
supers(C) when not is_atom(C) -> #{};
supers(C) ->
    Key = {?MODULE, supers, C},
    case persistent_term:get(Key, undefined) of
        undefined ->
            S = closure(direct(C), #{}),
            case record_or_type(C) of
                none -> persistent_term:put(Key, S);           % records may be redefined
                _ -> ok
            end,
            S;
        S -> S
    end.

closure([], Acc) -> Acc;
closure([C | Rest], Acc) when is_map_key(C, Acc) -> closure(Rest, Acc);
closure([C | Rest], Acc) -> closure(direct(C) ++ Rest, Acc#{C => true}).

%% @doc c and everything above it, nearest first (breadth-first), for
%% protocol dispatch on a class or interface
ancestry(nil) -> [];
ancestry(C) -> bfs([C], #{C => true}, []).

bfs([], _, Acc) -> lists:reverse(Acc);
bfs([C | Q], Seen, Acc) ->
    New = [S || S <- direct(C), not is_map_key(S, Seen)],
    bfs(Q ++ New, maps:merge(Seen, maps:from_keys(New, true)), [C | Acc]).

bases(C) when is_atom(C) -> direct(C);
bases(_) -> [].

%% @doc (instance? c x)
is_instance(_, nil) -> false;
is_instance(C, X) ->
    XC = class_of(X),
    XC =:= C orelse C =:= 'java.lang.Object' orelse is_map_key(C, supers(XC)).

%% @doc Is c a class this model knows (or a record/deftype)?
is_class(C) when is_atom(C) ->
    {G, I} = graph(),
    is_map_key(C, G) orelse is_map_key(C, I) orelse record_or_type(C) =/= none;
is_class(_) -> false.

supers_list(C) -> maps:keys(supers(C)).

%% @doc (isa? Child Parent) for classes: Parent is Child or one of its
%% supers (Class.isAssignableFrom)
is_subclass(C, P) when is_atom(C), is_atom(P), C =/= nil, P =/= nil ->
    is_class(C) andalso is_class(P) andalso is_map_key(P, supers(C));
is_subclass(_, _) -> false.

%% @doc A symbol in code that names a class → that class, or error. Bare
%% names are java.lang's (imported by default), clojure.lang's are not.
resolve(S) ->
    {G, I} = graph(),
    Known = fun(C) -> is_map_key(C, G) orelse is_map_key(C, I) end,
    case Known(S) of
        true -> {ok, S};
        false ->
            Lang = list_to_atom("java.lang." ++ atom_to_list(S)),
            case Known(Lang) of
                true -> {ok, Lang};
                %% Clojure's default imports beyond java.lang
                false when S =:= 'BigDecimal'; S =:= 'BigInteger' ->
                    {ok, list_to_atom("java.math." ++ atom_to_list(S))};
                false -> error
            end
    end.

%% @doc A class by a bare name: java.lang's, else the one class anywhere
%% with that simple name (Map → java.util.Map)
resolve_simple(S) -> by_simple_name(S).

%% a class by its simple name (IllegalFormatConversionException →
%% java.util.IllegalFormatConversionException), when one class has it
by_simple_name(S) ->
    Index = case persistent_term:get({?MODULE, simple}, undefined) of
                undefined ->
                    {G, I} = graph(),
                    %% Compiler$CompilerException is also CompilerException
                    Pairs = lists:usort([{N, C} || C <- maps:keys(G) ++ maps:keys(I),
                                                   N <- lists:usort([simple(C), inner(simple(C))])]),
                    Ix = maps:from_list([{N, [C || {N1, C} <- Pairs, N1 =:= N]} || {N, _} <- Pairs]),
                    persistent_term:put({?MODULE, simple}, Ix),
                    Ix;
                Ix -> Ix
            end,
    case Index of
        #{S := [C]} -> {ok, C};
        _ -> resolve(S)
    end.

inner(S) ->
    case string:split(atom_to_list(S), "$", trailing) of
        [_, In] when In =/= "" -> list_to_atom(In);
        _ -> S
    end.

simple(C) ->
    [Last | _] = lists:reverse(string:split(atom_to_list(C), ".", all)),
    list_to_atom(Last).

%%====================================================================
%% Exceptions
%%====================================================================

%% @doc The JVM class of a caught error reason
exception_class({'clojure.lang.ExceptionInfo', _, #{':data' := {map, _, #{':type' := T}}}}) when is_atom(T) ->
    %% the runtime's own errors name the JVM class they stand for
    case clj2_rt:is_keyword(T) andalso by_simple_name(list_to_atom(tl(atom_to_list(T)))) of
        {ok, C} -> C;
        _ -> 'clojure.lang.ExceptionInfo'
    end;
exception_class({'clojure.lang.ExceptionInfo', _, _}) -> 'clojure.lang.ExceptionInfo';
exception_class({clj2_compile, _, _}) -> 'clojure.lang.Compiler$CompilerException';
exception_class({clj2_read, _}) -> 'clojure.lang.LispReader$ReaderException';
exception_class(badarith) -> 'java.lang.ArithmeticException';
exception_class({badarith, _}) -> 'java.lang.ArithmeticException';
exception_class(badarg) -> 'java.lang.IllegalArgumentException';
exception_class({badarg, _}) -> 'java.lang.IllegalArgumentException';
exception_class(function_clause) -> 'java.lang.IllegalArgumentException';
exception_class({case_clause, _}) -> 'java.lang.IllegalArgumentException';
exception_class({badmatch, _}) -> 'java.lang.IllegalArgumentException';
exception_class({clj2_index_out_of_bounds, nil}) -> 'java.lang.NullPointerException';
exception_class({clj2_index_out_of_bounds, _}) -> 'java.lang.IndexOutOfBoundsException';
exception_class(R) when element(1, R) =:= clj2_string_index_out_of_bounds -> 'java.lang.StringIndexOutOfBoundsException';
exception_class({clj2_cannot_compare, _, _}) -> 'java.lang.ClassCastException';
exception_class({clj2_not_derefable, nil}) -> 'java.lang.NullPointerException';
exception_class({clj2_not_derefable, _}) -> 'java.lang.ClassCastException';
exception_class({clj2_not_pending, _}) -> 'java.lang.ClassCastException';
exception_class({clj2_not_seqable, _}) -> 'java.lang.IllegalArgumentException';
exception_class({clj2_not_countable, _}) -> 'java.lang.UnsupportedOperationException';
exception_class({clj2_not_ifn, _}) -> 'java.lang.ClassCastException';
exception_class({clj2_arity, _, _}) -> 'clojure.lang.ArityException';
exception_class({clj2_cannot_assoc, _, _}) -> 'java.lang.ClassCastException';
exception_class({clj2_cannot_conj, _, _}) -> 'java.lang.ClassCastException';
exception_class({clj2_unbound_var, _, _}) -> 'java.lang.IllegalStateException';
exception_class({badkey, _}) -> 'java.lang.IllegalArgumentException';
exception_class({badmap, _}) -> 'java.lang.ClassCastException';
exception_class(undef) -> 'java.lang.RuntimeException';
exception_class(_) -> 'java.lang.RuntimeException'.

%% @doc Does a caught error reason belong to class C? (Throwable and
%% Exception take everything; the compiler maps catch clauses to this.)
exception_matches(C, Reason) ->
    C =:= 'java.lang.Throwable' orelse C =:= 'java.lang.Exception' orelse
        begin
            EC = exception_class(Reason),
            EC =:= C orelse is_map_key(C, supers(EC))
        end.
