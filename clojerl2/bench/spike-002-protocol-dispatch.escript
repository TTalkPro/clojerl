#!/usr/bin/env escript
%%! -mode(compile).
%% -*- erlang -*-
%%%-------------------------------------------------------------------
%%% spike-002 -- clojerl2-002 protocol dispatch benchmark
%%%
%%% Measures the three protocol dispatch strategies of designs/03-runtime-
%%% model.md 4.2 on a 100 protocols x 50 types scenario:
%%%
%%%   S0  static direct call     Mod:m0(X, A)              (ceiling, reference)
%%%   S1  direct remote call     apply(ImplMod, M, [X|A])  (designs/03 4.1 upper bound)
%%%   S2  impl module + ETS      clj_rt_protocol:impl(P,T) -> {ok,Mod} -> apply/3
%%%   S3  ETS fun table          ets {P,T,Method} -> fun, then call the fun
%%%
%%% Every one of the 5000 (protocol, type) pairs is backed by a REAL BEAM
%%% module compiled at runtime (bench_pP_tT, 4 methods of arity 2), so every
%%% dispatch is a real remote call into real loaded code.
%%%
%%% Usage: escript spike-002-protocol-dispatch.escript [Iters] [Reps] [Warmup]
%%%-------------------------------------------------------------------
-module(spike_002_protocol_dispatch).
-export([main/1]).

%% ---- scenario scale (designs/03 4.2) ---------------------------------------
-define(NP, 100).           %% protocols
-define(NT, 50).            %% types
-define(NM, 4).             %% methods per protocol
-define(NX, 100).           %% extra "unknown" type tags per protocol
-define(NI, ?NP * ?NT).     %% 5000 impl entries

%% ---- measurement defaults ---------------------------------------------------
-define(DEF_ITERS, 3000000).
-define(DEF_REPS, 3).
-define(DEF_WARM, 300000).

-define(IMPL_TAB, bench_proto_impl_tab).
-define(EXT_TAB, bench_fun_ext_tab).
-define(CLO_TAB, bench_fun_clo_tab).

%%%===================================================================
%%% main
%%%===================================================================

main(Args) ->
    {Iters, Reps, Warm} = opts(Args),
    print_header(Iters, Reps, Warm),
    T0 = erlang:monotonic_time(millisecond),
    S = setup(),
    T1 = erlang:monotonic_time(millisecond),
    io:format("~nsetup done: ~p real impl modules + ~p default modules + rt/index/static~n",
              [?NI, ?NP]),
    io:format("           ETS impl entries=~p  fun(ext)=~p  fun(clo)=~p~n",
              [ets:info(?IMPL_TAB, size), ets:info(?EXT_TAB, size),
               ets:info(?CLO_TAB, size)]),
    io:format("           generation + table build ~p ms, erlang memory ~p MB~n~n",
              [T1 - T0, erlang:memory(total) div (1024 * 1024)]),

    %% warmup every strategy once (code paths, fun table pages, ...)
    _ = [Loop(Warm, 0) || {_, Loop, _, _} <- strategies()],
    reset_cold(S),

    Results = [{Label, Ops, Cs, RepList, N}
               || {Label, Loop, Reset, Div} <- strategies(),
                  N <- [max(1000, Iters div Div)],
                  {Ops, Cs, RepList} <- [measure(Loop, fun() -> Reset(S) end,
                                                    N, Reps)]],

    print_table(Results, Iters),
    print_checksums(Results),
    print_verdict(Results).

opts([]) -> {?DEF_ITERS, ?DEF_REPS, ?DEF_WARM};
opts([A]) -> {int(A), ?DEF_REPS, ?DEF_WARM};
opts([A, B]) -> {int(A), int(B), ?DEF_WARM};
opts([A, B, C | _]) -> {int(A), int(B), int(C)}.

int(A) -> list_to_integer(A).

print_header(Iters, Reps, Warm) ->
    io:format("~n== clojerl2 spike-002: protocol dispatch benchmark ==~n"),
    io:format("OTP release      : ~s (~s)~n", [erlang:system_info(otp_release),
                                              erlang:system_info(system_architecture)]),
    io:format("schedulers / cpus: ~p online, ~p logical processors~n",
              [erlang:system_info(schedulers_online),
               erlang:system_info(logical_processors)]),
    io:format("scale            : ~p protocols x ~p types x ~p methods = ~p entries~n",
              [?NP, ?NT, ?NM, ?NI]),
    io:format("iters/reps/warmup: ~p / ~p / ~p~n", [Iters, Reps, Warm]).

%%%===================================================================
%%% setup: real BEAM modules + ETS tables
%%%===================================================================

setup() ->
    Ps = lists:seq(1, ?NP),
    Ts = lists:seq(1, ?NT),

    gen_impl_modules(Ps, Ts),
    gen_default_modules(Ps),
    gen_rt_module(),
    gen_index_module(Ps, Ts),
    gen_static_module(Ps, Ts),

    ets:new(?IMPL_TAB, [named_table, public, set, {read_concurrency, true}]),
    ets:new(?EXT_TAB, [named_table, public, set, {read_concurrency, true}]),
    ets:new(?CLO_TAB, [named_table, public, set, {read_concurrency, true}]),

    ets:insert(?IMPL_TAB,
               [{{proto(P), type(T)}, impl_mod(P, T)} || P <- Ps, T <- Ts]),

    Neg = extra_keys(Ps, ?NT),
    Cold = extra_keys(Ps, ?NT + ?NX),
    Coldb = extra_keys(Ps, ?NT + 2 * ?NX),
    ets:insert(?IMPL_TAB, [{{P, T}, none} || {P, T} <- Neg]),

    build_fun_tables(Ps, Ts),

    #{neg => Neg, cold => Cold, coldb => Coldb}.

%% three disjoint ranges of "type tags that have no impl module":
%%   51..150  pre-populated with `none'      -> steady state negative cache hit
%%   151..250 never inserted                  -> real cold miss + probe + backfill
%%   251..350 never inserted                  -> real cold miss, probe only
extra_keys(Ps, Base) ->
    [{proto(P), type(Base + K)} || P <- Ps, K <- lists:seq(1, ?NX)].

build_fun_tables(Ps, Ts) ->
    _ = lists:foreach(
          fun({P, T}) ->
                  Mod = impl_mod(P, T),
                  {module, Mod} = code:ensure_loaded(Mod),
                  Ms = lists:seq(0, ?NM - 1),
                  ets:insert(?EXT_TAB,
                             [{{proto(P), type(T), M}, meth_ext(Mod, M)} || M <- Ms]),
                  ets:insert(?CLO_TAB,
                             [{{proto(P), type(T), M}, meth_clo(Mod, M)} || M <- Ms])
          end, [{P, T} || P <- Ps, T <- Ts]),
    ok.

%% wipe negative-cache entries produced by a previous cold rep, so that every
%% cold iteration really is a cache miss
reset_cold(#{cold := Cold, coldb := Coldb}) ->
    _ = [ets:delete(?IMPL_TAB, K) || K <- Cold ++ Coldb],
    ok.

%%%===================================================================
%%% generated modules
%%%===================================================================

gen_impl_modules(Ps, Ts) ->
    N = length(Ps) * length(Ts),
    _ = lists:foldl(
          fun({P, T}, Cnt) ->
                  Mod = impl_mod(P, T),
                  S = atom_to_list(Mod),
                  I = integer_to_list(P * 100000 + T),
                  load(Mod,
                       forms(["-module(" ++ S ++ ").",
                              "-export([m0/2, m1/2, m2/2, m3/2, t0/0, t1/0, t2/0, t3/0]).",
                              "m0(X, A) -> X + A + " ++ I ++ ".",
                              "m1(X, A) -> X - A + " ++ I ++ ".",
                              "m2(X, A) -> X + A * " ++ I ++ ".",
                              "m3(X, A) -> X + A - " ++ I ++ ".",
                              "t0() -> fun " ++ S ++ ":m0/2.",
                              "t1() -> fun " ++ S ++ ":m1/2.",
                              "t2() -> fun " ++ S ++ ":m2/2.",
                              "t3() -> fun " ++ S ++ ":m3/2."])),
                  case (Cnt + 1) rem 1000 of
                      0 -> io:format("  .. ~p/~p impl modules~n", [Cnt + 1, N]);
                      _ -> ok
                  end,
                  Cnt + 1
          end, 0, [{P, T} || P <- Ps, T <- Ts]),
    ok.

gen_default_modules(Ps) ->
    _ = [begin
             Mod = def_mod(P),
             S = atom_to_list(Mod),
             I = integer_to_list(P),
             load(Mod,
                  forms(["-module(" ++ S ++ ").",
                         "-export([m0/2, m1/2, m2/2, m3/2]).",
                         "m0(X, A) -> X + A + " ++ I ++ ".",
                         "m1(X, A) -> X + A + " ++ I ++ ".",
                         "m2(X, A) -> X + A + " ++ I ++ ".",
                         "m3(X, A) -> X + A + " ++ I ++ "."]))
         end || P <- Ps],
    ok.

%% the runtime dispatch entry points of designs/03 4.1
gen_rt_module() ->
    load('bench_clj_rt_protocol',
         forms(["-module(bench_clj_rt_protocol).",
                "-export([impl/2, impl_cold/2, impl_cold_nb/2, impl_fun/4, candidate/2]).",
                "impl(P, T) ->\n"
                "    case ets:lookup(bench_proto_impl_tab, {P, T}) of\n"
                "        [{_, none}] -> error;\n"
                "        [{_, Mod}] -> {ok, Mod};\n"
                "        [] ->\n"
                "            Mod = candidate(P, T),\n"
                "            case code:ensure_loaded(Mod) of\n"
                "                {module, Mod} ->\n"
                "                    ets:insert(bench_proto_impl_tab, {{P, T}, Mod}),\n"
                "                    {ok, Mod};\n"
                "                _ ->\n"
                "                    ets:insert(bench_proto_impl_tab, {{P, T}, none}),\n"
                "                    error\n"
                "            end\n"
                "    end.",
                "impl_cold(P, T) ->\n"
                "    ets:delete(bench_proto_impl_tab, {P, T}),\n"
                "    case ets:lookup(bench_proto_impl_tab, {P, T}) of\n"
                "        [{_, none}] -> error;\n"
                "        [{_, Mod}] -> {ok, Mod};\n"
                "        [] ->\n"
                "            Mod = candidate(P, T),\n"
                "            case code:ensure_loaded(Mod) of\n"
                "                {module, Mod} ->\n"
                "                    ets:insert(bench_proto_impl_tab, {{P, T}, Mod}),\n"
                "                    {ok, Mod};\n"
                "                _ ->\n"
                "                    ets:insert(bench_proto_impl_tab, {{P, T}, none}),\n"
                "                    error\n"
                "            end\n"
                "    end.",
                "impl_cold_nb(P, T) ->\n"
                "    ets:delete(bench_proto_impl_tab, {P, T}),\n"
                "    case ets:lookup(bench_proto_impl_tab, {P, T}) of\n"
                "        [{_, none}] -> error;\n"
                "        [{_, Mod}] -> {ok, Mod};\n"
                "        [] ->\n"
                "            Mod = candidate(P, T),\n"
                "            case code:ensure_loaded(Mod) of\n"
                "                {module, Mod} -> {ok, Mod};\n"
                "                _ -> error\n"
                "            end\n"
                "    end.",
                "impl_fun(Tab, P, T, M) ->\n"
                "    case ets:lookup(Tab, {P, T, M}) of\n"
                "        [{_, F}] -> F;\n"
                "        [] -> none\n"
                "    end.",
                "candidate(P, T) ->\n"
                "    list_to_atom(\"bench_p\" ++ ds(P) ++ \"_t\" ++ ds(T)).",
                "ds(A) ->\n"
                "    case lists:splitwith(fun(C) -> C =/= $_ end, atom_to_list(A)) of\n"
                "        {_, [$_ | Ds]} -> Ds;\n"
                "        _ -> atom_to_list(A)\n"
                "    end."])).

%% mod/2 models "impl module name is a literal at the dispatch site":
%% a 5000-clause select_val over integer keys (no map/ETS copy).
%% key/2 does the same for the {Protocol, TypeTag} atom pair that the ETS
%% strategies look up -- so S2/S3 pay exactly the same "materialise the dispatch
%% key" cost as S1's mod/2, and the comparison stays apples-to-apples.
gen_index_module(Ps, Ts) ->
    ModBody = lists:flatten(
              join([io_lib:format("mod(~p, ~p) -> ~s", [P, T, impl_mod(P, T)])
                    || P <- Ps, T <- Ts], ";\n")) ++ ".",
    DefBody = lists:flatten(
              join([io_lib:format("defmod(~p) -> ~s", [P, def_mod(P)]) || P <- Ps],
                   ";\n")) ++ ".",
    KeyBody = lists:flatten(
              join([io_lib:format("key(~p, ~p) -> {p_~p, t_~p}", [P, T, P, T])
                    || P <- Ps, T <- Ts], ";\n")) ++ ".",
    PKeyBody = lists:flatten(
               join([io_lib:format("pkey(~p) -> p_~p", [P, P]) || P <- Ps],
                    ";\n")) ++ ".",
    TKeyBody = lists:flatten(
               join([io_lib:format("typeatom(~p) -> t_~p", [T, T])
                     || T <- lists:seq(1, ?NT + 3 * ?NX)], ";\n")) ++ ".",
    load('bench_index',
         forms(["-module(bench_index).",
                "-export([mod/2, defmod/1, key/2, pkey/1, typeatom/1]).",
                ModBody, DefBody, KeyBody, PKeyBody, TKeyBody])).

%% S0 reference: a fully direct-linked dispatch site (Mod:m0(X, A) as a remote
%% call with no apply at all), modelled as a 20000-clause select_val.
gen_static_module(Ps, Ts) ->
    Body = lists:flatten(
            join([io_lib:format("direct(~p, ~p, ~p, X, A) -> ~s:~s(X, A)",
                                [P, T, M, impl_mod(P, T), meth(M)])
                  || P <- Ps, T <- Ts, M <- lists:seq(0, ?NM - 1)], ";\n")) ++ ".",
    load('bench_static', forms(["-module(bench_static).", "-export([direct/5]).", Body])).

forms(FormStrs) -> [parse_form(F) || F <- FormStrs].

parse_form(S) ->
    {ok, Toks, _} = erl_scan:string(S),
    case erl_parse:parse_form(Toks) of
        {ok, Form} -> Form;
        {ok, Form, _} -> Form
    end.

load(Mod, Forms) ->
    {ok, Mod, Bin} = compile:forms(Forms, []),
    {module, Mod} = code:load_binary(Mod, atom_to_list(Mod), Bin),
    Mod.

join([], _) -> [];
join([X], _) -> X;
join([X | Xs], Sep) -> [X, Sep | join(Xs, Sep)].

proto(P) -> list_to_atom("p_" ++ integer_to_list(P)).
type(T) -> list_to_atom("t_" ++ integer_to_list(T)).
impl_mod(P, T) ->
    list_to_atom("bench_p" ++ integer_to_list(P) ++ "_t" ++ integer_to_list(T)).
def_mod(P) -> list_to_atom("bench_p" ++ integer_to_list(P) ++ "_default").

meth(M) ->
    case M of
        0 -> m0;
        1 -> m1;
        2 -> m2;
        3 -> m3
    end.

%% zero-environment external fun: the impl module hands out its own function
meth_ext(Mod, M) ->
    {module, Mod} = code:ensure_loaded(Mod),
    case M of
        0 -> Mod:t0();
        1 -> Mod:t1();
        2 -> Mod:t2();
        3 -> Mod:t3()
    end.

%% closure fun capturing {Mod, Method}: reading it from ETS copies the
%% environment, and the body needs a dynamic apply (designs/03 4.2 caveat)
meth_clo(Mod, M) ->
    Name = meth(M),
    fun(X, A) -> apply(Mod, Name, [X, A]) end.

%%%===================================================================
%%% measured loops (identical workload derivation in every loop)
%%%===================================================================

%% {Label, Loop, Reset, IterationDivisor}
%% the cold-miss rows are ~1-2 orders of magnitude more expensive per op, so
%% they run fewer iterations (the divisor is printed in the result table).
strategies() ->
    [{"H 基准: 仅 workload 计算(无分派)", fun s_none/2, fun no_reset/1, 1},
     {"S0 静态直接链接 (无 apply, 参考)", fun s0/2, fun no_reset/1, 1},
     {"S1 直接远程调用 apply/3 (上限)", fun s1/2, fun no_reset/1, 1},
     {"S2 impl+ETS 命中", fun s2_hit/2, fun no_reset/1, 1},
     {"S2 impl+ETS 未命中(负缓存)", fun s2_neg/2, fun no_reset/1, 1},
     {"S2 impl+ETS 冷未命中(回填)", fun s2_cold/2, fun no_reset/1, 10},
     {"S2 impl+ETS 冷未命中(不回填)", fun s2_cold_nb/2, fun no_reset/1, 30},
     {"S3 ETS fun 表 外部 fun", fun s3_ext/2, fun no_reset/1, 1},
     {"S3 ETS fun 表 闭包 fun", fun s3_clo/2, fun no_reset/1, 1}].

no_reset(_) -> ok.

-define(R, ((N * 2654435761) bsr 5)).
-define(P, ((?R rem ?NP) + 1)).
-define(T, (((?R div ?NP) rem ?NT) + 1)).
-define(M, ((?R div (?NP * ?NT)) rem ?NM)).
-define(X, (N band 255)).
-define(A, ((N bsr 8) band 255)).
-define(ACC(V), ((Acc + V) band 16#FFFFFFFF)).

%% the dispatch-free baseline: same workload arithmetic, no protocol dispatch.
%% its ns/op is the measurement harness overhead shared by every other row.
s_none(0, Acc) -> Acc;
s_none(N, Acc) ->
    V = ?X + ?A + ?P + ?T + ?M,
    s_none(N - 1, ?ACC(V)).

s0(0, Acc) -> Acc;
s0(N, Acc) ->
    V = bench_static:direct(?P, ?T, ?M, ?X, ?A),
    s0(N - 1, ?ACC(V)).

s1(0, Acc) -> Acc;
s1(N, Acc) ->
    V = apply(bench_index:mod(?P, ?T), meth(?M), [?X, ?A]),
    s1(N - 1, ?ACC(V)).

s2_hit(0, Acc) -> Acc;
s2_hit(N, Acc) ->
    {Pt, Tt} = bench_index:key(?P, ?T),
    V = case bench_clj_rt_protocol:impl(Pt, Tt) of
            {ok, Mod} -> apply(Mod, meth(?M), [?X, ?A]);
            error -> apply(bench_index:defmod(?P), meth(?M), [?X, ?A])
        end,
    s2_hit(N - 1, ?ACC(V)).

s2_neg(0, Acc) -> Acc;
s2_neg(N, Acc) ->
    T = bench_index:typeatom(?NT + ((?R div ?NP) rem ?NX) + 1),
    V = case bench_clj_rt_protocol:impl(bench_index:pkey(?P), T) of
            {ok, Mod} -> apply(Mod, meth(?M), [?X, ?A]);
            error -> apply(bench_index:defmod(?P), meth(?M), [?X, ?A])
        end,
    s2_neg(N - 1, ?ACC(V)).

s2_cold(0, Acc) -> Acc;
s2_cold(N, Acc) ->
    T = bench_index:typeatom(?NT + ?NX + ((?R div ?NP) rem ?NX) + 1),
    V = case bench_clj_rt_protocol:impl_cold(bench_index:pkey(?P), T) of
            {ok, Mod} -> apply(Mod, meth(?M), [?X, ?A]);
            error -> apply(bench_index:defmod(?P), meth(?M), [?X, ?A])
        end,
    s2_cold(N - 1, ?ACC(V)).

s2_cold_nb(0, Acc) -> Acc;
s2_cold_nb(N, Acc) ->
    T = bench_index:typeatom(?NT + 2 * ?NX + ((?R div ?NP) rem ?NX) + 1),
    V = case bench_clj_rt_protocol:impl_cold_nb(bench_index:pkey(?P), T) of
            {ok, Mod} -> apply(Mod, meth(?M), [?X, ?A]);
            error -> apply(bench_index:defmod(?P), meth(?M), [?X, ?A])
        end,
    s2_cold_nb(N - 1, ?ACC(V)).

s3_ext(0, Acc) -> Acc;
s3_ext(N, Acc) ->
    {Pt, Tt} = bench_index:key(?P, ?T),
    F = bench_clj_rt_protocol:impl_fun(?EXT_TAB, Pt, Tt, ?M),
    s3_ext(N - 1, ?ACC(F(?X, ?A))).

s3_clo(0, Acc) -> Acc;
s3_clo(N, Acc) ->
    {Pt, Tt} = bench_index:key(?P, ?T),
    F = bench_clj_rt_protocol:impl_fun(?CLO_TAB, Pt, Tt, ?M),
    s3_clo(N - 1, ?ACC(F(?X, ?A))).

%%%===================================================================
%%% measurement
%%%===================================================================

measure(Loop, Reset, Iters, Reps) ->
    Run = fun() ->
                  Reset(),
                  T0 = erlang:monotonic_time(nanosecond),
                  Cs = Loop(Iters, 0),
                  T1 = erlang:monotonic_time(nanosecond),
                  {Iters * 1000000000 div (T1 - T0), Cs, T1 - T0}
          end,
    Reps1 = [Run() || _ <- lists:seq(1, Reps)],
    [{BestOps, BestCs, _} | _] = lists:keysort(1, Reps1),
    {BestOps, BestCs, Reps1}.

%%%===================================================================
%%% reporting
%%%===================================================================

print_table(Results, Iters) ->
    S1Ops = ops("S1 直接远程调用 apply/3 (上限)", Results),
    io:format("~n== 分派吞吐 (基础迭代数 ~w, 各行可能按倍数缩减, 取 best-of-N) ==~n",
              [Iters]),
    io:format("~-32ts ~9s ~12s ~9s ~9s~n",
              ["策略", "iters", "ops/sec", "ns/op", "vs S1"]),
    io:format("~-32ts ~9s ~12s ~9s ~9s~n",
              [lists:duplicate(32, $-), lists:duplicate(9, $-),
               lists:duplicate(12, $-), lists:duplicate(9, $-),
               lists:duplicate(9, $-)]),
    _ = [io:format("~-32ts ~9w ~12w ~9.1f ~8.3fx~n",
                   [Label, N, Ops, 1000000000 / Ops, Ops / S1Ops])
         || {Label, Ops, _, _, N} <- Results],
    io:format("~n各轮耗时:~n"),
    _ = [io:format("~-32ts ~ts~n",
                   [Label, string:join([fmt_ns(Ns) || {_, _, Ns} <- Reps], "  ")])
         || {Label, _, _, Reps, _} <- Results],
    ok.

fmt_ns(Ns) -> io_lib:format("~.1fms", [Ns / 1000000]).

ops(Label, Results) ->
    {Label, Ops, _, _, _} = lists:keyfind(Label, 1, Results),
    Ops.

print_checksums(Results) ->
    io:format("~n== checksum (防死代码消除) ==~n"),
    _ = [begin
             {_, _, Cs, Reps, _} = lists:keyfind(Label, 1, Results),
             Stable = case lists:usort([C || {_, C, _} <- Reps]) of
                          [_] -> "reps 一致";
                          _ -> "!! 各轮不一致 !!"
                      end,
             io:format("~-32ts ~12w  ~ts~n", [Label, Cs, Stable])
         end || {Label, _, _, _, _} <- Results],
    S1Cs = ops_cs("S1 直接远程调用 apply/3 (上限)", Results),
    Same = [L || {L, _, C, _, _} <- Results, C =:= S1Cs, L =/= element(1, hd(Results))],
    io:format("~n与 S1 checksum 相同的策略 (命中路径语义等价): ~ts~n",
              [string:join(Same, ", ")]).

ops_cs(Label, Results) ->
    {Label, _, Cs, _, _} = lists:keyfind(Label, 1, Results),
    Cs.

print_verdict(Results) ->
    S1Label = "S1 直接远程调用 apply/3 (上限)",
    S2Label = "S2 impl+ETS 命中",
    S3Label = "S3 ETS fun 表 外部 fun",
    S1Ops = ops(S1Label, Results),
    S2Ops = ops(S2Label, Results),
    S3Ops = ops(S3Label, Results),
    Ratio = S2Ops / S1Ops,
    Threshold = 1.0 / 3.0,
    io:format("~n== 判据 (designs/03 4.2): S2 吞吐 >= S1 的 1/3 即采纳 ==~n"),
    io:format("S1 直接远程调用 apply/3      : ~w ops/sec (~.1f ns/op)~n",
              [S1Ops, 1000000000 / S1Ops]),
    io:format("S2 impl+ETS 命中             : ~w ops/sec (~.1f ns/op)~n",
              [S2Ops, 1000000000 / S2Ops]),
    io:format("S3 ETS fun 表 (外部 fun)      : ~w ops/sec (~.1f ns/op)~n",
              [S3Ops, 1000000000 / S3Ops]),
    io:format("S2/S1 = ~.4f  (阈值 ~.4f); S3/S1 = ~.4f~n",
              [Ratio, Threshold, S3Ops / S1Ops]),
    io:format("S2 相对 S1 慢 ~.2f 倍; S3 相对 S1 慢 ~.2f 倍~n",
              [S1Ops / S2Ops, S1Ops / S3Ops]),
    io:format("判据: ~ts~n",
              [case Ratio >= Threshold of true -> "PASS"; false -> "FAIL" end]),
    io:format("结论: ~ts~n",
              [case Ratio >= Threshold of
                   true -> "采纳 impl 模块 + ETS 存在性缓存 (designs/03 4.1 分派形状)";
                   false -> "退回 ETS fun 表方案"
               end]).
