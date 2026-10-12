%%%-------------------------------------------------------------------
%%% @doc clj2_decimal — java.math.BigDecimal (clojerl2-037).
%%%
%%% A decimal is `{decimal, Unscaled, Scale}': the value Unscaled ×
%%% 10^-Scale, both integers, as BigDecimal's unscaledValue and scale
%%% (1.50M is {decimal, 150, 2}; 1E+3M is {decimal, 1, -3}). Arithmetic
%%% is exact; division that does not terminate raises ArithmeticException
%%% unless a math context (*math-context*, with-precision) gives a
%%% precision, `{math_context, Precision, RoundingMode}', which also
%%% rounds +, - and *. Printing follows BigDecimal.toString.
%%%-------------------------------------------------------------------
-module(clj2_decimal).

-export([is_decimal/1, parse/1, from/1, from/2, to_string/1, to_plain_string/1,
         add/3, sub/3, mul/3, divide/3, negate/1, abs/1, signum/1,
         compare/2, equals/2, to_rational/1, to_ratio/1, to_float/1, to_integer/1,
         scale/1, precision/1, unscaled/1, set_scale/3, strip_trailing_zeros/1,
         quot/2, remainder/2, round/2, hash/1, math_context/2, rounding_mode/1]).

-define(D(U, S), {decimal, U, S}).

is_decimal({decimal, U, S}) when is_integer(U), is_integer(S) -> true;
is_decimal(_) -> false.

%%====================================================================
%% Construction
%%====================================================================

%% @doc A decimal from its text: [+-]digits[.digits][(e|E)[+-]digits]
parse(B) when is_binary(B) ->
    Groups = case re:run(B, "^([+-]?)([0-9]*)(?:\\.([0-9]*))?(?:[eE]([+-]?[0-9]+))?$",
                         [{capture, all_but_first, binary}]) of
                 %% unmatched trailing groups are left out: pad them
                 {match, G} -> {match, G ++ lists:duplicate(4 - length(G), <<>>)};
                 nomatch -> nomatch
             end,
    case Groups of
        {match, [Sign, Int, Frac | Exp]} when Int =/= <<>> orelse Frac =/= <<>> ->
            Digits = <<Int/binary, Frac/binary>>,
            U0 = binary_to_integer(Digits),
            U = case Sign of <<"-">> -> -U0; _ -> U0 end,
            E = case Exp of [X] when X =/= <<>> -> binary_to_integer(X); _ -> 0 end,
            ?D(U, byte_size(Frac) - E);
        _ ->
            erlang:error(clj2_rt:ex_info(<<"Character array is missing \"exponent\" mark 'e' or 'E'.">>,
                                         clj2_coll:hash_map_kv([':type', ':NumberFormatException']), nil))
    end.

%% @doc (bigdec x): integers exactly, a double through its shortest text
%% (BigDecimal/valueOf), a string parsed, a ratio divided
from(X) -> from(X, nil).

from(?D(_, _) = D, _) -> D;
from(I, _) when is_integer(I) -> ?D(I, 0);
from(F, _) when is_float(F) -> parse(clj2_print:float_str(F));
from(B, _) when is_binary(B) -> parse(B);
from({ratio, N, D}, MC) -> divide(?D(N, 0), ?D(D, 0), MC);
from(X, _) -> clj2_rt:not_number(X).

%% @doc A math context: precision (0 is unlimited) and rounding mode
math_context(P, Mode) when is_integer(P), P >= 0 -> {math_context, P, rounding_mode(Mode)}.

%% RoundingMode names (a symbol or keyword: HALF_UP, :half-up ...)
rounding_mode(nil) -> half_up;
rounding_mode(M) when is_atom(M) ->
    N = string:uppercase(string:replace(string:trim(atom_to_list(M), leading, ":"), "-", "_", all)),
    case lists:flatten(N) of
        "HALF_UP" -> half_up; "HALF_DOWN" -> half_down; "HALF_EVEN" -> half_even;
        "UP" -> up; "DOWN" -> down; "CEILING" -> ceiling; "FLOOR" -> floor;
        "UNNECESSARY" -> unnecessary;
        _ -> erlang:error(clj2_rt:ex_info(<<"No enum constant java.math.RoundingMode.", (atom_to_binary(M))/binary>>,
                                          clj2_coll:hash_map_kv([':type', ':IllegalArgumentException']), nil))
    end.

%%====================================================================
%% Text (BigDecimal.toString / toPlainString)
%%====================================================================

to_string(?D(U, S)) ->
    Coeff = integer_to_list(erlang:abs(U)),
    Len = length(Coeff),
    Adjusted = -S + (Len - 1),
    Sign = case U < 0 of true -> "-"; false -> "" end,
    Body = if
               S >= 0, Adjusted >= -6 -> plain(Coeff, S);
               true ->
                   Mant = case Coeff of
                              [D] -> [D];
                              [D | Rest] -> [D, $. | Rest]
                          end,
                   ExpSign = case Adjusted >= 0 of true -> "+"; false -> "" end,
                   Mant ++ "E" ++ ExpSign ++ integer_to_list(Adjusted)
           end,
    unicode:characters_to_binary([Sign, Body]).

to_plain_string(?D(U, S)) ->
    Coeff = integer_to_list(erlang:abs(U)),
    Sign = case U < 0 of true -> "-"; false -> "" end,
    Body = case S >= 0 of
               true -> plain(Coeff, S);
               false -> Coeff ++ lists:duplicate(-S, $0)
           end,
    unicode:characters_to_binary([Sign, Body]).

plain(Coeff, 0) -> Coeff;
plain(Coeff, S) when length(Coeff) > S ->
    {I, F} = lists:split(length(Coeff) - S, Coeff),
    I ++ "." ++ F;
plain(Coeff, S) -> "0." ++ lists:duplicate(S - length(Coeff), $0) ++ Coeff.

%%====================================================================
%% Arithmetic
%%====================================================================

add(?D(U1, S1), ?D(U2, S2), MC) ->
    S = max(S1, S2),
    round(?D(U1 * pow10(S - S1) + U2 * pow10(S - S2), S), MC).

sub(A, ?D(U, S), MC) -> add(A, ?D(-U, S), MC).

mul(?D(U1, S1), ?D(U2, S2), MC) -> round(?D(U1 * U2, S1 + S2), MC).

negate(?D(U, S)) -> ?D(-U, S).
abs(?D(U, S)) -> ?D(erlang:abs(U), S).
signum(?D(U, _)) -> sign(U).

%% @doc A / B. Without a precision the quotient is exact, with the
%% preferred scale S1 - S2 (or the smallest larger one that represents it
%% exactly); one that does not terminate raises. With a precision it is
%% rounded to that many digits, trailing zeros stripped back toward the
%% preferred scale.
divide(?D(0, _), ?D(0, _), _) -> arith(<<"Division undefined">>);
divide(_, ?D(0, _), _) -> arith(<<"Division by zero">>);
divide(?D(U1, S1), ?D(U2, S2), MC) ->
    Preferred = S1 - S2,
    case MC of
        {math_context, P, Mode} when P > 0 ->
            %% the value U1/U2 × 10^-Preferred, to P significant digits
            R = round_rational(U1, U2, Preferred, P, Mode),
            strip_toward(R, Preferred);
        _ ->
            G = gcd(erlang:abs(U1), erlang:abs(U2)),
            {N, D0} = {U1 div G, U2 div G},
            {N1, D} = case D0 < 0 of true -> {-N, -D0}; false -> {N, D0} end,
            case two_five(D) of
                {ok, K} -> ?D(N1 * pow10(K) div D, Preferred + K);
                error -> arith(<<"Non-terminating decimal expansion; no exact representable decimal result.">>)
            end
    end.

%% D = 2^a 5^b → {ok, max(a, b)} (the digits the exact quotient needs)
two_five(D) ->
    {A, R1} = strip_factor(D, 2, 0),
    {B, R2} = strip_factor(R1, 5, 0),
    case R2 of
        1 -> {ok, max(A, B)};
        _ -> error
    end.

strip_factor(N, F, C) when N rem F =:= 0 -> strip_factor(N div F, F, C + 1);
strip_factor(N, _, C) -> {C, N}.

%% @doc A rounded to the math context's precision (nil or 0: unchanged)
round(D, nil) -> D;
round(D, {math_context, 0, _}) -> D;
round(?D(U, S) = D, {math_context, P, Mode}) ->
    case digits(U) - P of
        Drop when Drop > 0 ->
            Q = round_div(U, pow10(Drop), Mode),
            %% a carry may add a digit (9.99 → 10.0): drop one more
            case digits(Q) > P of
                true -> ?D(round_div(Q, 10, Mode), S - Drop - 1);
                false -> ?D(Q, S - Drop)
            end;
        _ -> D
    end.

%% N/Dn × 10^-Scale0 rounded to P significant digits
round_rational(N, Dn, Scale0, P, Mode) ->
    {N1, D1} = case Dn < 0 of true -> {-N, -Dn}; false -> {N, Dn} end,
    case N1 of
        0 -> ?D(0, Scale0);
        _ ->
            %% the decimal exponent of |N1/D1|: 10^E =< |N1/D1| < 10^(E+1)
            E = magnitude(erlang:abs(N1), D1),
            Extra = P - 1 - E,                  % digits after the units place of N1/D1
            Q = case Extra >= 0 of
                    true -> round_div(N1 * pow10(Extra), D1, Mode);
                    false -> round_div(N1, D1 * pow10(-Extra), Mode)
                end,
            case digits(Q) > P of
                true -> ?D(round_div(Q, 10, Mode), Scale0 + Extra - 1);
                false -> ?D(Q, Scale0 + Extra)
            end
    end.

magnitude(N, D) ->
    E0 = digits(N) - digits(D),
    case less(N, D, E0) of
        true -> E0 - 1;          % N/D < 10^E0
        false -> E0
    end.

%% N/D < 10^E ?
less(N, D, E) when E >= 0 -> N < D * pow10(E);
less(N, D, E) -> N * pow10(-E) < D.

%% trailing zeros removed while the scale stays above Preferred
strip_toward(?D(U, S), Preferred) when S > Preferred, U rem 10 =:= 0, U =/= 0 ->
    strip_toward(?D(U div 10, S - 1), Preferred);
strip_toward(D, _) -> D.

%% integer division N / D (D > 0) rounded by Mode
round_div(N, D, Mode) when D < 0 -> round_div(-N, -D, Mode);
round_div(N, D, Mode) ->
    Q = N div D,                      % truncated toward zero
    R = N rem D,
    case R of
        0 -> Q;
        _ ->
            Sign = sign(N),
            Twice = 2 * erlang:abs(R),
            Away = case Mode of
                       up -> true;
                       down -> false;
                       ceiling -> Sign > 0;
                       floor -> Sign < 0;
                       half_up -> Twice >= D;
                       half_down -> Twice > D;
                       half_even -> Twice > D orelse (Twice =:= D andalso Q rem 2 =/= 0);
                       unnecessary -> arith(<<"Rounding necessary">>)
                   end,
            case Away of
                true -> Q + Sign;
                false -> Q
            end
    end.

%% @doc (quot a b): the integral part of a/b, scale max(0, S1 - S2)
quot(_, ?D(0, _)) -> arith(<<"Division by zero">>);
quot(?D(U1, S1), ?D(U2, S2)) ->
    {N, D} = ratio(?D(U1, S1), ?D(U2, S2)),
    Q = N div D,
    Preferred = S1 - S2,
    case Preferred >= 0 of
        true -> ?D(Q * pow10(Preferred), Preferred);
        false -> ?D(Q, 0)
    end.

%% @doc (rem a b): a - b × (quot a b)
remainder(A, B) ->
    Q = quot(A, B),
    sub(A, mul(B, ?D(to_integer(Q), 0), nil), nil).

ratio(A, B) ->
    {N1, D1} = to_rational(A),
    {N2, D2} = to_rational(B),
    {N, D} = {N1 * D2, D1 * N2},
    case D < 0 of true -> {-N, -D}; false -> {N, D} end.

%%====================================================================
%% Comparison, conversion, BigDecimal methods
%%====================================================================

compare(A, B) ->
    {N1, D1} = to_rational(A),
    {N2, D2} = to_rational(B),
    sign(N1 * D2 - N2 * D1).

%% = between two decimals is by value: 1.0M equals 1.00M
equals(A, B) -> compare(A, B) =:= 0.

%% @doc the exact value as an integer or a ratio in lowest terms
to_ratio(D) ->
    {N, Den} = to_rational(D),
    G = gcd(erlang:abs(N), Den),
    case Den div G of
        1 -> N div G;
        Den1 -> {ratio, N div G, Den1}
    end.

to_rational(?D(U, S)) when S >= 0 -> {U, pow10(S)};
to_rational(?D(U, S)) -> {U * pow10(-S), 1}.

%% the nearest double (correctly rounded by the float parser)
to_float(?D(U, S)) ->
    try list_to_float(integer_to_list(U) ++ ".0e" ++ integer_to_list(-S))
    catch error:badarg -> arith(<<"BigDecimal out of the double range">>)
    end.

%% truncated toward zero, as longValue/toBigInteger
to_integer(?D(U, S)) when S >= 0 -> U div pow10(S);
to_integer(?D(U, S)) -> U * pow10(-S).

scale(?D(_, S)) -> S.
unscaled(?D(U, _)) -> U.
precision(?D(U, _)) -> digits(U).

set_scale(?D(U, S), NewS, _Mode) when NewS >= S -> ?D(U * pow10(NewS - S), NewS);
set_scale(?D(U, S), NewS, Mode) -> ?D(round_div(U, pow10(S - NewS), rounding_mode(Mode)), NewS).

strip_trailing_zeros(?D(0, _)) -> ?D(0, 0);
strip_trailing_zeros(?D(U, S)) when U rem 10 =:= 0 -> strip_trailing_zeros(?D(U div 10, S - 1));
strip_trailing_zeros(D) -> D.

%% equal values hash alike: the hash of the value without trailing zeros
%% (BigDecimal.hashCode of stripTrailingZeros)
hash(D) ->
    ?D(U, S) = strip_trailing_zeros(D),
    clj2_hash:signed(31 * clj2_hash:big_integer_hash_code(U) + S).

%%====================================================================
%% Helpers
%%====================================================================

digits(0) -> 1;
digits(N) -> length(integer_to_list(erlang:abs(N))).

pow10(0) -> 1;
pow10(N) when N > 0 -> pow10(N, 1).
pow10(0, Acc) -> Acc;
pow10(N, Acc) -> pow10(N - 1, Acc * 10).

gcd(A, 0) -> A;
gcd(A, B) -> gcd(B, A rem B).

sign(N) when N < 0 -> -1;
sign(N) when N > 0 -> 1;
sign(_) -> 0.

arith(Msg) ->
    erlang:error(clj2_rt:ex_info(Msg, clj2_coll:hash_map_kv([':type', ':ArithmeticException']), nil)).
