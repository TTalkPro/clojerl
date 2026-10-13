%%%-------------------------------------------------------------------
%%% @doc clj2_math — the java.lang.Math members clojure.math adds
%%% (clojerl2-039): IEEE 754 neighbours and exponents on the bits of a
%%% double, IEEE-remainder, copy-sign, scalb, and the *-exact operations,
%%% which check the 64-bit long range as the JVM's do (a named operation,
%%% unlike + and *: :number/beam-semantics). BEAM has no Inf or NaN: a
%%% result past the double range raises (badarith).
%%%-------------------------------------------------------------------
-module(clj2_math).

-export([call/2, parse_double/1]).

-export([next_up/1, next_down/1, next_after/2, ulp/1, get_exponent/1, scalb/2,
         copy_sign/2, ieee_remainder/2, exact/2, exact/3]).

-define(LONG_MIN, -16#8000000000000000).
-define(LONG_MAX, 16#7FFFFFFFFFFFFFFF).

bits(F) -> <<B:64/signed>> = <<(float(F)):64/float>>, B.
from_bits(B) -> <<F:64/float>> = <<B:64/signed>>, F.

next_up(F) ->
    X = float(F),
    if X == 0.0 -> from_bits(1);                 % the least subnormal
       X > 0.0 -> from_bits(bits(X) + 1);
       true -> from_bits(bits(X) - 1)
    end.

next_down(F) ->
    X = float(F),
    if X == 0.0 -> -from_bits(1);
       X > 0.0 -> from_bits(bits(X) - 1);
       true -> from_bits(bits(X) + 1)
    end.

next_after(F, D) ->
    X = float(F), Y = float(D),
    if Y > X -> next_up(X);
       Y < X -> next_down(X);
       true -> Y
    end.

%% the distance to the next double away from zero (Math/ulp)
ulp(F) ->
    X = abs(float(F)),
    case get_exponent(X) of
        -1023 -> from_bits(1);                   % subnormal: the least step
        E when E - 52 >= -1022 -> math:pow(2, E - 52);
        E -> from_bits(1 bsl (E - 52 + 1074))
    end.

%% the unbiased exponent of a double (-1023 for zero and subnormals)
get_exponent(F) ->
    ((bits(float(F)) bsr 52) band 16#7FF) - 1023.

%% F × 2^N, rounded once (the bits of a subnormal result are exact)
scalb(F, N) ->
    X = float(F),
    case N > 1023 + 52 of
        true when X /= 0.0 -> erlang:error(badarith);
        _ ->
            R = X * math:pow(2.0, max(N, -1022)),
            case N < -1022 of
                true -> scale_down(R, N + 1022);
                false -> R
            end
    end.

scale_down(R, 0) -> R;
scale_down(R, K) -> scale_down(R / 2.0, K + 1).

copy_sign(Mag, Sign) ->
    M = bits(float(Mag)) band 16#7FFFFFFFFFFFFFFF,
    S = bits(float(Sign)) band (1 bsl 63),
    from_bits(M bor S).

%% x - y × n, n the integer nearest x/y (half to even)
ieee_remainder(X0, Y0) ->
    X = float(X0), Y = float(Y0),
    Y == 0.0 andalso erlang:error(badarith),
    Q = X / Y,
    N0 = trunc(Q),
    Frac = Q - N0,
    N = if Frac > 0.5 -> N0 + 1;
           Frac < -0.5 -> N0 - 1;
           Frac == 0.5 -> case N0 rem 2 of 0 -> N0; _ -> N0 + 1 end;
           Frac == -0.5 -> case N0 rem 2 of 0 -> N0; _ -> N0 - 1 end;
           true -> N0
        end,
    R = X - Y * N,
    case R == 0.0 of
        true -> copy_sign(0.0, X);
        false -> R
    end.

%% addExact & co: the result must fit a long
exact(Op, X) -> check(case Op of negate -> -X; increment -> X + 1; decrement -> X - 1 end).
exact(Op, X, Y) -> check(case Op of add -> X + Y; subtract -> X - Y; multiply -> X * Y end).

check(R) when R >= ?LONG_MIN, R =< ?LONG_MAX -> R;
check(_) ->
    erlang:error(clj2_rt:ex_info(<<"long overflow">>, clj2_coll:hash_map_kv([':type', ':ArithmeticException']), nil)).

%% @doc A math function by name (clojure.math): sqrt, pow, floorDiv ...
call(abs, [X]) -> abs(X);
call(sqrt, [X]) -> math:sqrt(X);
call(cbrt, [X]) when X < 0 -> -math:pow(-X, 1 / 3);
call(cbrt, [X]) -> math:pow(X, 1 / 3);
call(pow, [X, Y]) -> math:pow(X, Y);
call(exp, [X]) -> math:exp(X);
call(log, [X]) -> math:log(X);
call(log10, [X]) -> math:log10(X);
call(sin, [X]) -> math:sin(X);
call(cos, [X]) -> math:cos(X);
call(tan, [X]) -> math:tan(X);
call(asin, [X]) -> math:asin(X);
call(acos, [X]) -> math:acos(X);
call(atan, [X]) -> math:atan(X);
call(atan2, [Y, X]) -> math:atan2(Y, X);
call(hypot, [X, Y]) -> math:sqrt(X * X + Y * Y);
call(floor, [X]) -> float(math:floor(X));
call(ceil, [X]) -> float(math:ceil(X));
call(rint, [X]) -> float(round_half_even(X));
call(round, [X]) when is_integer(X) -> X;
call(round, [X]) -> trunc(math:floor(X + 0.5));
call(signum, [X]) when X > 0 -> 1.0;
call(signum, [X]) when X < 0 -> -1.0;
call(signum, [X]) -> float(X);
call(max, [X, Y]) -> max(X, Y);
call(min, [X, Y]) -> min(X, Y);
call(random, []) -> rand:uniform();
call(floorDiv, [X, Y]) -> floor_div(X, Y);
call(floorMod, [X, Y]) -> X - floor_div(X, Y) * Y;
call(toRadians, [X]) -> X * math:pi() / 180;
call(toDegrees, [X]) -> X * 180 / math:pi();
call(addExact, [X, Y]) -> clj2_math:exact(add, X, Y);
call(multiplyExact, [X, Y]) -> clj2_math:exact(multiply, X, Y);
call(subtractExact, [X, Y]) -> clj2_math:exact(subtract, X, Y);
call(negateExact, [X]) -> clj2_math:exact(negate, X);
call(incrementExact, [X]) -> clj2_math:exact(increment, X);
call(decrementExact, [X]) -> clj2_math:exact(decrement, X);
call(nextUp, [X]) -> clj2_math:next_up(X);
call(nextDown, [X]) -> clj2_math:next_down(X);
call(nextAfter, [X, Y]) -> clj2_math:next_after(X, Y);
call(ulp, [X]) -> clj2_math:ulp(X);
call(getExponent, [X]) -> clj2_math:get_exponent(X);
call(scalb, [X, N]) -> clj2_math:scalb(X, N);
call(copySign, [X, Y]) -> clj2_math:copy_sign(X, Y);
call('IEEEremainder', [X, Y]) -> clj2_math:ieee_remainder(X, Y);
call(sinh, [X]) -> math:sinh(X);
call(cosh, [X]) -> math:cosh(X);
call(tanh, [X]) -> math:tanh(X);
call(expm1, [X]) -> math:exp(X) - 1;
call(log1p, [X]) -> math:log(1 + X);
call(M, _Args) -> erlang:error(clj2_rt:ex_info(iolist_to_binary(["No math function ", atom_to_binary(M)]), clj2_coll:hash_map_kv([':type', ':IllegalArgumentException']), nil)).

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


%% a number's text as Double.valueOf reads it, or nil (parse-double)
parse_double(S0) when is_binary(S0) ->
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
                    {match, _} -> Sign * float_text(S3);
                    nomatch -> nil
                end
        end
    catch error:_ -> nil
    end;
parse_double(_) -> nil.

float_text(S) ->
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
