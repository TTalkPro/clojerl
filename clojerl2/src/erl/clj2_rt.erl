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
-export([invoke/2, var_fn/3, var/2, is_ratio/1, numerator/1, denominator/1, existing_keyword/2]).

%% layer-0 primitives for clojure.core (00-kernel)
-export([str/1, keyword/1, keyword/2, symbol/1, symbol/2, name/1, namespace/1,
         gensym/1, apply/2, is_keyword/1, is_symbol/1, is_fn/1, is_ifn/1, identical/2, divide/2]).

%% layer-0 primitives for 01-core (clojerl2-021)
-export([str_contains/2]).
-export([reduced/1, is_reduced/1, unreduced/1, compare/2, sort/2, format/2,
         ex_info/3, throwable/2, no_matching_clause/1, is_ex_info/1, ex_message/1, ex_data/1, ex_cause/1, subs/3]).

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
str1({'java.lang.StringBuilder', _, _} = B) -> clj2_jvm:builder_text(B);
str1(X) -> clj2_print:pr_str(X).                         % collections, records, ...

is_keyword(X) -> is_atom(X) andalso X =/= nil andalso X =/= true andalso X =/= false
                     andalso X =/= ':' andalso hd(atom_to_list(X)) =:= $:.

identical(X, Y) -> X =:= Y.

%% @doc ifn?: what invoke takes (fns, keywords, symbols, maps, sets,
%% vectors, vars, multimethods, transients of those)
is_ifn(X) when is_atom(X) -> X =/= nil andalso X =/= true andalso X =/= false;
is_ifn({Tag, _, _}) when Tag =:= map; Tag =:= set; Tag =:= vector; Tag =:= var; Tag =:= multifn;
                         Tag =:= sorted_map; Tag =:= sorted_set; Tag =:= transient -> true;
is_ifn(X) -> is_fn(X).

is_fn(F) when is_function(F) -> true;
is_fn({clj2_fn, _, _}) -> true;
is_fn({fnmeta, _, _}) -> true;
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
format(Fmt, Args) when is_binary(Fmt) -> clj2_format:format(Fmt, Args).

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

%% @doc Transients: {transient, nil, PersistentValue} (clojure.core/transient)
transient(C) -> {transient, nil, C}.
is_transient({transient, _, _}) -> true;
is_transient(_) -> false.
persistent({transient, _, C}) -> C;
persistent(X) -> erlang:error(ex_info(<<"not a transient">>, clj2_coll:hash_map_kv([':value', X]), nil)).

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
meta(_) -> nil.

with_meta({Tag, _, D}, M) when Tag =:= vector; Tag =:= map; Tag =:= set; Tag =:= lazy_seq;
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
            {map, nil, maps:merge(element(3, M0), Extra)};
        _ -> nil
    end.

%% @doc defn's metadata map: {:doc doc} then the attr-map, then
%% :arglists (quoted) unless the attr-map has one (Clojure's order)
defn_meta(Doc, Attr, Sigs) ->
    M0 = case Doc of nil -> #{}; _ -> #{':doc' => Doc} end,
    M1 = case Attr of {map, _, A} -> maps:merge(M0, A); _ -> M0 end,
    M2 = case M1 of
             #{':arglists' := _} -> M1;
             _ -> M1#{':arglists' => [quote, clj2_coll:to_list(Sigs)]}
         end,
    {map, nil, M2}.

%% @doc Merge evaluated metadata into a var's (def with expression values)
merge_var_meta({var, _, {Ns, Name}} = V, {map, _, M}) ->
    {ok, #{vars := #{Name := I}}} = clj2_ns:info(Ns),
    clj2_ns:set_var_meta(V, {map, nil, maps:merge(maps:get(meta, I, #{}), M)}),
    V.

is_var({var, _, {_, _}}) -> true;
is_var(_) -> false.
