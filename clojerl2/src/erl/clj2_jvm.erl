%%%-------------------------------------------------------------------
%%% @doc clj2_jvm — what is left of the JVM interop syntax (designs/10):
%%% (.method x args), (.-field x), (Class. args) / (new Class args),
%%% Class/FIELD and (Class/method args) for the few values that have
%%% them here:
%%%   - deftype / defrecord values: their protocol and interface methods,
%%%     record fields (and __extmap / __meta);
%%%   - exceptions: (Exception. msg), (.getMessage e), (.getCause e) ...;
%%%   - BigDecimal: (BigDecimal. x), its methods, MathContext, RoundingMode;
%%%   - io devices as writers (print-method): .write, .append, .flush;
%%%   - toString / equals / hashCode of any value, (Object.).
%%% Java classes (String, Math, Integer, System, Thread ...) are not
%%% provided: Clojure functions and Erlang modules do that work.
%%%-------------------------------------------------------------------
-module(clj2_jvm).

-export([static/3, field/2, method/3, new/2, instance_field/2,
         throw_new/2]).

%%====================================================================
%% Static fields and methods: BigDecimal only
%%====================================================================

field('java.math.BigDecimal', 'ZERO') -> {decimal, 0, 0};
field('java.math.BigDecimal', 'ONE') -> {decimal, 1, 0};
field('java.math.BigDecimal', 'TEN') -> {decimal, 10, 0};
%% a rounding mode is its name (clj2_decimal:rounding_mode/1 reads it)
field('java.math.RoundingMode', M) -> clj2_decimal:rounding_mode(M), M;
field(C, F) -> no_member(C, F, []).

%% (. BigDecimal ZERO): a field, when the class has one by that name
static(C, F, []) ->
    try field(C, F)
    catch error:_ -> static1(C, F, [])
    end;
static(C, M, Args) -> static1(C, M, Args).

static1('java.math.BigDecimal', valueOf, [X]) when is_integer(X); is_float(X) -> clj2_decimal:from(X);
static1('java.math.BigDecimal', valueOf, [U, S]) when is_integer(U), is_integer(S) -> {decimal, U, S};
static1('java.math.RoundingMode', valueOf, [N]) -> M = binary_to_atom(str(N)), clj2_decimal:rounding_mode(M), M;
static1(C, M, Args) -> no_member(C, M, Args).

%%====================================================================
%% Instance methods: (.method x args)
%%====================================================================

method(nil, M, _) ->
    throw_new('java.lang.NullPointerException', [iolist_to_binary(["Cannot invoke \"", atom_to_binary(M), "\" on nil"])]);
method({'clojure.lang.ExceptionInfo', _, _} = E, M, Args) -> exception_method(E, M, Args);
method({decimal, _, _} = D, M, Args) -> decimal_method(D, M, Args);
method({Tag, _, R} = X, M, []) when is_atom(Tag), is_map(R), (M =:= '__extmap' orelse M =:= '__meta') ->
    instance_field(X, M);
%% an io device as a writer (print-method): write (a string, or a code
%% point), append, flush; a string writer's text
method(P, write, [X]) when is_pid(P) -> clj2_io:write(P, writer_chars(X)), nil;
method(P, write, [X, Off, Len]) when is_pid(P), is_binary(X) ->
    clj2_io:write(P, string:slice(X, Off, Len)), nil;
method(P, append, [X]) when is_pid(P) -> clj2_io:write(P, writer_chars(X)), P;
method(P, flush, []) when is_pid(P) -> nil;
method(P, toString, []) when is_pid(P) ->
    case clj2_io:is_string_writer(P) of
        true -> clj2_io:contents(P);
        false -> to_string(P)
    end;
method(X, M, Args) ->
    %% a deftype/defrecord: a method of what it implements, else Object's
    case clj2_proto:is_type_value(X) andalso clj2_proto:type_method(X, M, Args) of
        {ok, R} -> R;
        _ -> object_method(X, M, Args)
    end.

object_method(X, toString, []) -> to_string(X);
object_method(X, equals, [Y]) -> clj2_coll:equals(X, Y);
object_method(X, hashCode, []) -> clj2_hash:hasheq(X);
object_method(X, M, Args) -> no_member(clj2_class:class_of(X), M, Args).

writer_chars(C) when is_integer(C) -> [C];
writer_chars(X) -> to_string(X).

exception_method(E, getMessage, []) -> clj2_rt:ex_message(E);
exception_method(E, getLocalizedMessage, []) -> clj2_rt:ex_message(E);
exception_method(E, getCause, []) -> clj2_rt:ex_cause(E);
exception_method(E, getData, []) -> clj2_rt:ex_data(E);
exception_method(E, toString, []) ->
    iolist_to_binary([atom_to_binary(clj2_class:exception_class(E)), ": ", str(clj2_rt:ex_message(E))]);
exception_method(_, getStackTrace, []) -> clj2_coll:vector([]);
exception_method(E, M, Args) -> method_fallback(E, M, Args).

method_fallback(X, M, Args) -> no_member(clj2_class:class_of(X), M, Args).

%% (.-field x): a record's field; __extmap, __meta
instance_field({Tag, Meta, M}, F) when is_atom(Tag), is_map(M), F =:= '__extmap'; is_atom(Tag), is_map(M), F =:= '__meta' ->
    case F of
        '__meta' -> Meta;
        '__extmap' ->
            Ext = maps:without(clj2_proto:record_fields(Tag), M),
            case map_size(Ext) of 0 -> nil; _ -> Ext end
    end;
instance_field({Tag, _, M}, F) when is_atom(Tag), is_map(M) ->
    maps:get(list_to_atom(":" ++ atom_to_list(F)), M, nil);
instance_field(X, F) -> no_member(clj2_class:class_of(X), F, []).

new(C, Args) ->
    case is_throwable(C) of
        true -> make_exception(C, Args);
        false -> construct(C, Args)
    end.

is_throwable(C) -> C =:= 'java.lang.Throwable' orelse
                       maps:is_key('java.lang.Throwable', clj2_class:supers(C)).

%% an exception is an ex-info carrying its class
make_exception(C, Args) ->
    {Msg, Cause} = case Args of
                       [] -> {nil, nil};
                       [M] when is_binary(M); M =:= nil -> {M, nil};
                       [M, K] when is_binary(M); M =:= nil -> {M, K};
                       [K] -> {nil, K}
                   end,
    Type = binary_to_atom(<<":", (simple_name(C))/binary>>),
    {T, Me, Map} = clj2_rt:ex_info(Msg, clj2_coll:hash_map_kv([':type', Type]), Cause),
    {T, Me, Map#{':host' => true}}.                    % not an ex-info: no ex-data

simple_name(C) ->
    [Last | _] = lists:reverse(string:split(atom_to_binary(C), ".", all)), Last.

construct('java.lang.Object', []) -> {'java.lang.Object', nil, make_ref()};
construct('java.math.BigDecimal', [X]) -> clj2_decimal:from(X);
construct('java.math.BigDecimal', [X, {math_context, _, _} = MC]) -> clj2_decimal:round(clj2_decimal:from(X), MC);
construct('java.math.MathContext', [P]) -> clj2_decimal:math_context(P, nil);
construct('java.math.MathContext', [P, M]) -> clj2_decimal:math_context(P, M);
construct(C, Args) -> no_member(C, '<init>', Args).

to_string(nil) -> <<"null">>;
to_string(X) -> clj2_rt:str([X]).

str(nil) -> <<>>;
str(X) -> clj2_rt:str([X]).

throw_new(C, Args) -> erlang:error(new(C, Args)).

no_member(C, M, Args) ->
    erlang:error(clj2_rt:ex_info(
                   iolist_to_binary(["No matching method ", atom_to_binary(M), " found taking ",
                                     integer_to_binary(length(Args)), " args for class ",
                                     case C of nil -> <<"nil">>; _ -> atom_to_binary(C) end]),
                   clj2_coll:hash_map_kv([':type', ':IllegalArgumentException']), nil)).

%%====================================================================
%% java.math.BigDecimal (clj2_decimal)
%%====================================================================

decimal_method(D, scale, []) -> clj2_decimal:scale(D);
decimal_method(D, precision, []) -> clj2_decimal:precision(D);
decimal_method(D, unscaledValue, []) -> clj2_decimal:unscaled(D);
decimal_method(D, signum, []) -> clj2_decimal:signum(D);
decimal_method(D, negate, []) -> clj2_decimal:negate(D);
decimal_method(D, abs, []) -> clj2_decimal:abs(D);
decimal_method(D, toString, []) -> clj2_decimal:to_string(D);
decimal_method(D, toPlainString, []) -> clj2_decimal:to_plain_string(D);
decimal_method(D, stripTrailingZeros, []) -> clj2_decimal:strip_trailing_zeros(D);
decimal_method(D, setScale, [S]) -> clj2_decimal:set_scale(D, S, 'UNNECESSARY');
decimal_method(D, setScale, [S, M]) -> clj2_decimal:set_scale(D, S, M);
decimal_method(D, round, [MC]) -> clj2_decimal:round(D, MC);
decimal_method(D, M, []) when M =:= doubleValue; M =:= floatValue -> clj2_decimal:to_float(D);
decimal_method(D, M, []) when M =:= longValue; M =:= intValue; M =:= toBigInteger;
                              M =:= shortValue; M =:= byteValue -> clj2_decimal:to_integer(D);
decimal_method(D, compareTo, [O]) -> clj2_decimal:compare(D, clj2_decimal:from(O));
decimal_method(D, equals, [{decimal, _, _} = O]) -> D =:= O;      % scale matters to equals
decimal_method(_, equals, [_]) -> false;
decimal_method(D, hashCode, []) -> clj2_decimal:hash(D);
decimal_method(D, add, [O | MC]) -> clj2_decimal:add(D, clj2_decimal:from(O), mc(MC));
decimal_method(D, subtract, [O | MC]) -> clj2_decimal:sub(D, clj2_decimal:from(O), mc(MC));
decimal_method(D, multiply, [O | MC]) -> clj2_decimal:mul(D, clj2_decimal:from(O), mc(MC));
decimal_method(D, divide, [O | MC]) -> clj2_decimal:divide(D, clj2_decimal:from(O), mc(MC));
decimal_method(D, remainder, [O]) -> clj2_decimal:remainder(D, clj2_decimal:from(O));
decimal_method(D, divideToIntegralValue, [O]) -> clj2_decimal:quot(D, clj2_decimal:from(O));
decimal_method(D, max, [O]) -> case clj2_decimal:compare(D, O) >= 0 of true -> D; false -> O end;
decimal_method(D, min, [O]) -> case clj2_decimal:compare(D, O) =< 0 of true -> D; false -> O end;
decimal_method(_, M, Args) -> no_member('java.math.BigDecimal', M, Args).

mc([{math_context, _, _} = MC]) -> MC;
mc([]) -> nil.

