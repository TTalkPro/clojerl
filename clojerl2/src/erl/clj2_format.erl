%%%-------------------------------------------------------------------
%%% @doc clj2_format — clojure.core/format: java.util.Formatter's grammar
%%% `%[index$][flags][width][.precision]conversion' (clojerl2-020).
%%%
%%% Conversions: %b %B %h %H %s %S %c %C %d %o %x %X %e %E %f %g %G %a %A
%%% %n %%; `%<s' reuses the previous argument, `%2$s' names one. Flags:
%%% - # + space 0 , ( . Decimal floats round HALF_UP on the shortest
%%% round-trip digits of the double, as Formatter does (2.675 at %.2f is
%%% "2.68", not the binary value's "2.67"); semantics follow jolt's
%%% natives-format.ss, which documents the JVM's behaviour in detail.
%%%
%%% Integers are unbounded and %x/%o of a negative number is signed
%%% (known divergence :number/beam-semantics); %t needs a date type and
%%% is refused. A conversion given the wrong kind of argument, a missing
%%% argument, an unknown conversion or a flag it cannot take raise
%%% ex-infos named like the JVM exceptions.
%%%-------------------------------------------------------------------
-module(clj2_format).

-export([format/2]).

format(Fmt, Args) when is_binary(Fmt) ->
    Out = run(unicode:characters_to_list(Fmt), clj2_coll:to_list(Args), 1, none),
    unicode:characters_to_binary(Out).

%% Next: the next ordinary argument (1-based); Last: the last one used (%<)
run([], _, _, _) -> [];
run([$% | R], Args, Next, Last) ->
    {Spec, Rest} = parse(R),
    case Spec of
        #{conv := $%} -> [justify(Spec, "%") | run(Rest, Args, Next, Last)];
        #{conv := $n} -> [$\n | run(Rest, Args, Next, Last)];
        _ ->
            {I, Next1} = case Spec of
                             #{index := prev} when Last =:= none -> fail(missing, "%<");
                             #{index := prev} -> {Last, Next};
                             #{index := N} when is_integer(N) -> {N, Next};
                             _ -> {Next, Next + 1}
                         end,
            I =< length(Args) orelse fail(missing, spec_text(Spec)),
            [convert(Spec, lists:nth(I, Args)) | run(Rest, Args, Next1, I)]
    end;
run([C | R], Args, Next, Last) -> [C | run(R, Args, Next, Last)].

%%====================================================================
%% Parsing a specifier
%%====================================================================

parse(R0) ->
    {Index, R1} = index(R0),
    {Flags, R2} = lists:splitwith(fun(C) -> lists:member(C, "-#+ 0,(") end, R1),
    {W, R3} = lists:splitwith(fun is_digit/1, R2),
    {P, R4} = case R3 of
                  [$. | T] ->
                      {Ds, T1} = lists:splitwith(fun is_digit/1, T),
                      Ds =/= [] orelse fail(unknown, [$. | T]),
                      {list_to_integer(Ds), T1};
                  _ -> {none, R3}
              end,
    case R4 of
        [Conv | Rest] ->
            {#{index => Index, flags => Flags, width => to_int(W), prec => P, conv => Conv,
               text => [$% | lists:sublist(R0, length(R0) - length(Rest))]}, Rest};
        [] -> fail(unknown, "%")
    end.

index([$< | R]) -> {prev, R};
index(R) ->
    {Ds, T} = lists:splitwith(fun is_digit/1, R),
    case {Ds, T} of
        {[_ | _], [$$ | T1]} -> {list_to_integer(Ds), T1};
        _ -> {next, R}
    end.

is_digit(C) -> C >= $0 andalso C =< $9.
to_int([]) -> none;
to_int(Ds) -> list_to_integer(Ds).

spec_text(#{text := T}) -> T.

%%====================================================================
%% Conversions
%%====================================================================

convert(S = #{conv := C}, A) when C =:= $b; C =:= $B ->
    no_flags(S, "#+ 0,("),
    T = case A of
            nil -> "false";
            false -> "false";
            _ -> "true"
        end,
    justify(S, upper(C, truncate(S, T)));
convert(S = #{conv := C}, A) when C =:= $h; C =:= $H ->
    no_flags(S, "#+ 0,("),
    T = case A of
            nil -> "null";
            _ -> integer_to_list(clj2_hash:java_hash_code(A) band 16#FFFFFFFF, 16)    % Integer.toHexString(hashCode)
        end,
    justify(S, upper(C, truncate(S, string:lowercase(T))));
convert(S = #{conv := C}, A) when C =:= $s; C =:= $S ->
    %% # is only for java.util.Formattable, which nothing here is
    no_flags(S, "#+ 0,("),
    T = case A of
            nil -> "null";
            _ -> unicode:characters_to_list(clj2_rt:str([A]))
        end,
    justify(S, upper(C, truncate(S, T)));
convert(S = #{conv := C}, A) when C =:= $c; C =:= $C ->
    no_flags(S, "#+ 0,("),
    S1 = no_prec(S),
    T = case A of
            nil -> "null";
            Cp when is_integer(Cp), Cp >= 0, Cp =< 16#10FFFF -> [Cp];
            _ -> wrong_kind(S1, A)
        end,
    justify(S1, upper(C, T));
convert(S = #{conv := $d}, A) ->
    no_flags(S, "#"),
    S1 = no_prec(S),
    case A of
        nil -> justify(S1, "null");
        I when is_integer(I) -> number(S1, I < 0, group(S1, integer_to_list(abs(I))));
        _ -> wrong_kind(S1, A)
    end;
convert(S = #{conv := C}, A) when C =:= $o; C =:= $x; C =:= $X ->
    no_flags(S, " ,"),
    S1 = no_prec(S),
    case A of
        nil -> justify(S1, "null");
        I when is_integer(I) ->
            Radix = case C of $o -> 8; _ -> 16 end,
            Digits = string:lowercase(integer_to_list(abs(I), Radix)),
            Alt = case {has(S1, $#), C} of
                      {false, _} -> "";
                      {true, $o} -> "0";
                      {true, _} -> "0x"
                  end,
            upper(C, number(S1, I < 0, Alt ++ Digits));
        _ -> wrong_kind(S1, A)
    end;
convert(S = #{conv := C}, A) when C =:= $e; C =:= $E ->
    no_flags(S, ","),
    float_conv(S, A, fun(X, P) -> sci(X, P) end);
convert(S = #{conv := $f}, A) ->
    float_conv(S, A, fun(X, P) -> group(S, fixed(X, P)) end);
convert(S = #{conv := C}, A) when C =:= $g; C =:= $G ->
    no_flags(S, "#"),
    float_conv(S, A, fun(X, P0) ->
                             P = case P0 of 0 -> 1; _ -> P0 end,
                             general(S, X, P)
                     end);
convert(S = #{conv := C}, A) when C =:= $a; C =:= $A ->
    no_flags(S, ",("),
    case A of
        nil -> justify(S, "null");
        X when is_float(X) -> upper(C, number(S, sign_bit(X), hexfloat(abs(X), maps:get(prec, S))));
        _ -> wrong_kind(S, A)
    end;
convert(S = #{conv := C}, _) when C =:= $t; C =:= $T ->
    fail(conversion, spec_text(S), <<"date/time conversions need a date type, which clojerl2 does not have">>);
convert(S, _) -> fail(unknown, spec_text(S)).

%% %e %f %g: a float (an integer is the JVM's IllegalFormatConversion);
%% precision defaults to 6
float_conv(S, A, F) ->
    case A of
        nil -> justify(S, "null");
        X when is_float(X) ->
            P = case maps:get(prec, S) of none -> 6; Pr -> Pr end,
            upper(maps:get(conv, S), number(S, sign_bit(X), F(abs(X), P)));
        _ -> wrong_kind(S, A)
    end.

sign_bit(X) -> X < 0.0 orelse <<X/float>> =:= <<-0.0/float>>.

%%--------------------------------------------------------------------
%% sign, grouping, zero padding, justification

%% Body: the digits of the magnitude; Neg: is the value negative
number(S, Neg, Body) ->
    {Pre, Post} = case {Neg, has(S, $(), has(S, $+), has(S, $\s)} of
                      {true, true, _, _} -> {"(", ")"};
                      {true, false, _, _} -> {"-", ""};
                      {false, _, true, _} -> {"+", ""};
                      {false, _, _, true} -> {" ", ""};
                      _ -> {"", ""}
                  end,
    case has(S, $0) of
        true ->
            W = maps:get(width, S),
            W =:= none andalso fail(missing_width, spec_text(S)),
            Fill = W - length(Pre) - length(Body) - length(Post),
            Pre ++ lists:duplicate(max(0, Fill), $0) ++ Body ++ Post;
        false -> justify(S, Pre ++ Body ++ Post)
    end.

justify(S, T) ->
    case maps:get(width, S) of
        none -> T;
        W ->
            Pad = lists:duplicate(max(0, W - string:length(T)), $\s),
            case has(S, $-) of
                true -> T ++ Pad;
                false -> Pad ++ T
            end
    end.

%% "," groups the integer part in threes
group(S, Digits) ->
    case has(S, $,) of
        false -> Digits;
        true ->
            {Int, Frac} = lists:splitwith(fun(C) -> C =/= $. end, Digits),
            Rev = lists:reverse(Int),
            Grouped = lists:reverse(lists:append(
                        [case I rem 3 =:= 0 andalso I > 0 of
                             true -> [$,, D];
                             false -> [D]
                         end || {I, D} <- lists:zip(lists:seq(0, length(Rev) - 1), Rev)])),
            Grouped ++ Frac
    end.

has(#{flags := F}, C) -> lists:member(C, F).

truncate(#{prec := none}, T) -> T;
truncate(#{prec := P}, T) -> string:slice(T, 0, P).

upper(C, T) when C >= $A, C =< $Z -> string:uppercase(T);
upper(_, T) -> T.

no_flags(S = #{flags := F}, Bad) ->
    %% flags that exclude each other, whatever the conversion
    case (lists:member($-, F) andalso lists:member($0, F)) orelse
         (lists:member($+, F) andalso lists:member($\s, F)) of
        true -> raise(<<"IllegalFormatFlagsException">>, ["Flags = '", F, "'"]);
        false -> ok
    end,
    case [C || C <- F, lists:member(C, Bad)] of
        [] -> ok;
        [C | _] -> fail(flags, spec_text(S), [C])
    end,
    case has(S, $-) andalso maps:get(width, S) =:= none of
        true -> fail(missing_width, spec_text(S));
        false -> ok
    end.

no_prec(S = #{prec := none}) -> S;
no_prec(S) -> fail(precision, spec_text(S)).

%%--------------------------------------------------------------------
%% decimal digits, HALF_UP on the shortest round-trip representation

%% → {D, L, E}: the shortest round-trip digits of X >= 0 as an integer D
%% of L digits, with X = 0.D * 10^E (D has no leading or trailing zeros)
shortest(X) when X == 0.0 -> {0, 1, 1};
shortest(X) ->
    {Mant, Ex} = case string:split(float_to_list(X, [short]), "e") of
                     [M, E] -> {M, list_to_integer(E)};
                     [M] -> {M, 0}
                 end,
    {I, F} = case string:split(Mant, ".") of
                 [I0, F0] -> {I0, F0};
                 [I0] -> {I0, ""}
             end,
    Raw = I ++ F,
    Lead = length(Raw) - length(string:trim(Raw, leading, "0")),
    Ds = string:trim(string:trim(Raw, leading, "0"), trailing, "0"),
    {list_to_integer(Ds), length(Ds), length(I) + Ex - Lead}.

%% D * 10^Shift rounded HALF_UP to an integer (D >= 0)
scale(D, Shift) when Shift >= 0 -> D * pow10(Shift);
scale(D, Shift) -> Div = pow10(-Shift), (D + Div div 2) div Div.

pow10(N) -> pow10(N, 1).
pow10(0, Acc) -> Acc;
pow10(N, Acc) -> pow10(N - 1, Acc * 10).

%% %f: P decimals
fixed(X, P) ->
    {D, L, E} = shortest(X),
    N = scale(D, E - L + P),                   % X * 10^P, rounded
    Txt = pad_left(integer_to_list(N), P + 1),
    {Int, Frac} = lists:split(length(Txt) - P, Txt),
    Int ++ frac(Frac).

%% %e: one digit before the point, P after; exponent sign and >= 2 digits
sci(X, P) when X == 0.0 -> "0" ++ frac(lists:duplicate(P, $0)) ++ "e+00";
sci(X, P) ->
    {D, L, E} = shortest(X),
    N0 = scale(D, P + 1 - L),                  % P + 1 significant digits
    {N, Carry} = case length(integer_to_list(N0)) > P + 1 of
                     true -> {N0 div 10, 1};
                     false -> {N0, 0}
                 end,
    [H | T] = integer_to_list(N),
    [H] ++ frac(T) ++ exp_text(E - 1 + Carry).

exp_text(E) when E < 0 -> "e-" ++ pad_left(integer_to_list(-E), 2);
exp_text(E) -> "e+" ++ pad_left(integer_to_list(E), 2).

%% %g: P significant digits; as %f when 10^-4 <= rounded value < 10^P,
%% else as %e (trailing zeros kept, as the JVM does)
general(S, X, P) when X == 0.0 -> group(S, fixed(X, P - 1));
general(S, X, P) ->
    {D, L, E} = shortest(X),
    N0 = scale(D, P - L),
    Mag = case length(integer_to_list(N0)) > P of
              true -> E + 1;                     % rounding carried: 9.99 -> 10.0
              false -> E
          end,
    case Mag >= -3 andalso Mag =< P of
        true -> group(S, fixed(X, P - Mag));
        false -> sci(X, P - 1)
    end.

pad_left(S, N) -> lists:duplicate(max(0, N - length(S)), $0) ++ S.
pad_right(S, N) -> S ++ lists:duplicate(max(0, N - length(S)), $0).

frac([]) -> [];
frac(F) -> [$. | F].

%%--------------------------------------------------------------------
%% %a: hexadecimal floating point, as Double.toHexString

hexfloat(+0.0, _) -> "0x0.0p0";
hexfloat(X, Prec) ->
    <<0:1, BE:11, M:52>> = <<X/float>>,
    {Lead, E} = case BE of
                    0 -> {"0", -1022};
                    _ -> {"1", BE - 1023}
                end,
    Hex = pad_left(string:lowercase(integer_to_list(M, 16)), 13),
    {Lead1, Frac} = case Prec of
                        none -> {Lead, case string:trim(Hex, trailing, "0") of [] -> "0"; H -> H end};
                        _ -> round_hex(Lead, Hex, max(Prec, 1))
                    end,
    "0x" ++ Lead1 ++ "." ++ Frac ++ "p" ++ integer_to_list(E).

round_hex(Lead, Hex, P) when P >= 13 -> {Lead, pad_right(Hex, P)};
round_hex(Lead, Hex, P) ->
    {Keep, [D | _]} = lists:split(P, Hex),
    V = list_to_integer(Lead ++ Keep, 16) + case list_to_integer([D], 16) >= 8 of true -> 1; false -> 0 end,
    All = string:lowercase(integer_to_list(V, 16)),
    All1 = pad_left(All, P + 1),
    {lists:sublist(All1, length(All1) - P), lists:nthtail(length(All1) - P, All1)}.

%%====================================================================
%% Errors, named after the JVM's
%%====================================================================

wrong_kind(#{conv := C}, A) ->
    fail(conversion, [C], iolist_to_binary([C, " != ", clj2_print:pr_str(A)])).

fail(missing, Spec) -> raise(<<"MissingFormatArgumentException">>, ["Format specifier '", Spec, "'"]);
fail(unknown, Spec) -> raise(<<"UnknownFormatConversionException">>, ["Conversion = '", Spec, "'"]);
fail(precision, Spec) -> raise(<<"IllegalFormatPrecisionException">>, Spec);
fail(missing_width, Spec) -> raise(<<"MissingFormatWidthException">>, Spec).

fail(flags, _Spec, Flag) -> raise(<<"FormatFlagsConversionMismatchException">>, ["Conversion = ", Flag]);
fail(conversion, _Spec, Msg) -> raise(<<"IllegalFormatConversionException">>, Msg).

raise(Class, Msg) ->
    M = unicode:characters_to_binary(Msg),
    erlang:error(clj2_rt:ex_info(M, clj2_coll:hash_map_kv([':type', binary_to_atom(<<":", Class/binary>>)]), nil)).
