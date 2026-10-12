%%%-------------------------------------------------------------------
%%% @doc clj2_hash — clojure.core/hash as on the JVM: Clojure's hasheq
%%% (clojure.lang.Murmur3, Util.hasheq/hashCombine, Numbers.hasheq,
%%% Keyword/Symbol.hasheq, APersistentMap/Set/Vector hasheq, defrecord's
%%% hasheq), so (hash :a) is -2123407586 here too.
%%%
%%% Ported from jolt's host/chez/hasheq.ss (EPL-2.0), itself a port of
%%% the Java sources. All arithmetic is Java's 32-bit int: values are
%%% kept unsigned (band 16#FFFFFFFF) inside and made signed at the end.
%%%
%%% Strings are hashed over their UTF-16 code units (a code point beyond
%%% the BMP is two), as String.hashCode and Murmur3.hashUnencodedChars
%%% see them. Values with no JVM counterpart (pids, refs, fns) hash by
%%% erlang:phash2.
%%%-------------------------------------------------------------------
-module(clj2_hash).

-export([hasheq/1, java_hash_code/1, hash_ordered/1, hash_unordered/1, mix_coll_hash/2,
         hash_combine/2, string_hash_code/1, hash_int/1, hash_long/1,
         big_integer_hash_code/1, signed/1]).

-define(M32, 16#FFFFFFFF).
-define(C1, 16#cc9e2d51).
-define(C2, 16#1b873593).
-define(GOLDEN, 16#9e3779b9).

%%====================================================================
%% hasheq
%%====================================================================

hasheq(nil) -> 0;
hasheq(true) -> 1231;                                   % Boolean.hashCode
hasheq(false) -> 1237;
hasheq(I) when is_integer(I), I >= -16#8000000000000000, I =< 16#7FFFFFFFFFFFFFFF -> hash_long(I);
hasheq(I) when is_integer(I) -> big_integer_hash_code(I);
hasheq(F) when is_float(F) -> double_hash(F);
hasheq(B) when is_binary(B) -> hash_int(string_hash_code(B));
hasheq(A) when is_atom(A) ->
    case clj2_rt:is_keyword(A) of
        true -> signed(symbol_hash(tl(atom_to_list(A))) + ?GOLDEN);
        false -> symbol_hash(atom_to_list(A))
    end;
hasheq({decimal, _, _} = D) -> clj2_decimal:hash(D);
hasheq({ratio, N, D}) -> signed(big_integer_hash_code(N) bxor big_integer_hash_code(D));
hasheq({vector, _, T}) when is_tuple(T) -> hash_ordered(tuple_to_list(T));
hasheq({map, _, M}) when is_map(M) -> map_hash(maps:to_list(M));
hasheq({set, _, M}) when is_map(M) -> hash_unordered(maps:keys(M));
hasheq({sorted_map, _, {_, _, _}} = S) ->
    map_hash([{K, V} || {vector, _, {K, V}} <- clj2_sorted:to_list(S)]);
hasheq({sorted_set, _, {_, _, _}} = S) -> hash_unordered(clj2_sorted:to_list(S));
hasheq(L) when is_list(L) -> hash_ordered(clj2_coll:to_list(L));
hasheq({lazy_seq, _, _} = L) -> hash_ordered(clj2_coll:to_list(L));
%% a defrecord: (bit-xor (hash 'ns.R) map-hasheq), as its generated hasheq
hasheq({Tag, _, M}) when is_atom(Tag), is_map(M), Tag =/= set, Tag =/= map ->
    signed(u(symbol_hash(atom_to_list(Tag))) bxor u(map_hash(maps:to_list(M))));
hasheq({transient, _, _} = T) -> erlang:phash2(T);
hasheq(X) -> erlang:phash2(X).

%% @doc Object.hashCode as the JVM's classes define it (.hashCode, %h,
%% hash-combine's second argument): not hasheq
java_hash_code(nil) -> 0;
java_hash_code(true) -> 1231;
java_hash_code(false) -> 1237;
java_hash_code(I) when is_integer(I), I >= -16#8000000000000000, I =< 16#7FFFFFFFFFFFFFFF ->
    U = I band 16#FFFFFFFFFFFFFFFF,
    signed(U bxor (U bsr 32));
java_hash_code(I) when is_integer(I) -> big_integer_hash_code(I);
java_hash_code(F) when is_float(F) ->
    <<Bits:64/unsigned>> = <<F:64/float>>,
    signed((Bits bxor (Bits bsr 32)) band ?M32);
java_hash_code(B) when is_binary(B) -> string_hash_code(B);
java_hash_code(A) when is_atom(A) ->
    case clj2_rt:is_keyword(A) of
        true -> signed(symbol_hash_code(tl(atom_to_list(A))) + ?GOLDEN);
        false -> symbol_hash_code(atom_to_list(A))
    end;
java_hash_code({decimal, _, _} = D) -> clj2_decimal:hash(D);
java_hash_code({ratio, N, D}) -> signed(big_integer_hash_code(N) bxor big_integer_hash_code(D));
java_hash_code({vector, _, T}) when is_tuple(T) -> list_hash_code(tuple_to_list(T));
java_hash_code({map, _, M}) when is_map(M) ->
    signed(lists:foldl(fun({K, V}, Acc) -> (Acc + u(u(java_hash_code(K)) bxor u(java_hash_code(V)))) band ?M32 end,
                       0, maps:to_list(M)));
java_hash_code({set, _, M}) when is_map(M) ->
    signed(lists:foldl(fun(K, Acc) -> (Acc + java_hash_code(K)) band ?M32 end, 0, maps:keys(M)));
java_hash_code(L) when is_list(L) -> list_hash_code(clj2_coll:to_list(L));
java_hash_code({lazy_seq, _, _} = L) -> list_hash_code(clj2_coll:to_list(L));
java_hash_code(X) -> hasheq(X).

list_hash_code(Xs) ->
    signed(lists:foldl(fun(X, H) -> (31 * H + java_hash_code(X)) band ?M32 end, 1, Xs)).

%% Symbol.hashCode: hashCombine(name.hashCode(), ns.hashCode())
symbol_hash_code(Str) ->
    {Ns, Name} = split_symbol(Str),
    NsHash = case Ns of
                 nil -> 0;
                 _ -> string_hash_code(unicode:characters_to_binary(Ns))
             end,
    hash_combine(string_hash_code(unicode:characters_to_binary(Name)), NsHash).

split_symbol(Str) ->
    case string:split(Str, "/") of
        [N, Nm] when N =/= "", Nm =/= "" -> {N, Nm};
        _ -> {nil, Str}
    end.

%% Symbol.hasheq: hashCombine(hashUnencodedChars(name), ns.hashCode())
symbol_hash(Str) ->
    {Ns, Name} = split_symbol(Str),
    NsHash = case Ns of
                 nil -> 0;
                 _ -> string_hash_code(unicode:characters_to_binary(Ns))
             end,
    hash_combine(hash_unencoded_chars(utf16(unicode:characters_to_binary(Name))), NsHash).

map_hash(Pairs) ->
    {H, N} = lists:foldl(fun({K, V}, {Acc, C}) -> {(Acc + entry_hash(K, V)) band ?M32, C + 1} end,
                         {0, 0}, Pairs),
    mix_coll_hash(H, N).

%% a map entry hashes as the vector [k v]
entry_hash(K, V) ->
    H1 = (31 + hasheq(K)) band ?M32,
    H2 = (31 * H1 + hasheq(V)) band ?M32,
    u(mix_coll_hash(H2, 2)).

%% @doc Murmur3.hashOrdered over the elements
hash_ordered(Xs) ->
    {H, N} = lists:foldl(fun(X, {Acc, C}) -> {(31 * Acc + hasheq(X)) band ?M32, C + 1} end, {1, 0}, Xs),
    mix_coll_hash(H, N).

%% @doc Murmur3.hashUnordered over the elements
hash_unordered(Xs) ->
    {H, N} = lists:foldl(fun(X, {Acc, C}) -> {(Acc + hasheq(X)) band ?M32, C + 1} end, {0, 0}, Xs),
    mix_coll_hash(H, N).

%% @doc Murmur3.mixCollHash
mix_coll_hash(Hash, Count) ->
    signed(fmix(mix_h1(0, mix_k1(u(Hash))), Count)).

%% @doc Util.hashCombine: seed ^= hash + 0x9e3779b9 + (seed << 6) + (seed >> 2)
hash_combine(Seed0, Hash) ->
    Seed = signed(Seed0),
    signed(u(Seed) bxor u(u(Hash) + ?GOLDEN + u(Seed bsl 6) + u(Seed bsr 2))).

%%====================================================================
%% Murmur3
%%====================================================================

hash_int(0) -> 0;
hash_int(I) -> signed(fmix(mix_h1(0, mix_k1(u(I))), 4)).

hash_long(0) -> 0;
hash_long(L) ->
    U = L band 16#FFFFFFFFFFFFFFFF,
    H1 = mix_h1(0, mix_k1(U band ?M32)),
    H2 = mix_h1(H1, mix_k1(U bsr 32)),
    signed(fmix(H2, 8)).

hash_unencoded_chars(Units) -> signed(chars(Units, 0, length(Units))).

chars([A, B | Rest], H1, Len) -> chars(Rest, mix_h1(H1, mix_k1(A bor (B bsl 16))), Len);
chars([A], H1, Len) -> fmix(H1 bxor mix_k1(A), 2 * Len);
chars([], H1, Len) -> fmix(H1, 2 * Len).

mix_k1(K) ->
    K1 = mul(K, ?C1),
    K2 = rotl(K1, 15),
    mul(K2, ?C2).

mix_h1(H, K) ->
    H1 = H bxor K,
    H2 = rotl(H1, 13),
    (mul(H2, 5) + 16#e6546b64) band ?M32.

fmix(H0, Len) ->
    H1 = H0 bxor u(Len),
    H2 = H1 bxor (H1 bsr 16),
    H3 = mul(H2, 16#85ebca6b),
    H4 = H3 bxor (H3 bsr 13),
    H5 = mul(H4, 16#c2b2ae35),
    H5 bxor (H5 bsr 16).

mul(A, B) -> (A * B) band ?M32.
rotl(X, N) -> ((X bsl N) bor (X bsr (32 - N))) band ?M32.

%%====================================================================
%% Java hashCodes
%%====================================================================

%% @doc String.hashCode: s[0]*31^(n-1) + ... over the UTF-16 code units
string_hash_code(B) ->
    signed(lists:foldl(fun(C, H) -> (31 * H + C) band ?M32 end, 0, utf16(B))).

utf16(B) ->
    lists:append([case C of
                      _ when C >= 16#10000 ->
                          V = C - 16#10000,
                          [16#D800 + (V bsr 10), 16#DC00 + (V band 16#3FF)];
                      _ -> [C]
                  end || C <- unicode:characters_to_list(B)]).

%% Double.hashCode: (int)(bits ^ (bits >>> 32)); -0.0 hashes as 0.0
double_hash(F) when F == 0 -> 0;
double_hash(F) ->
    <<Bits:64/unsigned>> = <<F:64/float>>,
    signed((Bits bxor (Bits bsr 32)) band ?M32).

%% BigInteger.hashCode: over the 32-bit magnitude words, high first
big_integer_hash_code(0) -> 0;
big_integer_hash_code(I) ->
    Sign = case I < 0 of true -> -1; false -> 1 end,
    Mag = abs(I),
    Words = words(Mag, []),
    H = lists:foldl(fun(W, Acc) -> (31 * Acc + W) band ?M32 end, 0, Words),
    signed(Sign * signed(H)).

words(0, Acc) -> Acc;
words(M, Acc) -> words(M bsr 32, [M band ?M32 | Acc]).

u(X) -> X band ?M32.

signed(X) ->
    U = X band ?M32,
    case U >= 16#80000000 of
        true -> U - 16#100000000;
        false -> U
    end.
