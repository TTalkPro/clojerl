%%%-------------------------------------------------------------------
%%% @doc clj2_math — the java.lang.Math members clojure.math adds
%%% (clojerl2-039): IEEE 754 neighbours and exponents on the bits of a
%%% double, IEEE-remainder, copy-sign, scalb, and the *-exact operations,
%%% which check the 64-bit long range as the JVM's do (a named operation,
%%% unlike + and *: :number/beam-semantics). BEAM has no Inf or NaN: a
%%% result past the double range raises (badarith).
%%%-------------------------------------------------------------------
-module(clj2_math).

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
