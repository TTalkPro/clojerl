%%%-------------------------------------------------------------------
%%% @doc clj2_rt — runtime support called by compiled code.
%%%
%%% Only the slow path of invoke for now (designs/02 calling
%%% convention, see clj2_p_emit). IFn on keywords/maps/vars arrives
%%% with the D8 data structures and clojerl2-015.
%%%-------------------------------------------------------------------
-module(clj2_rt).

-export([invoke/2, var_fn/3, var/2]).

%% layer-0 primitives for clojure.core (00-kernel)
-export([str/1, keyword/1, keyword/2, symbol/1, symbol/2, name/1, namespace/1,
         gensym/1, apply/2, is_keyword/1, is_symbol/1, is_fn/1, identical/2, divide/2]).

%% layer-0 primitives for 01-core (clojerl2-021)
-export([str_contains/2]).
-export([reduced/1, is_reduced/1, unreduced/1, compare/2, sort/2, format/2,
         ex_info/3, is_ex_info/1, ex_message/1, ex_data/1, ex_cause/1, subs/3]).

%% @doc Call a Clojure fn value with an argument list.
invoke(F, Args) when is_function(F, length(Args)) ->
    erlang:apply(F, Args);
invoke({clj2_fn, Fixed, Var} = F, Args) ->
    N = length(Args),
    case Fixed of
        #{N := Fun} -> erlang:apply(Fun, Args);
        _ ->
            case Var of
                {Min, Fun} when N >= Min ->
                    {Req, Rest} = lists:split(Min, Args),
                    erlang:apply(Fun, Req ++ [rest(Rest)]);
                _ -> erlang:error({clj2_arity, N, F})
            end
    end;
invoke(F, Args) when is_function(F) ->
    erlang:error({clj2_arity, length(Args), F});
%% IFn of data: (:k m) (m k) (s x) (v i), with an optional not-found
invoke(K, [Coll]) when is_atom(K), K =/= nil, K =/= true, K =/= false -> clj2_coll:get(Coll, K);
invoke(K, [Coll, NotFound]) when is_atom(K), K =/= nil, K =/= true, K =/= false ->
    clj2_coll:get(Coll, K, NotFound);
invoke({Tag, _, _} = Coll, [K]) when Tag =:= map; Tag =:= set -> clj2_coll:get(Coll, K);
invoke({Tag, _, _} = Coll, [K, NotFound]) when Tag =:= map; Tag =:= set -> clj2_coll:get(Coll, K, NotFound);
invoke({vector, _, _} = V, [I]) -> clj2_coll:nth(V, I);
invoke(X, _Args) ->
    erlang:error({clj2_not_ifn, X}).

%% @doc The fn value of a fn var (what `fn_var' builds in compiled code).
var_fn(M, Name, #{kind := fn, arities := Fixed, variadic := Min}) ->
    Ref = fun(N) -> erlang:make_fun(M, Name, N) end,
    case {Fixed, Min} of
        {[N], nil} -> Ref(N);
        _ -> {clj2_fn, maps:from_list([{N, Ref(N)} || N <- Fixed]),
              case Min of
                  nil -> nil;
                  _ -> {Min, Ref(Min + 1)}
              end}
    end.

%% Clojure: no extra arguments → the rest param is nil.
rest([]) -> nil;
rest(L) -> L.

%%====================================================================
%% Layer-0 primitives (symbols, keywords, strings)
%%====================================================================

%% @doc `str' of a list of values (nil prints as nothing).
str(Xs) -> iolist_to_binary([str1(X) || X <- clj2_coll:to_list(Xs)]).

str1(nil) -> <<>>;
str1(B) when is_binary(B) -> B;
str1(A) when is_atom(A) -> atom_to_binary(A);           % symbols, keywords (':k'), true/false
str1(I) when is_integer(I) -> integer_to_binary(I);
str1(F) when is_float(F) -> clj2_print:float_str(F);
str1({Tag, _, S}) when (Tag =:= regex orelse Tag =:= uuid), is_binary(S) -> S;
str1(X) -> clj2_print:pr_str(X).                         % collections, records, ...

is_keyword(X) -> is_atom(X) andalso X =/= nil andalso X =/= true andalso X =/= false
                     andalso X =/= ':' andalso hd(atom_to_list(X)) =:= $:.

identical(X, Y) -> X =:= Y.

is_fn(F) when is_function(F) -> true;
is_fn({clj2_fn, _, _}) -> true;
is_fn(_) -> false.

is_symbol(X) -> is_atom(X) andalso X =/= nil andalso X =/= true andalso X =/= false
                    andalso not is_keyword(X).

keyword(K) when is_atom(K) ->
    case is_keyword(K) of
        true -> K;
        false -> binary_to_atom(<<$:, (atom_to_binary(K))/binary>>)
    end;
keyword(B) when is_binary(B) -> binary_to_atom(<<$:, B/binary>>).

keyword(nil, Name) -> keyword(Name);
keyword(Ns, Name) -> binary_to_atom(<<$:, (str1(Ns))/binary, $/, (str1(Name))/binary>>).

symbol(S) when is_atom(S) -> S;
symbol(B) when is_binary(B) -> binary_to_atom(B).

symbol(nil, Name) -> symbol(Name);
symbol(Ns, Name) -> binary_to_atom(<<(str1(Ns))/binary, $/, (str1(Name))/binary>>).

%% @doc name of a symbol or keyword (without namespace), or a string.
name(B) when is_binary(B) -> B;
name(A) when is_atom(A) ->
    Bin = strip_colon(A),
    case binary:split(Bin, <<"/">>) of
        [_, N] when N =/= <<>> -> N;
        _ -> Bin
    end.

namespace(A) when is_atom(A) ->
    case binary:split(strip_colon(A), <<"/">>) of
        [Ns, N] when Ns =/= <<>>, N =/= <<>> -> Ns;
        _ -> nil
    end.

strip_colon(A) ->
    case is_keyword(A) of
        true -> <<_, B/binary>> = atom_to_binary(A), B;
        false -> atom_to_binary(A)
    end.

gensym(Prefix) ->
    binary_to_atom(<<(str1(Prefix))/binary, (integer_to_binary(erlang:unique_integer([positive])))/binary>>).

%% @doc (apply f a b args): the last argument is a seqable.
apply(F, Args) ->
    {Init, [Last]} = lists:split(length(Args) - 1, Args),
    invoke(F, Init ++ clj2_coll:to_list(Last)).

%% @doc `/' on integers stays exact when it divides, else a float
%% (no ratio arithmetic yet: registered divergence).
divide(X, Y) when is_integer(X), is_integer(Y), Y =/= 0, X rem Y =:= 0 -> X div Y;
divide(X, Y) -> X / Y.

%%====================================================================
%% Layer-0 primitives for 01-core
%%====================================================================

str_contains(S, Sub) -> binary:match(S, Sub) =/= nomatch.

%% reduce's early exit (transducers, reduce over a reduced value)
reduced(X) -> {clj2_reduced, X}.
is_reduced({clj2_reduced, _}) -> true;
is_reduced(_) -> false.
unreduced({clj2_reduced, X}) -> X;
unreduced(X) -> X.

%% @doc Clojure `compare': -1/0/1; nil sorts first; numbers by value;
%% strings, symbols, keywords lexically; vectors by length then elements.
compare(X, X) -> 0;
compare(nil, _) -> -1;
compare(_, nil) -> 1;
compare(X, Y) when is_number(X), is_number(Y) -> sign(X - Y);
compare(X, Y) when is_binary(X), is_binary(Y) -> lex(X, Y);
compare(X, Y) when is_atom(X), is_atom(Y) -> lex(atom_to_binary(X), atom_to_binary(Y));
compare({vector, _, A}, {vector, _, B}) when tuple_size(A) =/= tuple_size(B) ->
    sign(tuple_size(A) - tuple_size(B));
compare({vector, _, A}, {vector, _, B}) -> compare_elems(tuple_to_list(A), tuple_to_list(B));
compare(X, Y) -> erlang:error({clj2_cannot_compare, X, Y}).

compare_elems([], []) -> 0;
compare_elems([X | Xs], [Y | Ys]) ->
    case compare(X, Y) of
        0 -> compare_elems(Xs, Ys);
        C -> C
    end.

lex(A, B) when A < B -> -1;
lex(A, A) -> 0;
lex(_, _) -> 1.

sign(N) when N < 0 -> -1;
sign(N) when N > 0 -> 1;
sign(_) -> 0.

%% @doc Stable sort with a Clojure comparator: a boolean "less than"
%% fn, or one returning a number.
sort(Cmp, Coll) ->
    L = clj2_coll:to_list(Coll),
    Le = fun(A, B) ->
                 case invoke(Cmp, [A, B]) of
                     true -> true;
                     false -> not (invoke(Cmp, [B, A]) =:= true);
                     N when is_number(N) -> N =< 0
                 end
         end,
    lists:sort(Le, L).

%% @doc A subset of java.util.Formatter: %s %d %f %.Nf %x %X %o %e %b %c %n %%.
%% Works on code points (the format string decoded, arguments as
%% chardata) and encodes the result once: padding counts characters.
format(Fmt, Args) when is_binary(Fmt) ->
    unicode:characters_to_binary(fmt(unicode:characters_to_list(Fmt), clj2_coll:to_list(Args))).

fmt([], _) -> [];
fmt("%%" ++ R, As) -> [$% | fmt(R, As)];
fmt("%n" ++ R, As) -> [$\n | fmt(R, As)];
fmt([$% | R], As) ->
    {Spec, Conv, Rest} = spec(R, []),
    [A | As1] = As,
    [pad(Spec, conv(Conv, Spec, A)) | fmt(Rest, As1)];
fmt([C | R], As) -> [C | fmt(R, As)].

spec([C | R], Acc) when C >= $0, C =< $9; C =:= $.; C =:= $-; C =:= $+; C =:= $, ->
    spec(R, [C | Acc]);
spec([C | R], Acc) -> {lists:reverse(Acc), C, R}.

conv($s, _, A) -> str1(A);
conv($d, _, A) -> integer_to_list(A);
conv($x, _, A) -> string:lowercase(integer_to_list(A, 16));
conv($X, _, A) -> integer_to_list(A, 16);
conv($o, _, A) -> integer_to_list(A, 8);
conv($b, _, A) -> atom_to_list(A =/= false andalso A =/= nil);
conv($c, _, A) -> unicode:characters_to_list([A]);
conv($e, Spec, A) -> io_lib:format("~." ++ integer_to_list(precision(Spec, 6) + 1) ++ "e", [float(A)]);
conv($f, Spec, A) -> io_lib:format("~." ++ integer_to_list(precision(Spec, 6)) ++ "f", [float(A)]).

precision(Spec, Default) ->
    case string:split(Spec, ".") of
        [_, P] when P =/= "" -> list_to_integer(P);
        _ -> Default
    end.

pad(Spec, S) ->
    Flat = unicode:characters_to_list(S),
    W = case string:split(Spec, ".") of
            [Wd | _] -> list_to_integer("0" ++ [C || C <- Wd, C >= $0, C =< $9]);
            _ -> 0
        end,
    ZeroPad = W > 0 andalso lists:prefix("0", Spec),
    case lists:member($-, Spec) of
        true -> string:pad(Flat, W, trailing);
        false when ZeroPad -> string:pad(Flat, W, leading, $0);
        false -> string:pad(Flat, W, leading)
    end.

%% ex-info: a record-shaped value, thrown with erlang:error
ex_info(Msg, Data, Cause) ->
    {'clojure.lang.ExceptionInfo', nil, #{':message' => Msg, ':data' => Data, ':cause' => Cause}}.
is_ex_info({'clojure.lang.ExceptionInfo', _, _}) -> true;
is_ex_info(_) -> false.
ex_message({'clojure.lang.ExceptionInfo', _, #{':message' := M}}) -> M;
ex_message(_) -> nil.
ex_data({'clojure.lang.ExceptionInfo', _, #{':data' := D}}) -> D;
ex_data(_) -> nil.
ex_cause({'clojure.lang.ExceptionInfo', _, #{':cause' := C}}) -> C;
ex_cause(_) -> nil.

%% (subs s start end) on characters (grapheme-agnostic: code points)
subs(S, Start, End) ->
    Cs = unicode:characters_to_list(S),
    End1 = case End of nil -> length(Cs); _ -> End end,
    (Start >= 0 andalso Start =< End1 andalso End1 =< length(Cs))
        orelse erlang:error({clj2_string_index_out_of_bounds, Start, End1}),
    unicode:characters_to_binary(lists:sublist(Cs, Start + 1, End1 - Start)).

%% @doc A var as a value (what def returns): #'ns/name.
var(Ns, Name) -> {var, nil, {Ns, Name}}.
