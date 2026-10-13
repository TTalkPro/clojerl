%%%-------------------------------------------------------------------
%%% @doc clj2_rt — runtime support called by compiled code.
%%%
%%% Only the slow path of invoke for now (designs/02 calling
%%% convention, see clj2_p_emit). IFn on keywords/maps/vars arrives
%%% with the D8 data structures and clojerl2-015.
%%%-------------------------------------------------------------------
-module(clj2_rt).

-export([transient/1, is_transient/1, persistent/1]).
-export([meta/1, with_meta/2, is_var/1, merge_var_meta/2, defn_meta/3]).
-export([invoke/2, call_loading/3, fn_const/1, var_fn/3, var_value/3, var/2, is_ratio/1, numerator/1, denominator/1, existing_keyword/2]).

%% layer-0 primitives for clojure.core (00-kernel)
-export([str/1, keyword/1, keyword/2, symbol/1, symbol/2, name/1, namespace/1,
         gensym/1, apply/2, is_keyword/1, is_symbol/1, is_fn/1, is_ifn/1, identical/2, divide/2]).

%% layer-0 primitives for 01-core (clojerl2-021)
-export([str_contains/2]).
-export([unsupported_float/1, unsupported_tag/1]).
-export([not_number/1, refine_error/3, num_compare/3, num_op/3, num_quot/2, num_rem/2, is_boxed_number/1, tagged_literal/2, is_tagged_literal/1,
         reader_conditional/2, is_reader_conditional/1]).
-export([def_root/2, invoke_root/4, set_var_root/2, assign_root/3, alter_var_root/3, var_root/1, table_root/1,
         set_var_validator/2, var_validator/1, update_var_watches/2]).
-export([reduced/1, is_reduced/1, unreduced/1, compare/2, sort/2, format/2,
         ex_info/3, exception_str/1, throwable/2, no_matching_clause/1, is_ex_info/1, ex_message/1, ex_data/1, ex_cause/1, subs/3]).

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
invoke({multifn, _, _} = MF, Args) -> clj2_multi:invoke(MF, Args);
invoke({promise, _, _} = P, [V]) -> clj2_ref:deliver(P, V);          % a promise delivers when called
invoke({fnmeta, _, F}, Args) -> invoke(F, Args);
invoke({transient, _, C}, Args) -> invoke(C, Args);                       % lookup on a transient
invoke({var, _, {_, _}} = V, Args) -> invoke(clj2_ref:deref(V), Args);     % a var calls its value
invoke({Tag, _, {_, _, _}} = S, [K]) when Tag =:= sorted_map; Tag =:= sorted_set -> clj2_coll:get(S, K);
invoke({Tag, _, {_, _, _}} = S, [K, NF]) when Tag =:= sorted_map; Tag =:= sorted_set -> clj2_coll:get(S, K, NF);
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

%% @doc The value of a var given its module and VarInfo: a fn var's fn,
%% a cell's root, otherwise what its accessor returns.
var_value(M, Name, Info) ->
    case get({clj2_loading, M}) of
        %% this process is running M's init: M's exports are undef until
        %% it returns, so the value comes through M's local '__var__'/1
        F when is_function(F, 1) -> F(Name);
        _ -> loaded_var_value(M, Name, Info)
    end.

%% the same value compiled code takes in value position (M:'__fn__'/1),
%% so (identical? > (var-get #'>)) holds
loaded_var_value(M, Name, #{kind := fn} = Info) ->
    case erlang:function_exported(M, '__fn__', 1) of
        true -> try M:'__fn__'(Name) catch error:function_clause -> var_fn(M, Name, Info) end;
        false -> var_fn(M, Name, Info)
    end;
loaded_var_value(M, Name, #{kind := cell}) -> clj2_var:root(M, Name);
loaded_var_value(M, Name, _Info) -> M:Name().

%% @doc A fn value a macro spliced into code (clj2_p_parse)
fn_const(Key) -> persistent_term:get({clj2_fn_const, Key}).

%% @doc M:Name(Args...) from a deftype/extend method of M's namespace:
%% while M's init runs (the method called at load time) M's exports are
%% undef, and the fn comes from M's local '__var__'/1 (var_value/3)
call_loading(M, Name, Args) ->
    case get({clj2_loading, M}) of
        F when is_function(F, 1) -> erlang:apply(arity_fun(F(Name), length(Args)), Args);
        _ -> erlang:apply(M, Name, Args)
    end.

arity_fun(F, N) when is_function(F, N) -> F;
arity_fun({clj2_fn, Fixed, Var}, N) ->
    case Fixed of
        #{N := F} -> F;
        _ -> element(2, Var)
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
str1({decimal, _, _} = D) -> clj2_decimal:to_string(D);
str1(A) when is_atom(A) -> atom_to_binary(A);           % symbols, keywords (':k'), true/false
str1(I) when is_integer(I) -> integer_to_binary(I);
str1(F) when is_float(F) -> clj2_print:float_str(F);
str1({Tag, _, S}) when (Tag =:= regex orelse Tag =:= uuid), is_binary(S) -> S;
str1({'java.lang.StringBuilder', _, _} = B) -> clj2_jvm:builder_text(B);
%% Throwable.toString: "class: message"; an ExceptionInfo adds its data
str1({'clojure.lang.ExceptionInfo', _, _} = E) -> exception_str(E);
%% a deftype or defrecord with its own toString
str1({Tag, _, _} = X) when is_atom(Tag) ->
    case clj2_proto:object_method(X, toString) of
        {ok, F} -> invoke(F, [X]);
        error -> clj2_print:pr_str(X)
    end;
str1(X) -> clj2_print:pr_str(X).                         % collections, records, ...

%% @doc An exception as str (and Throwable.toString) shows it
exception_str(E) ->
    Class = atom_to_binary(clj2_class:exception_class(E)),
    case {ex_message(E), Class} of
        {nil, _} -> Class;
        {M, <<"clojure.lang.ExceptionInfo">>} ->
            iolist_to_binary([Class, ": ", M, " ", clj2_print:pr_str(ex_data(E))]);
        {M, _} -> iolist_to_binary([Class, ": ", M])
    end.

is_keyword(X) -> is_atom(X) andalso X =/= nil andalso X =/= true andalso X =/= false
                     andalso X =/= ':' andalso X =/= '' andalso hd(atom_to_list(X)) =:= $:.

identical(X, Y) -> X =:= Y.

%% @doc ifn?: what invoke takes (fns, keywords, symbols, maps, sets,
%% vectors, vars, multimethods, transients of those)
is_ifn(X) when is_atom(X) -> X =/= nil andalso X =/= true andalso X =/= false;
is_ifn({Tag, _, _}) when Tag =:= map; Tag =:= set; Tag =:= vector; Tag =:= var; Tag =:= multifn; Tag =:= promise;
                         Tag =:= sorted_map; Tag =:= sorted_set; Tag =:= transient -> true;
is_ifn(X) -> is_fn(X).

is_fn(F) when is_function(F) -> true;
is_fn({clj2_fn, _, _}) -> true;
is_fn({fnmeta, _, _}) -> true;
is_fn(_) -> false.

is_symbol(X) -> is_atom(X) andalso X =/= nil andalso X =/= true andalso X =/= false
                    andalso not is_keyword(X).

keyword(nil) -> nil;
keyword(K) when is_atom(K) ->
    case is_keyword(K) of
        true -> K;
        false -> binary_to_atom(<<$:, (atom_to_binary(K))/binary>>)
    end;
keyword(B) when is_binary(B) -> binary_to_atom(<<$:, B/binary>>);
keyword(_) -> nil.                                          % (keyword 5): nil, as on the JVM

keyword(nil, Name) -> keyword(Name);
keyword(Ns, Name) when is_binary(Ns), is_binary(Name) -> binary_to_atom(<<$:, Ns/binary, $/, Name/binary>>);
keyword(Ns, Name) -> cast_string(if is_binary(Ns) -> Name; true -> Ns end).

symbol(nil) ->
    erlang:error(ex_info(<<"no conversion to symbol">>, clj2_coll:hash_map_kv([':type', ':IllegalArgumentException']), nil));
symbol(S) when is_atom(S) -> S;
symbol(B) when is_binary(B) -> binary_to_atom(B);
symbol(_) ->
    erlang:error(ex_info(<<"no conversion to symbol">>, clj2_coll:hash_map_kv([':type', ':IllegalArgumentException']), nil)).

symbol(nil, Name) -> symbol(Name);
symbol(Ns, Name) when is_binary(Ns), is_binary(Name) -> binary_to_atom(<<Ns/binary, $/, Name/binary>>);
symbol(Ns, Name) -> cast_string(if is_binary(Ns) -> Name; true -> Ns end).

cast_string(nil) ->
    erlang:error(ex_info(<<"Cannot invoke a method on nil">>, clj2_coll:hash_map_kv([':type', ':NullPointerException']), nil));
cast_string(X) ->
    erlang:error(ex_info(<<"class ", (atom_to_binary(clj2_class:class_of(X)))/binary,
                           " cannot be cast to class java.lang.String">>,
                         clj2_coll:hash_map_kv([':type', ':ClassCastException']), nil)).

%% @doc name of a symbol or keyword (without namespace), or a string.
name(B) when is_binary(B) -> B;
name(nil) -> cast_string(nil);
name(A) when is_atom(A) ->
    Bin = strip_colon(A),
    case binary:split(Bin, <<"/">>) of
        [_, N] when N =/= <<>> -> N;
        _ -> Bin
    end.

namespace(nil) -> cast_string(nil);
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
%% @doc (apply f a b args): args is realized only as far as choosing the
%% arity needs (one past the largest fixed arity); a variadic fn gets
%% the rest of it lazily, so an infinite tail works as on the JVM
apply(F, Args) ->
    {Init, [Last]} = lists:split(length(Args) - 1, Args),
    case arity_shape(F) of
        {Fixed, Min} ->
            Need = max(lists:max([0 | Fixed]), case Min of nil -> 0; _ -> Min end) + 1 - length(Init),
            {Taken, Tail} = take_seq(Last, max(Need, 0), []),
            All = Init ++ Taken,
            case clj2_coll:seq(Tail) of
                nil -> invoke(F, All);
                More when Min =/= nil ->
                    {Req, Extra} = lists:split(Min, All),
                    erlang:apply(variadic_fun(F), Req ++ [lists:foldr(fun(X, Acc) -> [X | Acc] end, More, Extra)]);
                %% the count, as the JVM's: past 20 it is "> 20"
                More -> erlang:error({clj2_arity, length(All) + bounded_count(More, 21 - length(All)), F})
            end;
        unknown -> invoke(F, Init ++ clj2_coll:to_list(Last))
    end.

%% the fixed arities and the variadic minimum (nil: none) of a fn value
arity_shape(F) when is_function(F) -> {[element(2, erlang:fun_info(F, arity))], nil};
arity_shape({clj2_fn, Fixed, nil}) -> {maps:keys(Fixed), nil};
arity_shape({clj2_fn, Fixed, {Min, _}}) -> {maps:keys(Fixed), Min};
arity_shape(_) -> unknown.

variadic_fun({clj2_fn, _, {_, Fun}}) -> Fun.

bounded_count(_, N) when N =< 0 -> 0;
bounded_count(S, N) ->
    case clj2_coll:seq(S) of
        nil -> 0;
        [_ | T] -> 1 + bounded_count(T, N - 1)
    end.

take_seq(S, 0, Acc) -> {lists:reverse(Acc), S};
take_seq(S, N, Acc) ->
    case clj2_coll:seq(S) of
        nil -> {lists:reverse(Acc), nil};
        [H | T] -> take_seq(T, N - 1, [H | Acc])
    end.

%% @doc `/' on integers stays exact when it divides, else a float
%% (no ratio arithmetic yet: registered divergence).
divide(X, Y) when is_integer(X), is_integer(Y), Y =/= 0, X rem Y =:= 0 -> X div Y;
divide(X, Y) when element(1, X) =:= decimal; element(1, Y) =:= decimal -> num_op('/', X, Y);
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
compare(X, Y) when element(1, X) =:= decimal; element(1, Y) =:= decimal ->
    case num_compare('<', X, Y) of
        true -> -1;
        false -> case num_compare('==', X, Y) of true -> 0; false -> 1 end
    end;
compare(X, Y) when is_binary(X), is_binary(Y) -> lex(X, Y);
%% symbols and keywords: namespace first (none before any), then name
compare(X, Y) when is_atom(X), is_atom(Y), not is_boolean(X), not is_boolean(Y) ->
    case compare(namespace(X), namespace(Y)) of
        0 -> lex(name(X), name(Y));
        C -> C
    end;
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
format(Fmt, Args) when is_binary(Fmt) -> clj2_format:format(Fmt, Args);
format(nil, _) -> cast_string(nil);
format(Fmt, _) -> cast_string(Fmt).

%% ex-info: a record-shaped value, thrown with erlang:error
ex_info(Msg, nil, Cause) -> ex_info(Msg, {map, nil, #{}}, Cause);            % nil data reads back as {}
ex_info(Msg, Data, Cause) ->
    {'clojure.lang.ExceptionInfo', nil, #{':message' => Msg, ':data' => Data, ':cause' => Cause}}.

%% @doc A caught exception as Clojure code sees it under a JVM-class
%% catch: an ex-info stays itself; an Erlang error (or exit, or throw)
%% becomes a host exception of its JVM class (clj2_class:exception_class)
%% with a message, no ex-data, and the original kept under :erlang.
throwable(_, {'clojure.lang.ExceptionInfo', _, _} = E) -> E;
%% a compile error: CompilerException "Syntax error compiling at (L:C).",
%% its cause saying what was wrong
throwable(error, {clj2_compile, Loc, Why} = R) ->
    {Cause, CauseMsg} = compile_cause(Why),
    Inner = {'clojure.lang.ExceptionInfo', nil,
             #{':message' => CauseMsg, ':data' => {map, nil, #{':type' => Cause}},
               ':cause' => nil, ':host' => true, ':erlang' => {error, Why}}},
    Where = case Loc of
                {L, C} when is_integer(L) -> io_lib:format("(~b:~b)", [L, C]);
                {File, {L, C}} -> io_lib:format("(~ts:~b:~b)", [File, L, C]);
                _ -> "(REPL)"
            end,
    {'clojure.lang.ExceptionInfo', nil,
     #{':message' => iolist_to_binary(["Syntax error compiling at ", Where, "."]),
       ':data' => {map, nil, #{':type' => ':CompilerException'}},
       ':cause' => Inner, ':host' => true, ':erlang' => {error, R}}};
throwable(Class, Reason) ->
    C = case Class of
            error -> clj2_class:exception_class(Reason);
            _ -> 'java.lang.RuntimeException'
        end,
    [Simple | _] = lists:reverse(string:split(atom_to_binary(C), ".", all)),
    {'clojure.lang.ExceptionInfo', nil,
     #{':message' => erlang_message(Class, Reason),
       ':data' => {map, nil, #{':type' => binary_to_atom(<<":", Simple/binary>>)}},
       ':cause' => nil, ':host' => true, ':erlang' => {Class, Reason}}}.

%% @doc An Erlang error refined by the call that raised it, which the
%% stacktrace's top frame names with its arguments: the JVM would have
%% thrown NullPointerException for a nil operand, ClassCastException for
%% a non-number one, where BEAM only says badarith (or badarg, or
%% function_clause). Anything else is left as it is.
refine_error(error, R, [{M, F, Args, _} | _]) when is_list(Args),
                                                   (R =:= badarith orelse R =:= badarg orelse
                                                    R =:= function_clause) ->
    %% never let the refinement itself fail: the original error stands
    try refine(R, M, F, Args) catch _:_ -> R end;
refine_error(_, R, _) -> R.

refine(R, M, F, Args) ->
    HasNil = lists:member(nil, Args),
    Bits = M =:= erlang andalso lists:member(F, ['band', 'bor', 'bxor', 'bsl', 'bsr', 'bnot']),
    Arith = M =:= erlang andalso lists:member(F, ['+', '-', '*', '/', 'div', 'rem', '<', '>', '=<', '>=',
                                                  abs, float, trunc, round]),
    NonInteger = [X || X <- Args, not is_integer(X)],
    NonNumber = [X || X <- Args, not is_number(X)],
    %% the host's own string, regex and math functions, and the runtime's:
    %% a call they have no clause for is a value of the wrong class
    Typed = R =/= badarith andalso
        (lists:member(M, [unicode, re, math, string, binary]) orelse
         lists:prefix("clj2_", atom_to_list(M))),
    if
        HasNil -> host_error(':NullPointerException', <<"Cannot invoke a method on nil">>, {error, R});
        Bits, NonInteger =/= [] ->
            host_error(':IllegalArgumentException',
                       iolist_to_binary(["bit operation not supported for: class ",
                                         atom_to_binary(clj2_class:class_of(hd(NonInteger)))]), {error, R});
        Arith, NonNumber =/= [] ->
            host_error(':ClassCastException',
                       iolist_to_binary(["class ", atom_to_binary(clj2_class:class_of(hd(NonNumber))),
                                         " cannot be cast to class java.lang.Number"]), {error, R});
        Typed, Args =/= [] ->
            host_error(':ClassCastException',
                       iolist_to_binary(["class ", atom_to_binary(clj2_class:class_of(hd(Args))),
                                         " cannot be cast to the class ", atom_to_binary(M), ":",
                                         atom_to_binary(F), " requires"]), {error, R});
        true -> R
    end.

host_error(Type, Msg, Orig) ->
    {'clojure.lang.ExceptionInfo', nil,
     #{':message' => Msg, ':data' => {map, nil, #{':type' => Type}},
       ':cause' => nil, ':host' => true, ':erlang' => Orig}}.

compile_cause({_, {not_public, Msg}}) -> {':IllegalStateException', Msg};
compile_cause({resolve, {unresolved_symbol, S}}) ->
    {':RuntimeException', iolist_to_binary(["Unable to resolve symbol: ", atom_to_binary(S), " in this context"])};
compile_cause({resolve, {no_such_var, Ns, Name}}) ->
    {':RuntimeException', iolist_to_binary(["No such var: ", atom_to_binary(Ns), "/", atom_to_binary(Name)])};
compile_cause(Why) -> {':RuntimeException', iolist_to_binary(io_lib:format("~tp", [Why]))}.

erlang_message(error, badarith) -> <<"Divide by zero">>;
erlang_message(error, {clj2_index_out_of_bounds, I}) when is_integer(I) ->
    <<"Index ", (integer_to_binary(I))/binary, " out of bounds">>;
erlang_message(error, {clj2_index_out_of_bounds, _}) -> nil;
erlang_message(error, {clj2_not_ifn, X}) ->
    iolist_to_binary(["class ", atom_to_binary(clj2_class:class_of(X)), " cannot be cast to class clojure.lang.IFn"]);
erlang_message(error, {clj2_arity, N, _}) when is_integer(N), N > 20 ->
    <<"Wrong number of args (> 20) passed to: fn">>;
erlang_message(error, {clj2_arity, N, _}) when is_integer(N) ->
    iolist_to_binary(["Wrong number of args (", integer_to_binary(N), ") passed to: fn"]);
erlang_message(error, {clj2_unbound_var, M, Name}) ->
    iolist_to_binary(["Attempting to call unbound fn: #'", atom_to_binary(M), "/", atom_to_binary(Name)]);
erlang_message(Class, Reason) ->
    iolist_to_binary(io_lib:format("~tp", [{Class, Reason}])).

%% @doc A case with no matching clause and no default
no_matching_clause(V) ->
    erlang:error(ex_info(<<"No matching clause: ", (str1(V))/binary>>,
                         clj2_coll:hash_map_kv([':type', ':IllegalArgumentException']), nil)).
is_ex_info({'clojure.lang.ExceptionInfo', _, _}) -> true;
is_ex_info(_) -> false.
ex_message({'clojure.lang.ExceptionInfo', _, #{':message' := M}}) -> M;
ex_message(_) -> nil.
ex_data({'clojure.lang.ExceptionInfo', _, #{':host' := true}}) -> nil;     % a host exception
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

%% @doc (ratio? x), (numerator r), (denominator r): ratios read as
%% {ratio, N, D} (known divergence :number/no-ratio-arithmetic)
is_ratio({ratio, _, _}) -> true;
is_ratio(_) -> false.
numerator({ratio, N, _}) -> N.
denominator({ratio, _, D}) -> D.

%% @doc (find-keyword ns name): the keyword when its atom exists already
existing_keyword(nil, Name) -> binary_to_existing_atom(<<":", Name/binary>>);
existing_keyword(Ns, Name) -> binary_to_existing_atom(<<":", Ns/binary, "/", Name/binary>>).

%% @doc Tagged literals and reader conditionals as data: their fields
%% read as keys (:tag :form, :form :splicing?), = is by value, and they
%% are not maps.
tagged_literal(Tag, Form) -> {tagged_literal, nil, #{':tag' => Tag, ':form' => Form}}.
is_tagged_literal({tagged_literal, _, _}) -> true;
is_tagged_literal(_) -> false.
reader_conditional(Form, Splicing) ->
    {reader_conditional, nil, #{':form' => Form, ':splicing?' => Splicing =:= true}}.
is_reader_conditional({reader_conditional, _, _}) -> true;
is_reader_conditional(_) -> false.

%% @doc A value used where a number is required: nil is a
%% NullPointerException, anything else a ClassCastException (as on the JVM)
not_number(nil) ->
    erlang:error(ex_info(<<"Cannot use nil as a number">>,
                         clj2_coll:hash_map_kv([':type', ':NullPointerException']), nil));
not_number(X) ->
    erlang:error(ex_info(<<"class ", (atom_to_binary(clj2_class:class_of(X)))/binary,
                           " cannot be cast to class java.lang.Number">>,
                         clj2_coll:hash_map_kv([':type', ':ClassCastException']), nil)).

%% @doc A numeric comparison off the fast path (both Erlang numbers): a
%% ratio compares by value (exactly, or as a float against a float);
%% anything else that is not a number raises as on the JVM.
num_compare(Op, X, Y) ->
    C = case {rational(X), rational(Y)} of
            {A, B} when is_float(A); is_float(B) -> sign(to_float(A) - to_float(B));
            {{N1, D1}, {N2, D2}} -> sign(N1 * D2 - N2 * D1)
        end,
    case Op of
        '<' -> C < 0;
        '>' -> C > 0;
        '=<' -> C =< 0;
        '>=' -> C >= 0;
        '==' -> C =:= 0
    end.

rational(I) when is_integer(I) -> {I, 1};
rational({decimal, _, _} = D) -> clj2_decimal:to_rational(D);
rational(F) when is_float(F) -> F;
rational({ratio, N, D}) -> {N, D};
rational(X) -> not_number(X).

to_float({N, D}) -> N / D;
to_float(F) -> F.

%% @doc Arithmetic off the fast path (both Erlang numbers), with the JVM's
%% contagion: a double makes the result a double; otherwise a BigDecimal
%% makes it a BigDecimal (rounded by *math-context*); a ratio has no
%% arithmetic here (:number/no-ratio-arithmetic); a non-number raises.
num_op(Op, X, Y) ->
    case {num_kind(X), num_kind(Y)} of
        {A, B} when A =:= float; B =:= float ->
            FX = to_double(X), FY = to_double(Y),
            case Op of
                '+' -> FX + FY;
                '-' -> FX - FY;
                '*' -> FX * FY;
                '/' -> FX / FY
            end;
        _ ->
            DX = clj2_decimal:from(X), DY = clj2_decimal:from(Y),
            MC = math_context(),
            case Op of
                '+' -> clj2_decimal:add(DX, DY, MC);
                '-' -> clj2_decimal:sub(DX, DY, MC);
                '*' -> clj2_decimal:mul(DX, DY, MC);
                '/' -> clj2_decimal:divide(DX, DY, MC)
            end
    end.

%% @doc quot/rem off the integer path: doubles (truncated quotient, fmod),
%% BigDecimals (divideToIntegralValue, remainder)
num_quot(N, D) ->
    case {num_kind(N), num_kind(D)} of
        {A, B} when A =:= float; B =:= float -> float(trunc(divide(to_double(N), to_double(D))));
        _ -> clj2_decimal:quot(clj2_decimal:from(N), clj2_decimal:from(D))
    end.

num_rem(N, D) ->
    case {num_kind(N), num_kind(D)} of
        {A, B} when A =:= float; B =:= float ->
            FD = to_double(D),
            FD == 0 andalso erlang:error(badarith),
            math:fmod(to_double(N), FD);
        _ -> clj2_decimal:remainder(clj2_decimal:from(N), clj2_decimal:from(D))
    end.

num_kind(I) when is_integer(I) -> integer;
num_kind(F) when is_float(F) -> float;
num_kind({decimal, _, _}) -> decimal;
num_kind(X) -> not_number(X).

to_double({decimal, _, _} = D) -> clj2_decimal:to_float(D);
to_double(N) -> float(N).

%% the bound *math-context* (nil: exact)
math_context() ->
    try clj2_var:deref('clojure.core', '*math-context*') catch error:_ -> nil end.

%% @doc number? beyond Erlang's numbers: ratios and BigDecimals
is_boxed_number({ratio, N, D}) -> is_integer(N) andalso is_integer(D);
is_boxed_number({decimal, U, S}) -> is_integer(U) andalso is_integer(S);
is_boxed_number(_) -> false.

%% @doc Transients: {transient, nil, PersistentValue} (clojure.core/transient)
%% only vectors, hash maps and hash sets are editable (as on the JVM:
%% a sorted collection, a seq or a record is a ClassCastException)
transient({vector, _, T} = C) when is_tuple(T) -> {transient, nil, C};
transient({map, _, M} = C) when is_map(M) -> {transient, nil, C};
transient({set, _, M} = C) when is_map(M) -> {transient, nil, C};
transient(nil) ->
    erlang:error(ex_info(<<"transient: nil">>, clj2_coll:hash_map_kv([':type', ':NullPointerException']), nil));
transient(X) ->
    erlang:error(ex_info(<<"class ", (atom_to_binary(clj2_class:class_of(X)))/binary,
                           " cannot be cast to class clojure.lang.IEditableCollection">>,
                         clj2_coll:hash_map_kv([':type', ':ClassCastException']), nil)).
is_transient({transient, _, _}) -> true;
is_transient(_) -> false.
persistent({transient, _, C}) -> C;
persistent(X) ->
    erlang:error(ex_info(<<"class ", (atom_to_binary(clj2_class:class_of(X)))/binary,
                           " cannot be cast to class clojure.lang.ITransientCollection">>,
                         clj2_coll:hash_map_kv([':type', ':ClassCastException', ':value', X]), nil)).

%%====================================================================
%% Metadata (clojerl2-021 follow-up)
%%
%% Collections, lazy seqs and records carry it in their Meta slot; a fn
%% with metadata is {fnmeta, Meta, Fn} (invoked like Fn); a list given
%% metadata becomes a lazy seq that holds it. Symbols carry none (known
%% divergence :symbol/no-metadata). = and hash ignore metadata.
%%====================================================================

meta({Tag, M, _}) when Tag =:= vector; Tag =:= map; Tag =:= set; Tag =:= lazy_seq;
                       Tag =:= fnmeta; Tag =:= sorted_map; Tag =:= sorted_set -> M;
meta({Tag, M, D}) when is_atom(Tag), is_map(D) -> M;          % records
meta({var, _, {Ns, Name}}) -> var_meta(Ns, Name);
meta({Tag, _, _} = R) when Tag =:= atom; Tag =:= agent -> clj2_ref:ref_meta(R);
meta(_) -> nil.

%% a lazy seq is realized (seq) when it is given metadata, as on the JVM
with_meta({lazy_seq, _, _} = L, M) -> _ = clj2_lazy:seq(L), {lazy_seq, M, element(3, L)};
with_meta({Tag, _, D}, M) when Tag =:= vector; Tag =:= map; Tag =:= set;
                               Tag =:= sorted_map; Tag =:= sorted_set ->
    {Tag, M, D};
with_meta({fnmeta, _, F}, M) -> {fnmeta, M, F};
with_meta({Tag, _, D}, M) when is_atom(Tag), is_map(D), Tag =/= var -> {Tag, M, D};
with_meta(F, M) when is_function(F) -> {fnmeta, M, F};
with_meta({clj2_fn, _, _} = F, M) -> {fnmeta, M, F};
with_meta(L, M) when is_list(L) ->
    {lazy_seq, _, Cell} = clj2_lazy:lazy_seq(fun() -> L end),
    {lazy_seq, M, Cell};
with_meta(X, _) ->
    erlang:error(ex_info(iolist_to_binary(["with-meta: ", clj2_print:pr_str(X), " cannot carry metadata"]),
                         clj2_coll:hash_map_kv([':type', ':ClassCastException']), nil)).

%% a var's metadata, from the namespace registry
var_meta(Ns, Name) ->
    case clj2_ns:info(Ns) of
        {ok, #{vars := #{Name := I}}} ->
            Base = [':ns', Ns, ':name', Name],
            Opt = lists:append([[K, V] || {K, Key} <- [{':doc', doc}, {':macro', macro},
                                                     {':dynamic', dynamic}, {':private', private}],
                                          V <- [maps:get(Key, I, nil)], V =/= nil, V =/= false]),
            Arglists = case I of
                           #{arities := As} -> [':arglists', [clj2_coll:vector(lists:duplicate(N, '_')) || N <- As]];
                           _ -> []
                       end,
            Extra = maps:get(meta, I, #{}),
            M0 = clj2_coll:hash_map_kv(Base ++ Opt ++ Arglists),
            {map, nil, jvm_doc(Ns, Name, maps:merge(element(3, M0), Extra))};
        _ -> nil
    end.

%% A var of a namespace JVM Clojure has too (clojure.core, clojure.string
%% ...) without a docstring or real arglists of its own takes the JVM's
%% (priv/clj2/jvm-docs.eterm, tools/gen-jvm-docs.clj)
jvm_doc(Ns, Name, M) ->
    case maps:get({Ns, Name}, jvm_docs(), none) of
        none -> M;
        {Doc, Arglists} ->
            M1 = case M of
                     #{':doc' := _} -> M;
                     _ when Doc =/= nil -> M#{':doc' => Doc};
                     _ -> M
                 end,
            Placeholder = case M1 of
                              #{':arglists' := As} ->
                                  lists:all(fun(V) -> lists:all(fun(P) -> P =:= '_' end, clj2_coll:to_list(V)) end,
                                            clj2_coll:to_list(As));
                              _ -> true
                          end,
            case Placeholder andalso Arglists =/= nil of
                true ->
                    {ok, F, _, _} = clj2_reader:read(Arglists),
                    M1#{':arglists' => clj2_form:to_data(F)};
                false -> M1
            end
    end.

jvm_docs() ->
    case persistent_term:get({?MODULE, jvm_docs}, undefined) of
        undefined ->
            File = filename:join([filename:dirname(code:which(?MODULE)), "..", "priv", "clj2", "jvm-docs.eterm"]),
            T = case file:consult(File) of
                    {ok, Terms} -> maps:from_list([{{Ns, binary_to_atom(N)}, {D, A}} || {Ns, N, D, A} <- Terms]);
                    _ -> #{}
                end,
            persistent_term:put({?MODULE, jvm_docs}, T),
            T;
        T -> T
    end.

%% @doc defn's metadata map: {:doc doc} then the attr-map, then
%% :arglists (quoted) unless the attr-map has one (Clojure's order)
defn_meta(Doc, Attr, Sigs) ->
    M0 = case Doc of nil -> #{}; _ -> #{':doc' => Doc} end,
    M1 = case Attr of {map, _, A} -> maps:merge(M0, A); _ -> M0 end,
    M2 = case M1 of
             #{':arglists' := _} -> M1;
             _ -> M1#{':arglists' => [quote, [elide_env(S) || S <- clj2_coll:to_list(Sigs)]]}
         end,
    {map, nil, M2}.

%% a leading &form &env (a fn written as a macro's) is not in :arglists
elide_env({vector, _, _} = V) ->
    case clj2_coll:vec_to_list(V) of
        ['&form', '&env' | Ps] -> clj2_coll:vector(Ps);
        _ -> V
    end;
elide_env(S) -> S.

%% @doc Merge evaluated metadata into a var's (def with expression values)
merge_var_meta({var, _, {Ns, Name}} = V, {map, _, M}) ->
    case clj2_ns:info(Ns) of
        {ok, #{vars := #{Name := I}}} ->
            clj2_ns:set_var_meta(V, {map, nil, maps:merge(maps:get(meta, I, #{}), M)});
        %% a compile-time segment's var is not registered (the namespace's
        %% own module registers it, with its metadata, when it loads)
        _ -> ok
    end,
    V.

is_var({var, _, {_, _}}) -> true;
is_var(_) -> false.

%% @doc What `##NaN', `##Inf' and `##-Inf' evaluate to: an
%% ArithmeticException, since BEAM floats have no NaN or infinity (known
%% divergence :number/beam-semantics).
unsupported_float(Kw) ->
    Name = list_to_binary(tl(atom_to_list(Kw))),
    erlang:error(ex_info(<<"##", Name/binary, ": BEAM floats have no NaN or infinity (known divergence :number/beam-semantics)">>,
                         clj2_coll:hash_map_kv([':type', ':ArithmeticException']), nil)).

%% @doc What a BigDecimal literal (1.5M) evaluates to while there is no
%% @doc What a tagged literal with no reader function (#inst ...)
%% evaluates to: the JVM reader's error, at evaluation time.
unsupported_tag(Tag) ->
    erlang:error(ex_info(<<"No reader function for tag ", (atom_to_binary(Tag))/binary>>,
                         clj2_coll:hash_map_kv([':type', ':RuntimeException']), nil)).

%% @doc What a def inside an expression does when it runs: the var gets
%% the value as its root (set_var_root/2), and is the result.
def_root(V, Val) ->
    _ = set_var_root(V, Val),
    V.

%% @doc Give a var a new root value (alter-var-root, with-redefs, a def
%% inside an expression): the var's validator runs first, its watches
%% after. A var whose value lives in the var table is set there; a fn or
%% constant var, linked directly, moves its value there first
%% (clj2_rt_eval:redirect/3, once). → the value
set_var_root({var, _, {Ns, Name}}, Val) ->
    case clj2_ns:info(Ns) of
        {ok, #{module := NsMod, vars := #{Name := I}}} ->
            Watches = maps:get(watches, I, #{}),
            validate_var(I, Val),
            Old = case map_size(Watches) of
                      0 -> nil;
                      _ -> raw_root(maps:get(module, I, NsMod), Name, I)
                  end,
            M = case I of
                    #{kind := K} when K =:= fn; K =:= const -> to_table(Ns, Name, I);
                    _ -> maps:get(module, I, NsMod)
                end,
            clj2_var:set_root(M, Name, clj2_rt_eval:root_value(M, Name, Val)),
            notify_var(Watches, {var, nil, {Ns, Name}}, Old, Val),
            Val;
        %% a fn var defined earlier in a file that is still compiling (a
        %% compile-time segment, not registered yet): its calls are linked
        %% to that segment's functions, so it cannot be redefined from here
        _ ->
            erlang:error(ex_info(iolist_to_binary(["Can't redefine ", atom_to_binary(Ns), "/", atom_to_binary(Name),
                                                   " from inside an expression: the var is not registered yet"]),
                                 clj2_coll:hash_map_kv([':type', ':IllegalStateException']), nil))
    end.

%% @doc A def inside an expression of a var whose value is in the var
%% table already (clj2_p_resolve: the module is known when it compiles,
%% and the var may not be registered yet -- a compile-time segment).
assign_root(V = {var, _, {Ns, Name}}, M, Val) ->
    case clj2_ns:info(Ns) of
        {ok, #{vars := #{Name := #{kind := K} = I}}} when K =/= fn, K =/= const,
                                                          (is_map_key(watches, I) orelse
                                                           is_map_key(validator, I)) ->
            _ = set_var_root(V, Val);
        _ -> clj2_var:set_root(M, Name, Val)
    end,
    V.

%% a fn or constant var's value moves into the var table (once)
to_table(Ns, Name, I) ->
    Ns =:= 'clojure.core' andalso core_direct_linked(Name),
    clj2_rt_eval:redirect(Ns, Name, I).

%% @doc (alter-var-root v f & args): the root becomes (apply f root args).
%% The value moves into the var table first, so the old value f gets is
%% the fn itself, not a call through the var (which it may wrap).
alter_var_root({local_var, _, {_, Cell}} = L, F, Args) ->
    Old = case clj2_ref:deref(Cell) of '$clj2_unbound' -> nil; R -> R end,
    New = invoke(F, [Old | clj2_coll:to_list(Args)]),
    clj2_ref:reset(Cell, New),
    _ = L,
    New;
alter_var_root(V, F, Args) ->
    set_var_root(V, invoke(F, [table_root(V) | clj2_coll:to_list(Args)])).

%% @doc A var's root value, whatever binding this process has of it
%% (what with-redefs saves and restores), once the value is in the var
%% table (as table_root/1)
table_root(V = {var, _, {Ns, Name}}) ->
    case clj2_ns:info(Ns) of
        {ok, #{vars := #{Name := #{kind := K} = I}}} when K =:= fn; K =:= const ->
            _ = to_table(Ns, Name, I);
        _ -> ok
    end,
    var_root(V).

%% @doc A var's root value, whatever binding this process has of it
var_root({var, _, {Ns, Name}}) ->
    {ok, #{module := NsMod, vars := #{Name := I}}} = clj2_ns:info(Ns),
    raw_root(maps:get(module, I, NsMod), Name, I).

raw_root(M, Name, #{kind := indirect}) -> clj2_var:root(M, Name);
raw_root(M, Name, I) -> var_value(M, Name, I).

validate_var(#{validator := F}, Val) when F =/= nil ->
    case invoke(F, [Val]) of
        R when R =:= false; R =:= nil ->
            erlang:error(ex_info(<<"Invalid reference state">>,
                                 clj2_coll:hash_map_kv([':type', ':IllegalStateException']), nil));
        _ -> ok
    end;
validate_var(_, _) -> ok.

notify_var(Watches, V, Old, New) ->
    [invoke(F, [K, V, Old, New]) || {K, F} <- lists:sort(maps:to_list(Watches))],
    ok.

%% @doc (set-validator! #'v f): checks the current root, as on the JVM
set_var_validator(V = {var, _, {Ns, Name}}, F) ->
    {ok, #{vars := #{Name := I}}} = clj2_ns:info(Ns),
    F =:= nil orelse validate_var(#{validator => F}, var_root(V)),
    clj2_ns:put_var(Ns, Name, I#{validator => F}),
    nil.

var_validator({var, _, {Ns, Name}}) ->
    {ok, #{vars := #{Name := I}}} = clj2_ns:info(Ns),
    maps:get(validator, I, nil).

%% @doc add-watch / remove-watch on a var (Fun updates its watch map)
update_var_watches(V = {var, _, {Ns, Name}}, Fun) ->
    {ok, #{vars := #{Name := I}}} = clj2_ns:info(Ns),
    clj2_ns:put_var(Ns, Name, I#{watches => Fun(maps:get(watches, I, #{}))}),
    V.

%% clojure.core is linked directly into everything compiled against it
%% (itself included), so its fn and constant vars keep their values
core_direct_linked(Name) ->
    erlang:error(ex_info(iolist_to_binary(["Can't change the root of clojure.core/", atom_to_binary(Name),
                                           ": clojure.core is direct-linked (clojerl2 :vars/core-direct-linked)"]),
                         clj2_coll:hash_map_kv([':type', ':IllegalStateException']), nil)).

%% @private A fn var whose value moved into the var table
%% (clj2_rt_eval:redirect/3) calls it through here.
invoke_root(M, Name, Req, Rest) ->
    invoke(clj2_var:root(M, Name), clj2_coll:to_list(Req) ++ clj2_coll:to_list(Rest)).
