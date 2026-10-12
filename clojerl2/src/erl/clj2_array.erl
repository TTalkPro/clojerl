%%%-------------------------------------------------------------------
%%% @doc clj2_array — Java arrays (long-array, byte-array, into-array,
%%% aget, aset, alength ...), as clojure.core uses them.
%%%
%%% An array is mutable, as on the JVM: `{array, Type, Cell}' where Cell is
%%% a clj2_ref atom holding a tuple of the elements. aget is O(1); aset
%%% copies the tuple (arrays here are for interop-shaped code, not for
%%% speed). Type is long | int | short | byte | char | double | float |
%%% boolean | object | a class; elements of the integer types wrap to
%%% their width when built from numbers (Number.byteValue ...).
%%%-------------------------------------------------------------------
-module(clj2_array).

-export([make/2, make/3, from_seq/2, get/2, set/3, length/1, to_list/1, clone/1,
         is_array/1, class_of/1, type_of_class/1]).

is_array({array, _, {atom, _, _}}) -> true;
is_array(_) -> false.

%% @doc (long-array 3) / (long-array [1 2]) and the like
make(Type, N) when is_integer(N) -> new(Type, lists:duplicate(N, default(Type)));
make(Type, Seq) -> from_seq(Type, Seq).

%% @doc (long-array 3 init-or-seq): size, then a fill value or the leading
%% elements (the rest default)
make(Type, N, X) when is_integer(N) ->
    case X of
        _ when is_number(X); is_boolean(X) -> new(Type, lists:duplicate(N, coerce(Type, X)));
        nil -> new(Type, lists:duplicate(N, default(Type)));
        _ ->
            Given = [coerce(Type, V) || V <- lists:sublist(clj2_coll:to_list(X), N)],
            new(Type, Given ++ lists:duplicate(N - erlang:length(Given), default(Type)))
    end.

from_seq(Type, Seq) -> new(Type, [coerce(Type, V) || V <- clj2_coll:to_list(Seq)]).

new(Type, Elems) -> {array, Type, clj2_ref:atom(list_to_tuple(Elems))}.

get({array, _, Cell}, I) when is_integer(I) ->
    T = clj2_ref:deref(Cell),
    check(I, tuple_size(T)),
    element(I + 1, T);
get(A, I) -> get(A, trunc(I)).

set({array, Type, Cell}, I, V) when is_integer(I) ->
    T = clj2_ref:deref(Cell),
    check(I, tuple_size(T)),
    clj2_ref:reset(Cell, setelement(I + 1, T, store(Type, V))),
    V;
set(A, I, V) -> set(A, trunc(I), V).

length({array, _, Cell}) -> tuple_size(clj2_ref:deref(Cell)).

to_list({array, _, Cell}) -> tuple_to_list(clj2_ref:deref(Cell)).

clone({array, Type, Cell}) -> {array, Type, clj2_ref:atom(clj2_ref:deref(Cell))}.

%% the JVM's names for array classes
class_of({array, long, _}) -> '[J';
class_of({array, int, _}) -> '[I';
class_of({array, short, _}) -> '[S';
class_of({array, byte, _}) -> '[B';
class_of({array, char, _}) -> '[C';
class_of({array, double, _}) -> '[D';
class_of({array, float, _}) -> '[F';
class_of({array, boolean, _}) -> '[Z';
class_of({array, object, _}) -> '[Ljava.lang.Object;';
class_of({array, C, _}) -> list_to_atom("[L" ++ atom_to_list(C) ++ ";").

%% @doc The element type a class names (Long/TYPE, Integer/TYPE ... or a
%% class for an object array)
type_of_class(C) ->
    case C of
        'long' -> long; 'java.lang.Long' -> long;
        'int' -> int; 'java.lang.Integer' -> int;
        'short' -> short; 'java.lang.Short' -> short;
        'byte' -> byte; 'java.lang.Byte' -> byte;
        'char' -> char; 'java.lang.Character' -> char;
        'double' -> double; 'java.lang.Double' -> double;
        'float' -> float; 'java.lang.Float' -> float;
        'boolean' -> boolean; 'java.lang.Boolean' -> boolean;
        nil -> object;
        'java.lang.Object' -> object;
        _ -> C
    end.

check(I, N) when I >= 0, I < N -> ok;
check(I, N) ->
    erlang:error(clj2_rt:ex_info(iolist_to_binary(["Index ", integer_to_binary(I), " out of bounds for length ",
                                                   integer_to_binary(N)]),
                                 clj2_coll:hash_map_kv([':type', ':ArrayIndexOutOfBoundsException']), nil)).

default(T) when T =:= double; T =:= float -> 0.0;
default(boolean) -> false;
default(T) when T =:= long; T =:= int; T =:= short; T =:= byte; T =:= char -> 0;
default(_) -> nil.

%% building from numbers: Number.longValue/intValue/... (wraps)
coerce(long, V) when is_number(V) -> wrap(trunc(V), 64);
coerce(int, V) when is_number(V) -> wrap(trunc(V), 32);
coerce(short, V) when is_number(V) -> wrap(trunc(V), 16);
coerce(byte, V) when is_number(V) -> wrap(trunc(V), 8);
coerce(char, V) when is_integer(V) -> V band 16#FFFF;
coerce(T, V) when (T =:= double orelse T =:= float), is_number(V) -> float(V);
coerce(_, V) -> V.

%% aset stores what it is given (a typed array checks the type)
store(T, V) when (T =:= double orelse T =:= float), is_integer(V) -> float(V);
store(T, V) when T =:= long; T =:= int; T =:= short; T =:= byte; T =:= char ->
    is_integer(V) orelse erlang:error(clj2_rt:ex_info(<<"argument type mismatch">>,
                                                      clj2_coll:hash_map_kv([':type', ':IllegalArgumentException']), nil)),
    V;
store(_, V) -> V.

wrap(N, Bits) ->
    M = 1 bsl Bits,
    R = N band (M - 1),
    case R >= M bsr 1 of
        true -> R - M;
        false -> R
    end.
