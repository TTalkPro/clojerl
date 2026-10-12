%%%-------------------------------------------------------------------
%%% @doc clj2_jvm — host shims for JVM interop syntax (clojerl2, aligning
%%% with Clojure as written against the JVM): (Class/method args),
%%% Class/FIELD, (.method obj args), (. obj method args), (.-field obj),
%%% (new Class args) / (Class. args).
%%%
%%% There is no JVM: these are the common java.lang (and a few java.util)
%%% members Clojure code reaches for, implemented on BEAM with the JVM's
%%% results — Integer/parseInt, Math/sqrt, String methods, exception
%%% constructors and the like. Anything else raises
%%% IllegalArgumentException "No matching method ..." (known divergence
%%% :host/jvm-shims).
%%%
%%% Objects: strings are UTF-8 binaries (indices count code points, as
%%% everywhere in clj2); an exception made with (new SomeException msg) is
%%% an ex-info whose :type names its class, so catch selects it by class.
%%%-------------------------------------------------------------------
-module(clj2_jvm).

-export([static/3, field/2, method/3, new/2, instance_field/2, builder_text/1, parse_double_or_nil/1]).

-define(LONG_MAX, 16#7FFFFFFFFFFFFFFF).
-define(LONG_MIN, -16#8000000000000000).
-define(INT_MAX, 16#7FFFFFFF).
-define(INT_MIN, -16#80000000).

%%====================================================================
%% Static fields
%%====================================================================

field('java.math.BigDecimal', 'ZERO') -> {decimal, 0, 0};
field('java.math.BigDecimal', 'ONE') -> {decimal, 1, 0};
field('java.math.BigDecimal', 'TEN') -> {decimal, 10, 0};
%% a rounding mode is its name (clj2_decimal:rounding_mode/1 reads it)
field('java.math.RoundingMode', M) -> clj2_decimal:rounding_mode(M), M;
field('java.lang.Long', 'MAX_VALUE') -> ?LONG_MAX;
field('java.lang.Long', 'MIN_VALUE') -> ?LONG_MIN;
field('java.lang.Integer', 'MAX_VALUE') -> ?INT_MAX;
field('java.lang.Integer', 'MIN_VALUE') -> ?INT_MIN;
field('java.lang.Short', 'MAX_VALUE') -> 32767;
field('java.lang.Short', 'MIN_VALUE') -> -32768;
field('java.lang.Byte', 'MAX_VALUE') -> 127;
field('java.lang.Byte', 'MIN_VALUE') -> -128;
field('java.lang.Character', 'MAX_VALUE') -> 16#FFFF;
field('java.lang.Character', 'MIN_VALUE') -> 0;
field('java.lang.Double', 'MAX_VALUE') -> 1.7976931348623157e308;
field('java.lang.Double', 'MIN_VALUE') -> 4.9e-324;
field('java.lang.Float', 'MAX_VALUE') -> 3.4028234663852886e38;
field('java.lang.Float', 'MIN_VALUE') -> 1.401298464324817e-45;
field('java.lang.Math', 'PI') -> math:pi();
field('java.lang.Math', 'E') -> math:exp(1);
field('java.lang.Boolean', 'TRUE') -> true;
field('java.lang.Boolean', 'FALSE') -> false;
field('java.io.File', 'separator') -> <<"/">>;
field('java.io.File', 'pathSeparator') -> <<":">>;
field(C, F) -> no_member(C, F, []).

%%====================================================================
%% Static methods
%%====================================================================

%% (. Long MAX_VALUE): a field, when the class has one by that name
static(C, F, []) when F =/= random, F =/= currentTimeMillis, F =/= nanoTime ->
    try field(C, F)
    catch error:_ -> static1(C, F, [])
    end;
static(C, M, Args) -> static1(C, M, Args).

static1('java.lang.Math', M, Args) -> math_fn(M, Args);
static1('java.math.BigDecimal', valueOf, [X]) when is_integer(X); is_float(X) -> clj2_decimal:from(X);
static1('java.math.BigDecimal', valueOf, [U, S]) when is_integer(U), is_integer(S) -> {decimal, U, S};
static1('java.math.RoundingMode', valueOf, [N]) -> M = binary_to_atom(str(N)), clj2_decimal:rounding_mode(M), M;
static1('java.lang.StrictMath', M, Args) -> math_fn(M, Args);
static1(C, M, Args) when C =:= 'java.lang.Long'; C =:= 'java.lang.Integer';
                        C =:= 'java.lang.Short'; C =:= 'java.lang.Byte' ->
    integer_fn(C, M, Args);
static1(C, M, Args) when C =:= 'java.lang.Double'; C =:= 'java.lang.Float' -> double_fn(M, Args);
static1('java.lang.Character', M, Args) -> char_fn(M, Args);
static1('java.lang.Boolean', parseBoolean, [S]) -> string:lowercase(str(S)) =:= <<"true">>;
static1('java.lang.Boolean', valueOf, [S]) when is_binary(S) -> string:lowercase(S) =:= <<"true">>;
static1('java.lang.Boolean', valueOf, [B]) -> B =:= true;
static1('java.lang.String', valueOf, [X]) -> to_string(X);
static1('java.lang.String', valueOf, [Cs, Off, N]) -> string:slice(to_string(Cs), Off, N);
static1('java.lang.String', join, [Sep, Coll]) -> clj2_string:join(Sep, Coll);
static1('java.lang.String', join, [Sep | Elems]) -> clj2_string:join(Sep, Elems);
static1('java.lang.String', format, [Fmt | Args]) -> clj2_format:format(Fmt, Args);
static1('java.lang.System', currentTimeMillis, []) -> erlang:system_time(millisecond);
static1('java.lang.System', nanoTime, []) -> erlang:monotonic_time(nanosecond);
static1('java.lang.System', getProperty, [K]) when is_binary(K) -> property(K, nil);
static1('java.lang.System', getProperty, [K, D]) when is_binary(K) -> property(K, D);
static1('java.lang.System', getProperty, [K | _]) ->
    throw_new('java.lang.ClassCastException',
              [iolist_to_binary(["class ", atom_to_binary(clj2_class:class_of(K)), " cannot be cast to class java.lang.String"])]);
static1('java.lang.System', getenv, [K]) ->
    case os:getenv(unicode:characters_to_list(K)) of
        false -> nil;
        V -> unicode:characters_to_binary(V)
    end;
static1('java.lang.System', getenv, []) ->
    clj2_coll:hash_map_kv(lists:append([[unicode:characters_to_binary(K), unicode:characters_to_binary(V)]
                                        || KV <- os:getenv(), [K, V] <- [string:split(KV, "=")]]));
static1('java.lang.System', lineSeparator, []) -> <<"\n">>;
static1('java.lang.System', identityHashCode, [X]) -> erlang:phash2(X);
static1('java.lang.System', exit, [Code]) -> erlang:halt(Code);
static1('java.lang.Thread', sleep, [Ms]) -> timer:sleep(Ms), nil;
static1('java.lang.Thread', currentThread, []) -> self();
static1('java.util.UUID', randomUUID, []) -> clj2_string:random_uuid();
static1('java.util.UUID', fromString, [S]) -> clj2_string:uuid(S);
static1('java.util.Objects', equals, [A, B]) -> clj2_coll:equals(A, B);
static1('java.util.Objects', hash, Args) -> clj2_hash:hash_ordered(Args);
static1('java.util.Objects', isNull, [X]) -> X =:= nil;
static1('java.util.Objects', nonNull, [X]) -> X =/= nil;
static1('java.util.Objects', requireNonNull, [nil | _]) -> throw_new('java.lang.NullPointerException', []);
static1('java.util.Objects', requireNonNull, [X | _]) -> X;
static1('clojure.lang.RT', count, [X]) -> clj2_coll:count(X);
static1('clojure.lang.Symbol', M, [N]) when M =:= intern; M =:= create -> clj2_rt:symbol(N);
static1('clojure.lang.Symbol', M, [Ns, N]) when M =:= intern; M =:= create -> clj2_rt:symbol(Ns, N);
static1('clojure.lang.Keyword', intern, [N]) -> clj2_rt:keyword(N);
static1('clojure.lang.Keyword', intern, [Ns, N]) -> clj2_rt:keyword(Ns, N);
static1('clojure.lang.Keyword', find, [N]) -> find_keyword(clj2_rt:namespace(N), clj2_rt:name(N));
static1('clojure.lang.Keyword', find, [Ns, N]) -> find_keyword(Ns, N);
static1('clojure.lang.Var', find, [S]) ->
    Ns = case clj2_rt:namespace(S) of
             nil -> throw_new('java.lang.IllegalArgumentException', [<<"Symbol must be namespace-qualified">>]);
             N -> binary_to_atom(N)
         end,
    Name = binary_to_atom(clj2_rt:name(S)),
    case clj2_ns:info(Ns) of
        {ok, #{vars := #{Name := _}}} -> {var, nil, {Ns, Name}};
        {ok, _} -> nil;
        error -> throw_new('java.lang.IllegalArgumentException', [<<"No such namespace: ", (atom_to_binary(Ns))/binary>>])
    end;
static1('clojure.lang.Numbers', M, Args) -> static1('java.lang.Math', M, Args);
static1(C, M, Args) -> no_member(C, M, Args).

math_fn(abs, [X]) -> abs(X);
math_fn(sqrt, [X]) -> math:sqrt(X);
math_fn(cbrt, [X]) when X < 0 -> -math:pow(-X, 1 / 3);
math_fn(cbrt, [X]) -> math:pow(X, 1 / 3);
math_fn(pow, [X, Y]) -> math:pow(X, Y);
math_fn(exp, [X]) -> math:exp(X);
math_fn(log, [X]) -> math:log(X);
math_fn(log10, [X]) -> math:log10(X);
math_fn(sin, [X]) -> math:sin(X);
math_fn(cos, [X]) -> math:cos(X);
math_fn(tan, [X]) -> math:tan(X);
math_fn(asin, [X]) -> math:asin(X);
math_fn(acos, [X]) -> math:acos(X);
math_fn(atan, [X]) -> math:atan(X);
math_fn(atan2, [Y, X]) -> math:atan2(Y, X);
math_fn(hypot, [X, Y]) -> math:sqrt(X * X + Y * Y);
math_fn(floor, [X]) -> float(math:floor(X));
math_fn(ceil, [X]) -> float(math:ceil(X));
math_fn(rint, [X]) -> float(round_half_even(X));
math_fn(round, [X]) when is_integer(X) -> X;
math_fn(round, [X]) -> trunc(math:floor(X + 0.5));
math_fn(signum, [X]) when X > 0 -> 1.0;
math_fn(signum, [X]) when X < 0 -> -1.0;
math_fn(signum, [X]) -> float(X);
math_fn(max, [X, Y]) -> max(X, Y);
math_fn(min, [X, Y]) -> min(X, Y);
math_fn(random, []) -> rand:uniform();
math_fn(floorDiv, [X, Y]) -> floor_div(X, Y);
math_fn(floorMod, [X, Y]) -> X - floor_div(X, Y) * Y;
math_fn(toRadians, [X]) -> X * math:pi() / 180;
math_fn(toDegrees, [X]) -> X * 180 / math:pi();
math_fn(addExact, [X, Y]) -> clj2_math:exact(add, X, Y);
math_fn(multiplyExact, [X, Y]) -> clj2_math:exact(multiply, X, Y);
math_fn(subtractExact, [X, Y]) -> clj2_math:exact(subtract, X, Y);
math_fn(negateExact, [X]) -> clj2_math:exact(negate, X);
math_fn(incrementExact, [X]) -> clj2_math:exact(increment, X);
math_fn(decrementExact, [X]) -> clj2_math:exact(decrement, X);
math_fn(nextUp, [X]) -> clj2_math:next_up(X);
math_fn(nextDown, [X]) -> clj2_math:next_down(X);
math_fn(nextAfter, [X, Y]) -> clj2_math:next_after(X, Y);
math_fn(ulp, [X]) -> clj2_math:ulp(X);
math_fn(getExponent, [X]) -> clj2_math:get_exponent(X);
math_fn(scalb, [X, N]) -> clj2_math:scalb(X, N);
math_fn(copySign, [X, Y]) -> clj2_math:copy_sign(X, Y);
math_fn('IEEEremainder', [X, Y]) -> clj2_math:ieee_remainder(X, Y);
math_fn(sinh, [X]) -> math:sinh(X);
math_fn(cosh, [X]) -> math:cosh(X);
math_fn(tanh, [X]) -> math:tanh(X);
math_fn(expm1, [X]) -> math:exp(X) - 1;
math_fn(log1p, [X]) -> math:log(1 + X);
math_fn(M, Args) -> no_member('java.lang.Math', M, Args).

floor_div(X, Y) when (X >= 0) =:= (Y > 0) -> X div Y;
floor_div(X, Y) ->
    Q = X div Y,
    case Q * Y =:= X of true -> Q; false -> Q - 1 end.

round_half_even(X) ->
    F = math:floor(X),
    case X - F of
        D when D > 0.5 -> F + 1;
        D when D < 0.5 -> F;
        _ -> case trunc(F) rem 2 of 0 -> F; _ -> F + 1 end
    end.

integer_fn(C, valueOf, [I]) when is_integer(I) -> in_range(C, I, integer_to_binary(I), 10);
integer_fn(C, M, [S]) when M =:= parseInt; M =:= parseLong; M =:= parseShort; M =:= parseByte; M =:= valueOf ->
    in_range(C, parse_int(S, 10), S, 10);
integer_fn(C, M, [S, R]) when M =:= parseInt; M =:= parseLong; M =:= parseShort; M =:= parseByte; M =:= valueOf ->
    in_range(C, parse_int(S, R), S, R);
integer_fn(C, decode, [S]) ->
    I = decode(str(S)),
    %% a narrow class names the value and the input (Byte/Short.decode)
    case C =:= 'java.lang.Byte' orelse C =:= 'java.lang.Short' of
        true ->
            {Lo, Hi} = range_of(C),
            case I >= Lo andalso I =< Hi of
                true -> I;
                false -> throw_new('java.lang.NumberFormatException',
                                   [iolist_to_binary(["Value ", integer_to_binary(I), " out of range from input ", str(S)])])
            end;
        false -> in_range(C, I, S, 10)
    end;
integer_fn(_, toString, [I]) -> integer_to_binary(I);
integer_fn(_, toString, [I, R]) -> string:lowercase(integer_to_binary(I, R));
integer_fn(_, toHexString, [I]) -> unsigned(I, 16);
integer_fn(_, toOctalString, [I]) -> unsigned(I, 8);
integer_fn(_, toBinaryString, [I]) -> unsigned(I, 2);
integer_fn(_, compare, [A, B]) -> sign(A - B);
integer_fn(_, signum, [I]) -> sign(I);
integer_fn(_, bitCount, [I]) -> length([1 || <<1:1>> <= <<(I band 16#FFFFFFFFFFFFFFFF):64>>]);
integer_fn(_, sum, [A, B]) -> A + B;
integer_fn(_, max, [A, B]) -> max(A, B);
integer_fn(_, min, [A, B]) -> min(A, B);
integer_fn(_, hashCode, [I]) -> clj2_hash:java_hash_code(I);
integer_fn(C, M, Args) -> no_member(C, M, Args).

%% the parse and valueOf methods check the width of their class (a
%% parsed number is a JVM long/int/short/byte; arithmetic stays BEAM's)
in_range(C, I, S, R) ->
    {Lo, Hi} = range_of(C),
    case I >= Lo andalso I =< Hi of
        true -> I;
        %% Short and Byte parse as an int, then range-check; Long and
        %% Integer fail like any bad input
        false when C =:= 'java.lang.Short'; C =:= 'java.lang.Byte' ->
            throw_new('java.lang.NumberFormatException',
                      [iolist_to_binary(["Value out of range. Value:\"", str(S), "\" Radix:", integer_to_binary(R)])]);
        false -> bad_input(str(S), R)
    end.

range_of('java.lang.Long') -> {?LONG_MIN, ?LONG_MAX};
range_of('java.lang.Integer') -> {?INT_MIN, ?INT_MAX};
range_of('java.lang.Short') -> {-32768, 32767};
range_of('java.lang.Byte') -> {-128, 127}.

parse_int(_, R) when is_integer(R), R < 2 ->
    throw_new('java.lang.NumberFormatException',
              [iolist_to_binary(["radix ", integer_to_binary(R), " less than Character.MIN_RADIX"])]);
parse_int(_, R) when is_integer(R), R > 36 ->
    throw_new('java.lang.NumberFormatException',
              [iolist_to_binary(["radix ", integer_to_binary(R), " greater than Character.MAX_RADIX"])]);
parse_int(S, R) when is_binary(S) ->
    Text = case S of <<"+", T/binary>> -> T; _ -> S end,
    try binary_to_integer(Text, R)
    catch error:badarg -> bad_input(S, R)
    end;
parse_int(nil, _) -> throw_new('java.lang.NumberFormatException', [<<"Cannot parse null string: null">>]).

%% the JVM names a radix other than ten
bad_input(S, 10) -> throw_new('java.lang.NumberFormatException', [<<"For input string: \"", S/binary, "\"">>]);
bad_input(S, R) ->
    throw_new('java.lang.NumberFormatException',
              [iolist_to_binary(["For input string: \"", S, "\" under radix ", integer_to_binary(R)])]).

decode(<<>>) -> throw_new('java.lang.NumberFormatException', [<<"Zero length string">>]);
decode(<<"-", S/binary>>) -> -decode(S);
decode(<<"+", S/binary>>) -> decode(S);
decode(<<"0x", S/binary>>) -> parse_int(S, 16);
decode(<<"0X", S/binary>>) -> parse_int(S, 16);
decode(<<"#", S/binary>>) -> parse_int(S, 16);
decode(<<"0", S/binary>>) when S =/= <<>> -> parse_int(S, 8);
decode(S) -> parse_int(S, 10).

%% as on the JVM, a negative number's 64-bit two's complement
unsigned(I, R) when I >= 0 -> string:lowercase(integer_to_binary(I, R));
unsigned(I, R) -> string:lowercase(integer_to_binary(I band 16#FFFFFFFFFFFFFFFF, R)).

sign(X) when X > 0 -> 1;
sign(X) when X < 0 -> -1;
sign(_) -> 0.

double_fn(M, [S]) when M =:= parseDouble; M =:= parseFloat; M =:= valueOf, is_binary(S) ->
    parse_double(S);
double_fn(valueOf, [X]) when is_number(X) -> float(X);
double_fn(isNaN, [_]) -> false;                         % BEAM floats have no NaN
double_fn(isInfinite, [_]) -> false;
double_fn(isFinite, [_]) -> true;
double_fn(toString, [X]) -> clj2_print:float_str(float(X));
double_fn(compare, [A, B]) -> sign(A - B);
double_fn(doubleToLongBits, [X]) -> <<I:64/signed>> = <<(float(X)):64/float>>, I;
double_fn(longBitsToDouble, [I]) -> <<F:64/float>> = <<I:64/signed>>, F;
double_fn(sum, [A, B]) -> A + B;
double_fn(max, [A, B]) -> max(A, B);
double_fn(min, [A, B]) -> min(A, B);
double_fn(M, Args) -> no_member('java.lang.Double', M, Args).

%% Double.valueOf's grammar: a decimal (with an optional d/f suffix) or a
%% hex significand with a binary exponent (0x1.8p1); BEAM has no
%% Infinity/NaN (:number/beam-semantics)
parse_double(S0) ->
    case parse_double_or_nil(S0) of
        nil -> throw_new('java.lang.NumberFormatException', [<<"For input string: \"", S0/binary, "\"">>]);
        F -> F
    end.

parse_double_or_nil(S0) when is_binary(S0) ->
    S1 = string:trim(S0),
    {Sign, S2} = case S1 of
                     <<"-", R/binary>> -> {-1, R};
                     <<"+", R/binary>> -> {1, R};
                     _ -> {1, S1}
                 end,
    S3 = case re:run(S2, "^(.*[0-9.])[dDfF]$", [{capture, [1], binary}]) of
             {match, [Body]} -> Body;
             nomatch -> S2
         end,
    try
        case re:run(S3, "^0[xX]([0-9a-fA-F]*)(?:\\.([0-9a-fA-F]*))?[pP]([-+]?[0-9]+)$", [{capture, all_but_first, list}]) of
            {match, [IntH, FracH, Exp]} when IntH =/= [] orelse FracH =/= [] ->
                Mant = list_to_integer("0" ++ IntH ++ FracH, 16),
                Sign * Mant * math:pow(2, list_to_integer(Exp) - 4 * length(FracH));
            {match, _} -> nil;
            nomatch ->
                case re:run(S3, "^([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?$") of
                    {match, _} -> Sign * decimal(S3);
                    nomatch -> nil
                end
        end
    catch error:_ -> nil
    end;
parse_double_or_nil(_) -> nil.

decimal(S) ->
    Text = binary_to_list(S),
    Norm = case {lists:member($., Text), string:find(string:lowercase(Text), "e")} of
               {false, nomatch} -> Text ++ ".0";
               {false, _} ->
                   [M, E] = string:split(string:lowercase(Text), "e"),
                   M ++ ".0e" ++ E;
               _ -> Text
           end,
    Norm1 = case Norm of
                "." ++ _ -> "0" ++ Norm;
                _ -> Norm
            end,
    Norm2 = case lists:reverse(Norm1) of
                "." ++ _ -> Norm1 ++ "0";
                _ -> re:replace(Norm1, "\\.([eE])", ".0\\1", [{return, list}])
            end,
    list_to_float(Norm2).

char_fn(isDigit, [C]) -> C >= $0 andalso C =< $9 orelse cat(C, "Nd");
char_fn(isLetter, [C]) -> cat(C, "L");
char_fn(isLetterOrDigit, [C]) -> cat(C, "L") orelse cat(C, "Nd");
char_fn(isAlphabetic, [C]) -> cat(C, "L");
char_fn(isUpperCase, [C]) -> cat(C, "Lu");
char_fn(isLowerCase, [C]) -> cat(C, "Ll");
char_fn(isWhitespace, [C]) -> lists:member(C, [$\s, $\t, $\n, $\r, $\f, 16#0B, 16#1C, 16#1D, 16#1E, 16#1F])
                                  orelse (cat(C, "Z") andalso not lists:member(C, [16#A0, 16#2007, 16#202F]));
char_fn(isSpaceChar, [C]) -> cat(C, "Z");
char_fn(toUpperCase, [C]) -> hd(string:uppercase([C]));
char_fn(toLowerCase, [C]) -> hd(string:lowercase([C]));
char_fn(digit, [C, R]) ->
    V = if C >= $0, C =< $9 -> C - $0;
           C >= $a, C =< $z -> C - $a + 10;
           C >= $A, C =< $Z -> C - $A + 10;
           true -> -1
        end,
    case V >= 0 andalso V < R of true -> V; false -> -1 end;
char_fn(getNumericValue, [C]) -> char_fn(digit, [C, 36]);
char_fn(valueOf, [C]) -> C;
char_fn(toString, [C]) -> unicode:characters_to_binary([C]);
char_fn(isSurrogate, [C]) -> C >= 16#D800 andalso C =< 16#DFFF;
char_fn(M, Args) -> no_member('java.lang.Character', M, Args).

%% the general category of a code point (a single-char regex test)
cat(C, Cat) when is_integer(C) ->
    re:run(unicode:characters_to_binary([C]), ["^\\p{", Cat, "}$"], [unicode]) =/= nomatch;
cat(_, _) -> false.

property(<<"line.separator">>, _) -> <<"\n">>;
property(<<"file.separator">>, _) -> <<"/">>;
property(<<"path.separator">>, _) -> <<":">>;
property(<<"user.dir">>, _) -> {ok, D} = file:get_cwd(), unicode:characters_to_binary(D);
property(<<"user.home">>, D) -> env("HOME", D);
property(<<"user.name">>, D) -> env("USER", D);
property(<<"java.io.tmpdir">>, _) -> env("TMPDIR", <<"/tmp">>);
property(<<"os.name">>, _) -> {_, N} = os:type(), atom_to_binary(N);
property(<<"java.version">>, _) -> <<"clojerl2">>;
property(_, D) -> D.

env(Name, D) ->
    case os:getenv(Name) of
        false -> D;
        V -> unicode:characters_to_binary(V)
    end.

%%====================================================================
%% Instance methods: (.method obj args)
%%====================================================================

method(nil, M, _) ->
    throw_new('java.lang.NullPointerException', [iolist_to_binary(["Cannot invoke \"", atom_to_binary(M), "\" on nil"])]);
%% a String method refuses a nil argument (equals and the like take one)
method(S, M, Args) when is_binary(S), M =/= equals, M =/= equalsIgnoreCase, M =/= contentEquals,
                        M =/= valueOf, M =/= format ->
    case lists:member(nil, Args) of
        true -> throw_new('java.lang.NullPointerException', [<<"Cannot invoke a String method with a null argument">>]);
        false -> string_method_checked(S, M, Args)
    end;
method(S, M, Args) when is_binary(S) -> string_method_checked(S, M, Args);
method({'clojure.lang.ExceptionInfo', _, _} = E, M, Args) -> exception_method(E, M, Args);
method({'java.lang.StringBuilder', _, _} = B, M, Args) -> builder_method(B, M, Args);
method({decimal, _, _} = D, M, Args) -> decimal_method(D, M, Args);
method({'java.util.Date', _, Ms}, getTime, []) -> Ms;
method({var, _, {_, _}} = V, M, Args) -> var_method(V, M, Args);
method(X, toString, []) -> to_string(X);
method(X, equals, [Y]) -> clj2_coll:equals(X, Y);
method(X, hashCode, []) -> clj2_hash:java_hash_code(X);
method(X, getClass, []) -> clj2_class:class_of(X);
method(C, getName, []) when is_atom(C) -> atom_to_binary(C);           % a class
method(C, getSimpleName, []) when is_atom(C) ->
    [Last | _] = lists:reverse(string:split(atom_to_binary(C), ".", all)), Last;
method(N, M, []) when is_number(N), M =:= intValue; is_number(N), M =:= longValue;
                      is_number(N), M =:= shortValue; is_number(N), M =:= byteValue -> trunc(N);
method(N, M, []) when is_number(N), M =:= doubleValue; is_number(N), M =:= floatValue -> float(N);
method(N, compareTo, [O]) when is_number(N) -> sign(N - O);
method({atom, _, _} = A, get, []) -> clj2_ref:deref(A);
method({atom, _, _} = A, reset, [V]) -> clj2_ref:reset(A, V);
%% an io device as a java.io.Writer: write (a string, or a char's code
%% point, as Writer.write(int)), append, flush
method(P, write, [X]) when is_pid(P) -> clj2_io:write(P, writer_chars(X)), nil;
method(P, write, [X, Off, Len]) when is_pid(P), is_binary(X) ->
    clj2_io:write(P, string:slice(X, Off, Len)), nil;
method(P, append, [X]) when is_pid(P) -> clj2_io:write(P, writer_chars(X)), P;
method(P, flush, []) when is_pid(P) -> nil;
method(X, M, Args) ->
    case clj2_coll:is_any_map(X) orelse clj2_coll:is_any_set(X) orelse clj2_coll:is_vector(X)
         orelse is_list(X) orelse is_tuple(X) andalso element(1, X) =:= lazy_seq of
        true -> coll_method(X, M, Args);
        false ->
            %% a deftype/defrecord: a method of what it implements
            case clj2_proto:is_type_value(X) andalso clj2_proto:type_method(X, M, Args) of
                {ok, R} -> R;
                _ -> no_member(clj2_class:class_of(X), M, Args)
            end
    end.

writer_chars(C) when is_integer(C) -> [C];
writer_chars(X) -> to_string(X).


%% a String method; an argument of the wrong class is a ClassCastException
string_method_checked(S, M, Args) ->
    try string_method(S, M, Args)
    catch error:R when R =:= badarg; R =:= function_clause; element(1, R) =:= badarg ->
            case [A || A <- Args, not is_binary(A), not is_integer(A), A =/= nil] of
                [Bad | _] ->
                    throw_new('java.lang.ClassCastException',
                              [iolist_to_binary(["class ", atom_to_binary(clj2_class:class_of(Bad)),
                                                 " cannot be cast to class java.lang.String"])]);
                [] -> erlang:raise(error, R, [])
            end
    end.

string_method(S, length, []) -> string:length(S);
string_method(S, isEmpty, []) -> S =:= <<>>;
string_method(S, isBlank, []) -> clj2_string:is_blank(S);
string_method(S, toUpperCase, []) -> clj2_string:upper(S);
string_method(S, toLowerCase, []) -> clj2_string:lower(S);
string_method(S, trim, []) -> unicode:characters_to_binary(string:trim(S, both, " \t\n\r\f\v\x00"));
string_method(S, strip, []) -> clj2_string:trim(S);
string_method(S, charAt, [I]) ->
    case clj2_coll:nth(S, I, '$none') of
        '$none' -> throw_new('java.lang.StringIndexOutOfBoundsException', [<<"index out of range">>]);
        C -> C
    end;
string_method(S, substring, [B]) -> substring(S, B, string:length(S));
string_method(S, substring, [B, E]) -> substring(S, B, E);
string_method(S, subSequence, [B, E]) -> substring(S, B, E);
%% indexOf(int ch): a code point, as a char
string_method(S, indexOf, [C]) when is_integer(C) -> idx(clj2_string:index_of(S, unicode:characters_to_binary([C]), 0));
string_method(S, indexOf, [C, From]) when is_integer(C) ->
    idx(clj2_string:index_of(S, unicode:characters_to_binary([C]), From));
string_method(S, lastIndexOf, [C]) when is_integer(C) ->
    idx(clj2_string:last_index_of(S, unicode:characters_to_binary([C]), nil));
string_method(S, indexOf, [X]) -> idx(clj2_string:index_of(S, X, 0));
string_method(S, indexOf, [X, From]) -> idx(clj2_string:index_of(S, X, From));
string_method(S, lastIndexOf, [X]) -> idx(clj2_string:last_index_of(S, X, nil));
string_method(S, contains, [X]) -> clj2_string:includes(S, to_string(X));
string_method(S, startsWith, [P]) -> clj2_string:starts_with(S, P);
string_method(S, endsWith, [P]) -> clj2_string:ends_with(S, P);
string_method(S, concat, [T]) when is_binary(T) -> <<S/binary, T/binary>>;
string_method(_, concat, [T]) ->
    throw_new('java.lang.ClassCastException',
              [iolist_to_binary(["class ", atom_to_binary(clj2_class:class_of(T)), " cannot be cast to class java.lang.String"])]);
string_method(S, replace, [A, B]) -> clj2_string:replace(S, A, B, all);
string_method(S, replaceAll, [Re, R]) -> clj2_string:replace(S, clj2_re:pattern(Re), R, all);
string_method(S, replaceFirst, [Re, R]) -> clj2_string:replace(S, clj2_re:pattern(Re), R, first);
string_method(S, matches, [Re]) -> clj2_re:matches(clj2_re:pattern(Re), S);
string_method(S, split, [Re]) -> clj2_string:split(S, clj2_re:pattern(Re), 0);
string_method(S, split, [Re, N]) -> clj2_string:split(S, clj2_re:pattern(Re), N);
string_method(S, equals, [T]) -> S =:= T;
string_method(S, equalsIgnoreCase, [T]) when is_binary(T) -> string:lowercase(S) =:= string:lowercase(T);
string_method(_, equalsIgnoreCase, [_]) -> false;
string_method(S, compareTo, [T]) -> compare_strings(S, T);
string_method(S, compareToIgnoreCase, [T]) -> compare_strings(string:lowercase(S), string:lowercase(T));
string_method(S, toCharArray, []) -> clj2_coll:vector(unicode:characters_to_list(S));
string_method(S, getBytes, []) -> clj2_coll:vector(binary_to_list(S));
string_method(S, getBytes, [_Charset]) -> clj2_coll:vector(binary_to_list(S));
string_method(S, chars, []) -> unicode:characters_to_list(S);
string_method(S, repeat, [N]) -> binary:copy(S, N);
string_method(S, intern, []) -> S;
string_method(S, hashCode, []) -> clj2_hash:string_hash_code(S);
string_method(S, toString, []) -> S;
string_method(_, M, Args) -> no_member('java.lang.String', M, Args).

compare_strings(S, T) ->
    sign_or_diff(unicode:characters_to_list(S), unicode:characters_to_list(T)).

%% String.compareTo: the first differing char's difference, else the
%% length difference
sign_or_diff([C | R1], [C | R2]) -> sign_or_diff(R1, R2);
sign_or_diff([A | _], [B | _]) -> A - B;
sign_or_diff(R1, R2) -> length(R1) - length(R2).

substring(S, B, E) ->
    N = string:length(S),
    (B >= 0 andalso E =< N andalso B =< E) orelse
        throw_new('java.lang.StringIndexOutOfBoundsException',
                  [iolist_to_binary(io_lib:format("begin ~b, end ~b, length ~b", [B, E, N]))]),
    string:slice(S, B, E - B).

idx(nil) -> -1;
idx(I) -> I.

exception_method(E, getMessage, []) -> clj2_rt:ex_message(E);
exception_method(E, getLocalizedMessage, []) -> clj2_rt:ex_message(E);
exception_method(E, getCause, []) -> clj2_rt:ex_cause(E);
exception_method(E, getData, []) -> clj2_rt:ex_data(E);
exception_method(E, toString, []) ->
    iolist_to_binary([atom_to_binary(clj2_class:exception_class(E)), ": ", str(clj2_rt:ex_message(E))]);
exception_method(_, getStackTrace, []) -> clj2_coll:vector([]);
exception_method(E, M, Args) -> method_fallback(E, M, Args).

method_fallback(X, M, Args) -> no_member(clj2_class:class_of(X), M, Args).

find_keyword(Ns, N) ->
    try clj2_rt:existing_keyword(case Ns of nil -> nil; _ -> str(Ns) end, str(N))
    catch error:badarg -> nil
    end.

%% clojure.lang.Var's members, over the namespace's var info
var_method({var, _, {Ns, Name}} = V, M, Args) ->
    {ok, #{module := NsMod, vars := #{Name := Info}}} = clj2_ns:info(Ns),
    Mod = maps:get(module, Info, NsMod),
    case {M, Args} of
        {isMacro, []} -> maps:get(macro, Info, false);
        {isDynamic, []} -> maps:get(dynamic, Info, false);
        {isPublic, []} -> not maps:get(private, Info, false);
        {isBound, []} -> is_bound(V);
        {hasRoot, []} -> has_root(Mod, Name, Info);
        {M, []} when M =:= deref; M =:= get; M =:= getRawRoot -> clj2_ref:deref(V);
        {toSymbol, []} -> clj2_rt:symbol(atom_to_binary(Ns), atom_to_binary(Name));
        {sym, []} -> Name;
        {fn, []} ->
            F = clj2_ref:deref(V),
            case clj2_rt:is_fn(F) orelse is_atom(F) orelse is_tuple(F) of
                true -> F;
                false -> throw_new('java.lang.ClassCastException',
                                   [iolist_to_binary(["class ", atom_to_binary(clj2_class:class_of(F)),
                                                      " cannot be cast to class clojure.lang.IFn"])])
            end;
        {set, [X]} ->
            case get({clj2_dyn, Mod, Name}) of
                [_ | _] -> clj2_var:set_binding(Mod, Name, X), X;
                _ -> throw_new('java.lang.IllegalStateException',
                               [<<"Can't change/establish root binding of: ", (atom_to_binary(Name))/binary, " with set">>])
            end;
        {getThreadBinding, []} ->
            case get({clj2_dyn, Mod, Name}) of
                [X | _] -> X;
                _ -> nil
            end;
        _ -> no_member('clojure.lang.Var', M, Args)
    end.

is_bound(V) ->
    try clj2_ref:deref(V), true
    catch error:{clj2_unbound_var, _, _} -> false
    end.

has_root(Mod, Name, #{kind := indirect}) -> ets:member(clj2_var, {Mod, Name});
has_root(_, _, _) -> true.

coll_method(X, size, []) -> clj2_coll:count(X);
coll_method(X, count, []) -> clj2_coll:count(X);
coll_method(X, isEmpty, []) -> clj2_coll:count(X) =:= 0;
coll_method(X, get, [K]) -> case clj2_coll:is_vector(X) of
                                true -> clj2_coll:nth(X, K);
                                false -> clj2_coll:get(X, K)
                            end;
coll_method(X, nth, [I]) -> clj2_coll:nth(X, I);
coll_method(X, valAt, [K]) -> clj2_coll:get(X, K);
coll_method(X, valAt, [K, D]) -> clj2_coll:get(X, K, D);
coll_method(X, containsKey, [K]) -> clj2_coll:contains(X, K);
coll_method(X, contains, [K]) -> lists:any(fun(E) -> clj2_coll:equals(E, K) end, clj2_coll:to_list(X));
coll_method(X, indexOf, [K]) -> index_in(clj2_coll:to_list(X), K, 0);
coll_method(X, seq, []) -> clj2_coll:seq(X);
coll_method(X, first, []) -> case clj2_coll:seq(X) of nil -> nil; [H | _] -> H end;
coll_method(X, cons, [V]) -> [V | clj2_coll:to_list(X)];
coll_method(X, assoc, [K, V]) -> clj2_coll:assoc(X, K, V);
coll_method(X, without, [K]) -> clj2_coll:dissoc(X, K);
coll_method(X, entrySet, []) -> clj2_coll:hash_set(clj2_coll:to_list(X));
coll_method(X, keySet, []) -> clj2_coll:hash_set(clj2_coll:to_list(clj2_coll:keys(X)));
coll_method(X, values, []) -> clj2_coll:to_list(clj2_coll:vals(X));
coll_method(X, toArray, []) -> clj2_coll:vector(clj2_coll:to_list(X));
coll_method(X, iterator, []) -> clj2_coll:seq(X);
coll_method(X, M, Args) -> no_member(clj2_class:class_of(X), M, Args).

index_in([], _, _) -> -1;
index_in([E | R], K, I) -> case clj2_coll:equals(E, K) of true -> I; false -> index_in(R, K, I + 1) end.

%% (.-field obj): a record's field (inside deftype methods fields are locals)
instance_field({Tag, _, M}, F) when is_atom(Tag), is_map(M) ->
    maps:get(list_to_atom(":" ++ atom_to_list(F)), M, nil);
instance_field(X, F) -> no_member(clj2_class:class_of(X), F, []).

%%====================================================================
%% Constructors: (new C args)
%%====================================================================

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
construct('java.util.Date', []) -> clj2_inst:now();
construct('java.util.Date', [Ms]) when is_integer(Ms) -> clj2_inst:from_millis(Ms);
construct('java.math.BigDecimal', [X]) -> clj2_decimal:from(X);
construct('java.math.BigDecimal', [X, {math_context, _, _} = MC]) -> clj2_decimal:round(clj2_decimal:from(X), MC);
construct('java.math.MathContext', [P]) -> clj2_decimal:math_context(P, nil);
construct('java.math.MathContext', [P, M]) -> clj2_decimal:math_context(P, M);
construct('java.lang.String', []) -> <<>>;
construct('java.lang.String', [S]) -> to_string(S);
construct('java.lang.StringBuilder', []) -> builder([]);
construct('java.lang.StringBuilder', [N]) when is_integer(N) -> builder([]);
construct('java.lang.StringBuilder', [nil]) ->
    throw_new('java.lang.NullPointerException', [<<"Cannot invoke \"String.length()\" because \"str\" is null">>]);
construct('java.lang.StringBuilder', [S]) -> builder([to_string(S)]);
construct('java.lang.Long', [X]) -> in_range('java.lang.Long', long_of(X), X, 10);
construct('java.lang.Integer', [X]) -> in_range('java.lang.Integer', long_of(X), X, 10);
construct('java.lang.Double', [X]) when is_number(X) -> float(X);
construct('java.lang.Double', [S]) -> parse_double(S);
construct('java.lang.Boolean', [X]) -> static('java.lang.Boolean', valueOf, [X]);
construct('java.util.UUID', [_Hi, _Lo]) -> clj2_string:random_uuid();
construct('java.io.StringWriter', []) -> clj2_io:string_writer();
construct('java.io.StringReader', [S]) -> clj2_io:string_reader(S);
construct('java.util.Random', _) -> {'java.util.Random', nil, {}};
construct(C, Args) -> no_member(C, '<init>', Args).

long_of(X) when is_integer(X) -> X;
long_of(S) when is_binary(S) -> parse_int(S, 10).

%% a StringBuilder is mutable, as on the JVM (doto, then str): its text
%% lives in an atom, as reversed iodata
builder_method({_, _, Ref} = B, append, [X]) ->
    clj2_ref:reset(Ref, [to_string(X) | clj2_ref:deref(Ref)]), B;
builder_method({_, _, Ref}, toString, []) -> builder_text(Ref);
builder_method({_, _, Ref}, length, []) -> string:length(builder_text(Ref));
builder_method({_, _, Ref} = B, reverse, []) ->
    clj2_ref:reset(Ref, [unicode:characters_to_binary(lists:reverse(unicode:characters_to_list(builder_text(Ref))))]),
    B;
builder_method({_, _, Ref} = B, setLength, [0]) -> clj2_ref:reset(Ref, []), B;
builder_method(_, M, Args) -> no_member('java.lang.StringBuilder', M, Args).

builder(Parts) -> {'java.lang.StringBuilder', nil, clj2_ref:atom(Parts)}.

%% @doc A StringBuilder's text (str uses it)
builder_text({'java.lang.StringBuilder', _, Ref}) -> builder_text(Ref);
builder_text(Ref) -> iolist_to_binary(lists:reverse(clj2_ref:deref(Ref))).

%%====================================================================

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
