#!/usr/bin/env escript
%%! -mode(compile) +S 1:1 +sbtu +A1
%% -*- erlang -*-
%% =====================================================================
%% clojerl2-001 值表示 spike
%%   A  = 打标元组 {Tag, Meta, FieldsTuple}    designs/03-runtime-model.md §1.4
%%   A' = 打标元组 {Tag, Meta, FieldsMap}      (字段本身是 map 的变体)
%%   B  = clojerl 1.0 式 #{?TYPE => Tag, ...}  (include/clojerl.hrl 的 ?TYPE)
%%
%% 运行: escript clojerl2/bench/spike-001-value-repr.escript
%%
%% 方法学(踩过的坑都记在这):
%%   1) escript 以 -mode(compile) 编译执行(走 BEAM JIT),+S 1:1 固定单调度器
%%   2) 输入流一次性建好并在整个循环中保持存活。不要在循环里重建列表:
%%      实测 4096 元素列表每轮重建 ≈ +60 ns/次,会把被测操作完全淹没
%%   3) 每格先热身 ?WARMUP 次,再采样 ?SAMPLES 次,报告 median 与 min
%%   4) checksum:产生新值的操作(构造 / with-meta)不能用 `X =:= 常量`、
%%      `erlang:size/1`、`element/2` 之类做消费——BEAM 会把整段构造优化掉
%%      (见 §4 DCE 校验)。这里统一用 `b2i(V =:= Ref)`,Ref 取自另一条不透明
%%      列表:比较必须真正检查 V,构造无法被折叠;同时为每个表示单测一行
%%      "[基准] 只消费不构造",净成本 = 该行 − 基准行
%%   5) 不产生新值的操作(字段访问 / 分派 / 相等)直接累加整数或布尔值
%%   6) 所有 cell 的循环骨架一致(链表遍历 + 累加),harness 基线单独列出
%% =====================================================================

-define(TYPE_KEY, '__type__').
-define(META_KEY,  'meta').

-define(N_REC,   100000).
-define(N_COLL,  50000).
-define(N_KW,    50000).
-define(SAMPLES, 4).
-define(WARMUP,  1).
-define(LISTLEN, 256).

-define(TAGS, ['user.T1','user.T2','user.T3','user.T4',
               'user.T5','user.T6','user.T7','user.T8']).

-define(BAR, "======================================================================").

%% =====================================================================
%% main
%% =====================================================================
main(_) ->
    ok = io:setopts(standard_io, [{encoding, unicode}]),
    D = data(),
    print_env(),
    sec_record(D),
    sec_collections(D),
    sec_dce(D),
    sec_keyword(),
    sec_summary(D),
    ok.

print_env() ->
    io:format("~n=== clojerl2-001 spike: {Tag,Meta,Data} vs clojerl1.0 map+?TYPE ===~n"),
    io:format("run mode     : escript -mode(compile) (BEAM JIT), emu args +S 1:1~n"),
    io:format("OTP release  : ~s~n", [erlang:system_info(otp_release)]),
    io:format("ERTS version : ~s~n", [erlang:system_info(version)]),
    io:format("architecture : ~s, word size ~p~n",
              [erlang:system_info(system_architecture), erlang:system_info(wordsize)]),
    io:format("schedulers   : online=~p~n", [erlang:system_info(schedulers_online)]),
    io:format("CPU          : ~s~n", [cpu_model()]),
    io:format("iters/cell   : record ~p, collection ~p, keyword ~p; samples ~p (warmup ~p)~n",
              [?N_REC, ?N_COLL, ?N_KW, ?SAMPLES, ?WARMUP]),
    ok.

cpu_model() ->
    case file:read_file("/proc/cpuinfo") of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            case [L || L <- Lines, binary:match(L, <<"model name">>) =/= nomatch] of
                [L | _] -> L;
                []       -> "unknown"
            end;
        _ -> "unknown"
    end.

%% =====================================================================
%% 计时与表格
%% =====================================================================
time_it(F) ->
    T0 = erlang:monotonic_time(nanosecond),
    R  = F(),
    T1 = erlang:monotonic_time(nanosecond),
    {T1 - T0, R}.

measure(F) ->
    Cs = [F() || _ <- lists:seq(1, ?WARMUP)],
    Ts = lists:sort([element(1, time_it(F)) || _ <- lists:seq(1, ?SAMPLES)]),
    {Ts, lists:last(Cs)}.

med(Ts) -> lists:nth((length(Ts) div 2) + 1, Ts).
mn(Ts)  -> hd(Ts).

fmt(F) -> lists:flatten(io_lib:format("~B", [round(F)])).

hdr() ->
    io:format("~-30s ~10s ~12s ~10s ~12s~n",
              ["op", "ns/op med", "ops/s med", "ns/op min", "ops/s min"]),
    io:format("~s~n", [lists:duplicate(79, $-)]).

%% 返回 checksum;同时把 median/min 供后面算净值
report(Name, F, N) ->
    {Ts, C} = measure(F),
    io:format("~-30ts ~10.2f ~12s ~10.2f ~12s~n",
              [Name, med(Ts) / N, fmt(N * 1.0e9 / med(Ts)), mn(Ts) / N, fmt(N * 1.0e9 / mn(Ts))]),
    C.

netrow(Name, Raw, Base) ->
    D = (Raw - Base) / ?N_REC,
    io:format("~-30ts ~10.2f ~12s~n", [Name, D, fmt(1.0e9 / D)]).



b2i(true) -> 1;
b2i(_)    -> 0.

%% =====================================================================
%% 测试数据(全部在 main 里构建一次,循环中保持存活)
%% =====================================================================
zip2([], []) -> [];
zip2([A | As], [B | Bs]) -> [{A, B} | zip2(As, Bs)].

%% 把标签表重复到 N 个元素(让 8 个分支均匀命中)
cycle([], N) when N > 0 -> cycle(?TAGS, N);
cycle(_, 0)             -> [];
cycle([H | T], N)       -> [H | cycle(T, N - 1)].

%% 256 组输入,标签轮转(让 dispatch 的 8 个分支均匀命中)
inputs() ->
    Tags   = cycle(?TAGS, ?LISTLEN),
    Fields = [{I, I + 1, I + 2, I + 3, I + 4} || I <- lists:seq(1, ?LISTLEN)],
    [{T, A, B, C, D, E} || {T, {A, B, C, D, E}} <- zip2(Tags, Fields)].

ints() -> lists:seq(1, ?LISTLEN).

field_map({A, B, C, D, E}) -> #{f1 => A, f2 => B, f3 => C, f4 => D, f5 => E}.

b_rec({T, A, B, C, D, E}) ->
    #{?TYPE_KEY => T, f1 => A, f2 => B, f3 => C, f4 => D, f5 => E}.

insts_a()    -> [{T, nil, {A, B, C, D, E}} || {T, A, B, C, D, E} <- inputs()].
insts_amap() -> [{T, nil, field_map({A, B, C, D, E})} || {T, A, B, C, D, E} <- inputs()].
insts_b()    -> [b_rec(I) || I <- inputs()].

%% 独立构建的同值第二份(避免 =:= 折叠成常量)
insts_a2()    -> [{T, nil, {A, B, C, D, E}} || {T, A, B, C, D, E} <- inputs()].
insts_amap2() -> [{T, nil, field_map({A, B, C, D, E})} || {T, A, B, C, D, E} <- inputs()].
insts_b2()    -> [b_rec(I) || I <- inputs()].

%% 第 5 字段不同的版本(= 判定走到最后才返回 false)
insts_ad2()    -> [{T, nil, {A, B, C, D, E + 2}} || {T, A, B, C, D, E} <- inputs()].
insts_amapd2() -> [{T, nil, field_map({A, B, C, D, E + 2})} || {T, A, B, C, D, E} <- inputs()].
insts_bd2()    -> [b_rec({T, A, B, C, D, E + 2}) || {T, A, B, C, D, E} <- inputs()].

%% 消费基准用的不透明 Ref:形状相同但大小/首元素不同,比较立刻失败
refs_a()    -> [{'user.Z', nil, junk} || _ <- inputs()].
refs_amap() -> [{'user.Z', nil, field_map({0, 0, 0, 0, 0})} || _ <- inputs()].
refs_b()    -> [#{?TYPE_KEY => 'user.Z', z => 1} || _ <- inputs()].

meta() -> #{line => 42, col => 7, file => <<"user.clj">>}.

tuple8(I) -> {I, I + 1, I + 2, I + 3, I + 4, I + 5, I + 6, I + 7}.
inner5(I) -> #{k1 => I, k2 => I + 1, k3 => I + 2, k4 => I + 3, k5 => I + 4}.

data() ->
    #{ inputs      => inputs(),
       ints        => ints(),
       insts_a     => insts_a(),
       insts_amap  => insts_amap(),
       insts_b     => insts_b(),
       insts_a2    => insts_a2(),
       insts_amap2 => insts_amap2(),
       insts_b2    => insts_b2(),
       ad2         => insts_ad2(),
       amapd2      => insts_amapd2(),
       bd2         => insts_bd2(),
       refs_a      => refs_a(),
       refs_amap   => refs_amap(),
       refs_b      => refs_b(),
       vec8        => [tuple8(I) || I <- lists:seq(1, ?LISTLEN)],
       map5        => [inner5(I) || I <- lists:seq(1, ?LISTLEN)],
       vecs_a      => [{vector, nil, tuple8(I)} || I <- lists:seq(1, ?LISTLEN)],
       vecs_b      => [#{?TYPE_KEY => 'clojerl.Vector', array => tuple8(I), ?META_KEY => nil}
                       || I <- lists:seq(1, ?LISTLEN)],
       maps_a      => [{map, nil, inner5(I)} || I <- lists:seq(1, ?LISTLEN)],
       maps_b      => [#{?TYPE_KEY => 'clojerl.Map', map => inner5(I), count => 5, ?META_KEY => nil}
                       || I <- lists:seq(1, ?LISTLEN)],
       sets_a      => [{set, nil, inner5(I)} || I <- lists:seq(1, ?LISTLEN)],
       sets_b      => [#{?TYPE_KEY => 'clojerl.Set', map => inner5(I), count => 5, ?META_KEY => nil}
                       || I <- lists:seq(1, ?LISTLEN)],
       vrefs_a     => [{vector, nil, junk} || _ <- lists:seq(1, ?LISTLEN)],
       vrefs_b     => [#{?TYPE_KEY => 'user.Z', z => 1} || _ <- lists:seq(1, ?LISTLEN)],
       mrefs_a     => [{map, nil, #{}} || _ <- lists:seq(1, ?LISTLEN)],
       mrefs_b     => [#{?TYPE_KEY => 'user.Z', z => 1} || _ <- lists:seq(1, ?LISTLEN)],
       srefs_a     => [{set, nil, #{}} || _ <- lists:seq(1, ?LISTLEN)],
       srefs_b     => [#{?TYPE_KEY => 'user.Z', z => 1} || _ <- lists:seq(1, ?LISTLEN)] }.

g(D, K) -> maps:get(K, D).

%% =====================================================================
%% §1 record/deftype:构造 / 字段访问 / 标签 / 分派 / with-meta / 相等
%%     产生新值的循环签名: loop(N, List, Cur, RefList, RefCur, Acc)
%% =====================================================================

%% ---- harness 基线:只有链表遍历 ----
bench_base(D) -> L = g(D, ints), loop_base(?N_REC, L, L, 0).
loop_base(0, _, _, _) -> ok;
loop_base(N, L, [X | R], _) -> loop_base(N - 1, L, R, X);
loop_base(N, L, [], _)    -> loop_base(N, L, L, 0).

%% ---- A: {Tag, Meta, FieldsTuple} ----
bench_con_a(D) -> L = g(D, inputs), R = g(D, refs_a), loop_con_a(?N_REC, L, L, R, R, 0).
loop_con_a(0, _, _, _, _, _) -> ok;
loop_con_a(N, L, [{T, A, B, C, D1, E} | R], Rs, [Ref | RR], Acc) ->
    V = {T, nil, {A, B, C, D1, E}},
    loop_con_a(N - 1, L, R, Rs, RR, Acc + A + b2i(V =:= Ref));
loop_con_a(N, L, [], Rs, RR, Acc) -> loop_con_a(N, L, L, Rs, RR, Acc);
loop_con_a(N, L, R, Rs, [], Acc) -> loop_con_a(N, L, R, Rs, Rs, Acc).

bench_get_a(D) -> L = g(D, insts_a), loop_get_a(?N_REC, L, L, 0).
loop_get_a(0, _, _, _) -> ok;
loop_get_a(N, L, [X | R], _) -> loop_get_a(N - 1, L, R, element(2, element(3, X)));
loop_get_a(N, L, [], _) -> loop_get_a(N, L, L, 0).

bench_tag_a(D) -> L = g(D, insts_a), loop_tag_a(?N_REC, L, L, 0).
loop_tag_a(0, _, _, _) -> ok;
loop_tag_a(N, L, [{T, _, _} | R], _) -> loop_tag_a(N - 1, L, R, b2i(T =:= 'user.T1'));
loop_tag_a(N, L, [], _) -> loop_tag_a(N, L, L, 0).

bench_disp_a(D) -> L = g(D, insts_a), loop_disp_a(?N_REC, L, L, 0).
loop_disp_a(0, _, _, _) -> ok;
loop_disp_a(N, L, [X | R], _) -> loop_disp_a(N - 1, L, R, dispatch_a(X));
loop_disp_a(N, L, [], _) -> loop_disp_a(N, L, L, 0).

dispatch_a({T, _, _}) -> impl_id(T).

bench_dcall_a(D) -> L = g(D, insts_a), loop_dcall_a(?N_REC, L, L, 0).
loop_dcall_a(0, _, _, _) -> ok;
loop_dcall_a(N, L, [X | R], _) -> loop_dcall_a(N - 1, L, R, dapply_a(X));
loop_dcall_a(N, L, [], _) -> loop_dcall_a(N, L, L, 0).

dapply_a({'user.T1', _, _} = X) -> impl_1(X);
dapply_a({'user.T2', _, _} = X) -> impl_2(X);
dapply_a({'user.T3', _, _} = X) -> impl_3(X);
dapply_a({'user.T4', _, _} = X) -> impl_4(X);
dapply_a({'user.T5', _, _} = X) -> impl_5(X);
dapply_a({'user.T6', _, _} = X) -> impl_6(X);
dapply_a({'user.T7', _, _} = X) -> impl_7(X);
dapply_a({'user.T8', _, _} = X) -> impl_8(X).

bench_wm_a(D) -> L = g(D, insts_a), R = g(D, refs_a), loop_wm_a(?N_REC, L, L, R, R, 0).
loop_wm_a(0, _, _, _, _, _) -> ok;
loop_wm_a(N, L, [X | R], Rs, [Ref | RR], Acc) ->
    V = setelement(2, X, meta()),
    loop_wm_a(N - 1, L, R, Rs, RR, Acc + b2i(V =:= Ref));
loop_wm_a(N, L, [], Rs, RR, Acc) -> loop_wm_a(N, L, L, Rs, RR, Acc);
loop_wm_a(N, L, R, Rs, [], Acc) -> loop_wm_a(N, L, R, Rs, Rs, Acc).

bench_off_a(D) -> L = g(D, insts_a), R = g(D, refs_a), loop_off_a(?N_REC, L, L, R, R, 0).
loop_off_a(0, _, _, _, _, _) -> ok;
loop_off_a(N, L, [X | R], Rs, [Ref | RR], Acc) -> loop_off_a(N - 1, L, R, Rs, RR, Acc + b2i(X =:= Ref));
loop_off_a(N, L, [], Rs, RR, Acc) -> loop_off_a(N, L, L, Rs, RR, Acc);
loop_off_a(N, L, R, Rs, [], Acc) -> loop_off_a(N, L, R, Rs, Rs, Acc).

bench_eq_a(D) -> L = g(D, insts_a), L2 = g(D, insts_a2), loop_eq_a(?N_REC, L, L, L2, L2, 0).
loop_eq_a(0, _, _, _, _, _) -> ok;
loop_eq_a(N, L, [X | R], Ys0, [Y | Ys], Acc) -> loop_eq_a(N - 1, L, R, Ys0, Ys, Acc + b2i(X =:= Y));
loop_eq_a(N, L, [], Ys0, _Ys, Acc) -> loop_eq_a(N, L, L, Ys0, Ys0, Acc).

bench_neq_a(D) -> L = g(D, insts_a), L2 = g(D, ad2), loop_neq_a(?N_REC, L, L, L2, L2, 0).
loop_neq_a(0, _, _, _, _, _) -> ok;
loop_neq_a(N, L, [X | R], Ys0, [Y | Ys], Acc) -> loop_neq_a(N - 1, L, R, Ys0, Ys, Acc + b2i(X =:= Y));
loop_neq_a(N, L, [], Ys0, _Ys, Acc) -> loop_neq_a(N, L, L, Ys0, Ys0, Acc).

%% ---- A': {Tag, Meta, FieldsMap} ----
bench_con_amap(D) -> L = g(D, inputs), R = g(D, refs_amap), loop_con_amap(?N_REC, L, L, R, R, 0).
loop_con_amap(0, _, _, _, _, _) -> ok;
loop_con_amap(N, L, [{T, A, B, C, D1, E} | R], Rs, [Ref | RR], Acc) ->
    V = {T, nil, #{f1 => A, f2 => B, f3 => C, f4 => D1, f5 => E}},
    loop_con_amap(N - 1, L, R, Rs, RR, Acc + A + b2i(V =:= Ref));
loop_con_amap(N, L, [], Rs, RR, Acc) -> loop_con_amap(N, L, L, Rs, RR, Acc);
loop_con_amap(N, L, R, Rs, [], Acc) -> loop_con_amap(N, L, R, Rs, Rs, Acc).

bench_get_amap(D) -> L = g(D, insts_amap), loop_get_amap(?N_REC, L, L, 0).
loop_get_amap(0, _, _, _) -> ok;
loop_get_amap(N, L, [X | R], _) -> loop_get_amap(N - 1, L, R, maps:get(f2, element(3, X)));
loop_get_amap(N, L, [], _) -> loop_get_amap(N, L, L, 0).

bench_tag_amap(D) -> L = g(D, insts_amap), loop_tag_amap(?N_REC, L, L, 0).
loop_tag_amap(0, _, _, _) -> ok;
loop_tag_amap(N, L, [{T, _, _} | R], _) -> loop_tag_amap(N - 1, L, R, b2i(T =:= 'user.T1'));
loop_tag_amap(N, L, [], _) -> loop_tag_amap(N, L, L, 0).

bench_disp_amap(D) -> L = g(D, insts_amap), loop_disp_amap(?N_REC, L, L, 0).
loop_disp_amap(0, _, _, _) -> ok;
loop_disp_amap(N, L, [X | R], _) -> loop_disp_amap(N - 1, L, R, dispatch_amap(X));
loop_disp_amap(N, L, [], _) -> loop_disp_amap(N, L, L, 0).

dispatch_amap({T, _, _}) -> impl_id(T).

bench_dcall_amap(D) -> L = g(D, insts_amap), loop_dcall_amap(?N_REC, L, L, 0).
loop_dcall_amap(0, _, _, _) -> ok;
loop_dcall_amap(N, L, [X | R], _) -> loop_dcall_amap(N - 1, L, R, dapply_amap(X));
loop_dcall_amap(N, L, [], _) -> loop_dcall_amap(N, L, L, 0).

dapply_amap({'user.T1', _, _} = X) -> impl_1(X);
dapply_amap({'user.T2', _, _} = X) -> impl_2(X);
dapply_amap({'user.T3', _, _} = X) -> impl_3(X);
dapply_amap({'user.T4', _, _} = X) -> impl_4(X);
dapply_amap({'user.T5', _, _} = X) -> impl_5(X);
dapply_amap({'user.T6', _, _} = X) -> impl_6(X);
dapply_amap({'user.T7', _, _} = X) -> impl_7(X);
dapply_amap({'user.T8', _, _} = X) -> impl_8(X).

bench_wm_amap(D) -> L = g(D, insts_amap), R = g(D, refs_amap), loop_wm_amap(?N_REC, L, L, R, R, 0).
loop_wm_amap(0, _, _, _, _, _) -> ok;
loop_wm_amap(N, L, [X | R], Rs, [Ref | RR], Acc) ->
    V = setelement(2, X, meta()),
    loop_wm_amap(N - 1, L, R, Rs, RR, Acc + b2i(V =:= Ref));
loop_wm_amap(N, L, [], Rs, RR, Acc) -> loop_wm_amap(N, L, L, Rs, RR, Acc);
loop_wm_amap(N, L, R, Rs, [], Acc) -> loop_wm_amap(N, L, R, Rs, Rs, Acc).

bench_off_amap(D) ->
    L = g(D, insts_amap), R = g(D, refs_amap), loop_off_amap(?N_REC, L, L, R, R, 0).
loop_off_amap(0, _, _, _, _, _) -> ok;
loop_off_amap(N, L, [X | R], Rs, [Ref | RR], Acc) -> loop_off_amap(N - 1, L, R, Rs, RR, Acc + b2i(X =:= Ref));
loop_off_amap(N, L, [], Rs, RR, Acc) -> loop_off_amap(N, L, L, Rs, RR, Acc);
loop_off_amap(N, L, R, Rs, [], Acc) -> loop_off_amap(N, L, R, Rs, Rs, Acc).

bench_eq_amap(D) ->
    L = g(D, insts_amap), L2 = g(D, insts_amap2), loop_eq_amap(?N_REC, L, L, L2, L2, 0).
loop_eq_amap(0, _, _, _, _, _) -> ok;
loop_eq_amap(N, L, [X | R], Ys0, [Y | Ys], Acc) -> loop_eq_amap(N - 1, L, R, Ys0, Ys, Acc + b2i(X =:= Y));
loop_eq_amap(N, L, [], Ys0, _Ys, Acc) -> loop_eq_amap(N, L, L, Ys0, Ys0, Acc).

bench_neq_amap(D) ->
    L = g(D, insts_amap), L2 = g(D, amapd2), loop_neq_amap(?N_REC, L, L, L2, L2, 0).
loop_neq_amap(0, _, _, _, _, _) -> ok;
loop_neq_amap(N, L, [X | R], Ys0, [Y | Ys], Acc) -> loop_neq_amap(N - 1, L, R, Ys0, Ys, Acc + b2i(X =:= Y));
loop_neq_amap(N, L, [], Ys0, _Ys, Acc) -> loop_neq_amap(N, L, L, Ys0, Ys0, Acc).

%% ---- B: #{?TYPE => Tag, f1..f5}(clojerl 1.0 实际表示) ----
bench_con_b(D) -> L = g(D, inputs), R = g(D, refs_b), loop_con_b(?N_REC, L, L, R, R, 0).
loop_con_b(0, _, _, _, _, _) -> ok;
loop_con_b(N, L, [{T, A, B, C, D1, E} | R], Rs, [Ref | RR], Acc) ->
    V = #{?TYPE_KEY => T, f1 => A, f2 => B, f3 => C, f4 => D1, f5 => E},
    loop_con_b(N - 1, L, R, Rs, RR, Acc + A + b2i(V =:= Ref));
loop_con_b(N, L, [], Rs, RR, Acc) -> loop_con_b(N, L, L, Rs, RR, Acc);
loop_con_b(N, L, R, Rs, [], Acc) -> loop_con_b(N, L, R, Rs, Rs, Acc).

bench_get_b(D) -> L = g(D, insts_b), loop_get_b(?N_REC, L, L, 0).
loop_get_b(0, _, _, _) -> ok;
loop_get_b(N, L, [X | R], _) -> loop_get_b(N - 1, L, R, maps:get(f2, X));
loop_get_b(N, L, [], _) -> loop_get_b(N, L, L, 0).

bench_tag_b(D) -> L = g(D, insts_b), loop_tag_b(?N_REC, L, L, 0).
loop_tag_b(0, _, _, _) -> ok;
loop_tag_b(N, L, [X | R], _) -> loop_tag_b(N - 1, L, R, b2i(maps:get(?TYPE_KEY, X) =:= 'user.T1'));
loop_tag_b(N, L, [], _) -> loop_tag_b(N, L, L, 0).

bench_disp_b(D) -> L = g(D, insts_b), loop_disp_b(?N_REC, L, L, 0).
loop_disp_b(0, _, _, _) -> ok;
loop_disp_b(N, L, [X | R], _) -> loop_disp_b(N - 1, L, R, dispatch_b(X));
loop_disp_b(N, L, [], _) -> loop_disp_b(N, L, L, 0).

dispatch_b(#{?TYPE_KEY := T}) -> impl_id(T).

bench_dcall_b(D) -> L = g(D, insts_b), loop_dcall_b(?N_REC, L, L, 0).
loop_dcall_b(0, _, _, _) -> ok;
loop_dcall_b(N, L, [X | R], _) -> loop_dcall_b(N - 1, L, R, dapply_b(X));
loop_dcall_b(N, L, [], _) -> loop_dcall_b(N, L, L, 0).

dapply_b(#{?TYPE_KEY := 'user.T1'} = X) -> impl_1(X);
dapply_b(#{?TYPE_KEY := 'user.T2'} = X) -> impl_2(X);
dapply_b(#{?TYPE_KEY := 'user.T3'} = X) -> impl_3(X);
dapply_b(#{?TYPE_KEY := 'user.T4'} = X) -> impl_4(X);
dapply_b(#{?TYPE_KEY := 'user.T5'} = X) -> impl_5(X);
dapply_b(#{?TYPE_KEY := 'user.T6'} = X) -> impl_6(X);
dapply_b(#{?TYPE_KEY := 'user.T7'} = X) -> impl_7(X);
dapply_b(#{?TYPE_KEY := 'user.T8'} = X) -> impl_8(X).

impl_id('user.T1') -> 1;
impl_id('user.T2') -> 2;
impl_id('user.T3') -> 3;
impl_id('user.T4') -> 4;
impl_id('user.T5') -> 5;
impl_id('user.T6') -> 6;
impl_id('user.T7') -> 7;
impl_id('user.T8') -> 8;
impl_id(_) -> 0.

impl_1(_) -> 1.
impl_2(_) -> 2.
impl_3(_) -> 3.
impl_4(_) -> 4.
impl_5(_) -> 5.
impl_6(_) -> 6.
impl_7(_) -> 7.
impl_8(_) -> 8.

bench_wm_b(D) -> L = g(D, insts_b), R = g(D, refs_b), loop_wm_b(?N_REC, L, L, R, R, 0).
loop_wm_b(0, _, _, _, _, _) -> ok;
loop_wm_b(N, L, [X | R], Rs, [Ref | RR], Acc) ->
    V = maps:put(?META_KEY, meta(), X),
    loop_wm_b(N - 1, L, R, Rs, RR, Acc + b2i(V =:= Ref));
loop_wm_b(N, L, [], Rs, RR, Acc) -> loop_wm_b(N, L, L, Rs, RR, Acc);
loop_wm_b(N, L, R, Rs, [], Acc) -> loop_wm_b(N, L, R, Rs, Rs, Acc).

bench_off_b(D) -> L = g(D, insts_b), R = g(D, refs_b), loop_off_b(?N_REC, L, L, R, R, 0).
loop_off_b(0, _, _, _, _, _) -> ok;
loop_off_b(N, L, [X | R], Rs, [Ref | RR], Acc) -> loop_off_b(N - 1, L, R, Rs, RR, Acc + b2i(X =:= Ref));
loop_off_b(N, L, [], Rs, RR, Acc) -> loop_off_b(N, L, L, Rs, RR, Acc);
loop_off_b(N, L, R, Rs, [], Acc) -> loop_off_b(N, L, R, Rs, Rs, Acc).

bench_eq_b(D) -> L = g(D, insts_b), L2 = g(D, insts_b2), loop_eq_b(?N_REC, L, L, L2, L2, 0).
loop_eq_b(0, _, _, _, _, _) -> ok;
loop_eq_b(N, L, [X | R], Ys0, [Y | Ys], Acc) -> loop_eq_b(N - 1, L, R, Ys0, Ys, Acc + b2i(X =:= Y));
loop_eq_b(N, L, [], Ys0, _Ys, Acc) -> loop_eq_b(N, L, L, Ys0, Ys0, Acc).

bench_neq_b(D) -> L = g(D, insts_b), L2 = g(D, bd2), loop_neq_b(?N_REC, L, L, L2, L2, 0).
loop_neq_b(0, _, _, _, _, _) -> ok;
loop_neq_b(N, L, [X | R], Ys0, [Y | Ys], Acc) -> loop_neq_b(N - 1, L, R, Ys0, Ys, Acc + b2i(X =:= Y));
loop_neq_b(N, L, [], Ys0, _Ys, Acc) -> loop_neq_b(N, L, L, Ys0, Ys0, Acc).

%% =====================================================================
%% §1 主表
%% =====================================================================
sec_record(D) ->
    io:format("~n~s~n", [?BAR]),
    io:format("§1 record/deftype 实例(5 字段, 8 种类型),每格 ~p 次迭代~n", [?N_REC]),
    io:format("  A  = {Tag, Meta, FieldsTuple}  字段为位置元组,访问器 element/2~n"),
    io:format("  A' = {Tag, Meta, FieldsMap}    字段本身是 map~n"),
    io:format("  B  = #{?TYPE => Tag, f1..f5}    clojerl 1.0 实际表示~n"),
    io:format("~s~n", [?BAR]),
    hdr(),
    _ = report("(harness) 遍历基线", fun() -> bench_base(D) end, ?N_REC),
    Cs = [report("A  construct", fun() -> bench_con_a(D) end, ?N_REC),
          report("A' construct", fun() -> bench_con_amap(D) end, ?N_REC),
          report("B  construct", fun() -> bench_con_b(D) end, ?N_REC),
          report("A  get(f2)", fun() -> bench_get_a(D) end, ?N_REC),
          report("A' get(f2)", fun() -> bench_get_amap(D) end, ?N_REC),
          report("B  get(f2)", fun() -> bench_get_b(D) end, ?N_REC),
          report("A  tag", fun() -> bench_tag_a(D) end, ?N_REC),
          report("A' tag", fun() -> bench_tag_amap(D) end, ?N_REC),
          report("B  tag", fun() -> bench_tag_b(D) end, ?N_REC),
          report("A  dispatch(tag->impl)", fun() -> bench_disp_a(D) end, ?N_REC),
          report("A' dispatch(tag->impl)", fun() -> bench_disp_amap(D) end, ?N_REC),
          report("B  dispatch(tag->impl)", fun() -> bench_disp_b(D) end, ?N_REC),
          report("A  dispatch+impl call", fun() -> bench_dcall_a(D) end, ?N_REC),
          report("A' dispatch+impl call", fun() -> bench_dcall_amap(D) end, ?N_REC),
          report("B  dispatch+impl call", fun() -> bench_dcall_b(D) end, ?N_REC),
          report("A  with-meta", fun() -> bench_wm_a(D) end, ?N_REC),
          report("A' with-meta", fun() -> bench_wm_amap(D) end, ?N_REC),
          report("B  with-meta", fun() -> bench_wm_b(D) end, ?N_REC),
          report("A  [基准] 只消费", fun() -> bench_off_a(D) end, ?N_REC),
          report("A' [基准] 只消费", fun() -> bench_off_amap(D) end, ?N_REC),
          report("B  [基准] 只消费", fun() -> bench_off_b(D) end, ?N_REC),
          report("A  = (same)", fun() -> bench_eq_a(D) end, ?N_REC),
          report("A' = (same)", fun() -> bench_eq_amap(D) end, ?N_REC),
          report("B  = (same)", fun() -> bench_eq_b(D) end, ?N_REC),
          report("A  = (diff)", fun() -> bench_neq_a(D) end, ?N_REC),
          report("A' = (diff)", fun() -> bench_neq_amap(D) end, ?N_REC),
          report("B  = (diff)", fun() -> bench_neq_b(D) end, ?N_REC)],
    io:format("~nchecksums: ~p~n", [Cs]),
    io:format("~n净值(该行 − 同一表示的 [基准] 行):~n"),
    hdr(),
    M = fun(F) -> med(element(1, measure(fun() -> F() end))) end,
    Con = [M(fun() -> bench_con_a(D) end), M(fun() -> bench_con_amap(D) end), M(fun() -> bench_con_b(D) end)],
    Wms = [M(fun() -> bench_wm_a(D) end), M(fun() -> bench_wm_amap(D) end), M(fun() -> bench_wm_b(D) end)],
    Off = [M(fun() -> bench_off_a(D) end), M(fun() -> bench_off_amap(D) end), M(fun() -> bench_off_b(D) end)],
    Labels = ["A  ", "A' ", "B  "],
    lists:foreach(fun(I) ->
        L = lists:nth(I, Labels),
        netrow(L ++ "  construct 净值", lists:nth(I, Con), lists:nth(I, Off)),
        netrow(L ++ "  with-meta 净值", lists:nth(I, Wms), lists:nth(I, Off))
    end, [1, 2, 3]),
    ok.

%% =====================================================================
%% §2 §1.1 总表代表类型:vector / hashmap / hashset
%%     construct 只计外层包装(内层 trie/map 三种表示共用)
%% =====================================================================
bench_vcon_a(D) -> L = g(D, vec8), R = g(D, vrefs_a), loop_vcon_a(?N_COLL, L, L, R, R, 0).
loop_vcon_a(0, _, _, _, _, _) -> ok;
loop_vcon_a(N, L, [T | R], Rs, [Ref | RR], Acc) ->
    V = {vector, nil, T},
    loop_vcon_a(N - 1, L, R, Rs, RR, Acc + b2i(V =:= Ref));
loop_vcon_a(N, L, [], Rs, RR, Acc) -> loop_vcon_a(N, L, L, Rs, RR, Acc);
loop_vcon_a(N, L, R, Rs, [], Acc) -> loop_vcon_a(N, L, R, Rs, Rs, Acc).

bench_vcon_b(D) -> L = g(D, vec8), R = g(D, vrefs_b), loop_vcon_b(?N_COLL, L, L, R, R, 0).
loop_vcon_b(0, _, _, _, _, _) -> ok;
loop_vcon_b(N, L, [T | R], Rs, [Ref | RR], Acc) ->
    V = #{?TYPE_KEY => 'clojerl.Vector', array => T, ?META_KEY => nil},
    loop_vcon_b(N - 1, L, R, Rs, RR, Acc + b2i(V =:= Ref));
loop_vcon_b(N, L, [], Rs, RR, Acc) -> loop_vcon_b(N, L, L, Rs, RR, Acc);
loop_vcon_b(N, L, R, Rs, [], Acc) -> loop_vcon_b(N, L, R, Rs, Rs, Acc).

bench_voff_a(D) -> L = g(D, vecs_a), R = g(D, vrefs_a), loop_voff_a(?N_COLL, L, L, R, R, 0).
loop_voff_a(0, _, _, _, _, _) -> ok;
loop_voff_a(N, L, [X | R], Rs, [Ref | RR], Acc) -> loop_voff_a(N - 1, L, R, Rs, RR, Acc + b2i(X =:= Ref));
loop_voff_a(N, L, [], Rs, RR, Acc) -> loop_voff_a(N, L, L, Rs, RR, Acc);
loop_voff_a(N, L, R, Rs, [], Acc) -> loop_voff_a(N, L, R, Rs, Rs, Acc).

bench_voff_b(D) -> L = g(D, vecs_b), R = g(D, vrefs_b), loop_voff_b(?N_COLL, L, L, R, R, 0).
loop_voff_b(0, _, _, _, _, _) -> ok;
loop_voff_b(N, L, [X | R], Rs, [Ref | RR], Acc) -> loop_voff_b(N - 1, L, R, Rs, RR, Acc + b2i(X =:= Ref));
loop_voff_b(N, L, [], Rs, RR, Acc) -> loop_voff_b(N, L, L, Rs, RR, Acc);
loop_voff_b(N, L, R, Rs, [], Acc) -> loop_voff_b(N, L, R, Rs, Rs, Acc).

bench_vget_a(D) -> L = g(D, vecs_a), loop_vget_a(?N_COLL, L, L, 0).
loop_vget_a(0, _, _, _) -> ok;
loop_vget_a(N, L, [X | R], _) -> loop_vget_a(N - 1, L, R, element(4, element(3, X)));
loop_vget_a(N, L, [], _) -> loop_vget_a(N, L, L, 0).

bench_vget_b(D) -> L = g(D, vecs_b), loop_vget_b(?N_COLL, L, L, 0).
loop_vget_b(0, _, _, _) -> ok;
loop_vget_b(N, L, [X | R], _) -> loop_vget_b(N - 1, L, R, element(4, maps:get(array, X)));
loop_vget_b(N, L, [], _) -> loop_vget_b(N, L, L, 0).

bench_mcon_a(D) -> L = g(D, map5), R = g(D, mrefs_a), loop_mcon_a(?N_COLL, L, L, R, R, 0).
loop_mcon_a(0, _, _, _, _, _) -> ok;
loop_mcon_a(N, L, [M | R], Rs, [Ref | RR], Acc) ->
    V = {map, nil, M},
    loop_mcon_a(N - 1, L, R, Rs, RR, Acc + b2i(V =:= Ref));
loop_mcon_a(N, L, [], Rs, RR, Acc) -> loop_mcon_a(N, L, L, Rs, RR, Acc);
loop_mcon_a(N, L, R, Rs, [], Acc) -> loop_mcon_a(N, L, R, Rs, Rs, Acc).

bench_mcon_b(D) -> L = g(D, map5), R = g(D, mrefs_b), loop_mcon_b(?N_COLL, L, L, R, R, 0).
loop_mcon_b(0, _, _, _, _, _) -> ok;
loop_mcon_b(N, L, [M | R], Rs, [Ref | RR], Acc) ->
    V = #{?TYPE_KEY => 'clojerl.Map', map => M, count => 5, ?META_KEY => nil},
    loop_mcon_b(N - 1, L, R, Rs, RR, Acc + b2i(V =:= Ref));
loop_mcon_b(N, L, [], Rs, RR, Acc) -> loop_mcon_b(N, L, L, Rs, RR, Acc);
loop_mcon_b(N, L, R, Rs, [], Acc) -> loop_mcon_b(N, L, R, Rs, Rs, Acc).

bench_moff_a(D) -> L = g(D, maps_a), R = g(D, mrefs_a), loop_moff_a(?N_COLL, L, L, R, R, 0).
loop_moff_a(0, _, _, _, _, _) -> ok;
loop_moff_a(N, L, [X | R], Rs, [Ref | RR], Acc) -> loop_moff_a(N - 1, L, R, Rs, RR, Acc + b2i(X =:= Ref));
loop_moff_a(N, L, [], Rs, RR, Acc) -> loop_moff_a(N, L, L, Rs, RR, Acc);
loop_moff_a(N, L, R, Rs, [], Acc) -> loop_moff_a(N, L, R, Rs, Rs, Acc).

bench_moff_b(D) -> L = g(D, maps_b), R = g(D, mrefs_b), loop_moff_b(?N_COLL, L, L, R, R, 0).
loop_moff_b(0, _, _, _, _, _) -> ok;
loop_moff_b(N, L, [X | R], Rs, [Ref | RR], Acc) -> loop_moff_b(N - 1, L, R, Rs, RR, Acc + b2i(X =:= Ref));
loop_moff_b(N, L, [], Rs, RR, Acc) -> loop_moff_b(N, L, L, Rs, RR, Acc);
loop_moff_b(N, L, R, Rs, [], Acc) -> loop_moff_b(N, L, R, Rs, Rs, Acc).

bench_mget_a(D) -> L = g(D, maps_a), loop_mget_a(?N_COLL, L, L, 0).
loop_mget_a(0, _, _, _) -> ok;
loop_mget_a(N, L, [X | R], _) -> loop_mget_a(N - 1, L, R, maps:get(k3, element(3, X)));
loop_mget_a(N, L, [], _) -> loop_mget_a(N, L, L, 0).

bench_mget_b(D) -> L = g(D, maps_b), loop_mget_b(?N_COLL, L, L, 0).
loop_mget_b(0, _, _, _) -> ok;
loop_mget_b(N, L, [X | R], _) -> loop_mget_b(N - 1, L, R, maps:get(k3, maps:get(map, X)));
loop_mget_b(N, L, [], _) -> loop_mget_b(N, L, L, 0).

bench_scon_a(D) -> L = g(D, map5), R = g(D, srefs_a), loop_scon_a(?N_COLL, L, L, R, R, 0).
loop_scon_a(0, _, _, _, _, _) -> ok;
loop_scon_a(N, L, [M | R], Rs, [Ref | RR], Acc) ->
    V = {set, nil, M},
    loop_scon_a(N - 1, L, R, Rs, RR, Acc + b2i(V =:= Ref));
loop_scon_a(N, L, [], Rs, RR, Acc) -> loop_scon_a(N, L, L, Rs, RR, Acc);
loop_scon_a(N, L, R, Rs, [], Acc) -> loop_scon_a(N, L, R, Rs, Rs, Acc).

bench_scon_b(D) -> L = g(D, map5), R = g(D, srefs_b), loop_scon_b(?N_COLL, L, L, R, R, 0).
loop_scon_b(0, _, _, _, _, _) -> ok;
loop_scon_b(N, L, [M | R], Rs, [Ref | RR], Acc) ->
    V = #{?TYPE_KEY => 'clojerl.Set', map => M, count => 5, ?META_KEY => nil},
    loop_scon_b(N - 1, L, R, Rs, RR, Acc + b2i(V =:= Ref));
loop_scon_b(N, L, [], Rs, RR, Acc) -> loop_scon_b(N, L, L, Rs, RR, Acc);
loop_scon_b(N, L, R, Rs, [], Acc) -> loop_scon_b(N, L, R, Rs, Rs, Acc).

bench_soff_a(D) -> L = g(D, sets_a), R = g(D, srefs_a), loop_soff_a(?N_COLL, L, L, R, R, 0).
loop_soff_a(0, _, _, _, _, _) -> ok;
loop_soff_a(N, L, [X | R], Rs, [Ref | RR], Acc) -> loop_soff_a(N - 1, L, R, Rs, RR, Acc + b2i(X =:= Ref));
loop_soff_a(N, L, [], Rs, RR, Acc) -> loop_soff_a(N, L, L, Rs, RR, Acc);
loop_soff_a(N, L, R, Rs, [], Acc) -> loop_soff_a(N, L, R, Rs, Rs, Acc).

bench_soff_b(D) -> L = g(D, sets_b), R = g(D, srefs_b), loop_soff_b(?N_COLL, L, L, R, R, 0).
loop_soff_b(0, _, _, _, _, _) -> ok;
loop_soff_b(N, L, [X | R], Rs, [Ref | RR], Acc) -> loop_soff_b(N - 1, L, R, Rs, RR, Acc + b2i(X =:= Ref));
loop_soff_b(N, L, [], Rs, RR, Acc) -> loop_soff_b(N, L, L, Rs, RR, Acc);
loop_soff_b(N, L, R, Rs, [], Acc) -> loop_soff_b(N, L, R, Rs, Rs, Acc).

bench_shas_a(D) -> L = g(D, sets_a), loop_shas_a(?N_COLL, L, L, 0).
loop_shas_a(0, _, _, _) -> ok;
loop_shas_a(N, L, [X | R], _) -> loop_shas_a(N - 1, L, R, b2i(maps:is_key(k3, element(3, X))));
loop_shas_a(N, L, [], _) -> loop_shas_a(N, L, L, 0).

bench_shas_b(D) -> L = g(D, sets_b), loop_shas_b(?N_COLL, L, L, 0).
loop_shas_b(0, _, _, _) -> ok;
loop_shas_b(N, L, [X | R], _) -> loop_shas_b(N - 1, L, R, b2i(maps:is_key(k3, maps:get(map, X))));
loop_shas_b(N, L, [], _) -> loop_shas_b(N, L, L, 0).

sec_collections(D) ->
    io:format("~n~s~n", [?BAR]),
    io:format("§1.1 总表代表类型 vector / hashmap / hashset,每格 ~p 次迭代~n", [?N_COLL]),
    io:format("  construct 只计外层包装;内层 trie/map 三种表示共用~n"),
    io:format("~s~n", [?BAR]),
    hdr(),
    Cs = [report("A  vector construct", fun() -> bench_vcon_a(D) end, ?N_COLL),
          report("B  vector construct", fun() -> bench_vcon_b(D) end, ?N_COLL),
          report("A' [基准] 只消费", fun() -> bench_voff_a(D) end, ?N_COLL),
          report("B  [基准] 只消费", fun() -> bench_voff_b(D) end, ?N_COLL),
          report("A  vector nth(4)", fun() -> bench_vget_a(D) end, ?N_COLL),
          report("B  vector nth(4)", fun() -> bench_vget_b(D) end, ?N_COLL),
          report("A  map construct", fun() -> bench_mcon_a(D) end, ?N_COLL),
          report("B  map construct", fun() -> bench_mcon_b(D) end, ?N_COLL),
          report("A' [基准] 只消费", fun() -> bench_moff_a(D) end, ?N_COLL),
          report("B  [基准] 只消费", fun() -> bench_moff_b(D) end, ?N_COLL),
          report("A  map get(k3)", fun() -> bench_mget_a(D) end, ?N_COLL),
          report("B  map get(k3)", fun() -> bench_mget_b(D) end, ?N_COLL),
          report("A  set construct", fun() -> bench_scon_a(D) end, ?N_COLL),
          report("B  set construct", fun() -> bench_scon_b(D) end, ?N_COLL),
          report("A' [基准] 只消费", fun() -> bench_soff_a(D) end, ?N_COLL),
          report("B  [基准] 只消费", fun() -> bench_soff_b(D) end, ?N_COLL),
          report("A  set contains(k3)", fun() -> bench_shas_a(D) end, ?N_COLL),
          report("B  set contains(k3)", fun() -> bench_shas_b(D) end, ?N_COLL)],
    io:format("~nchecksums: ~p~n", [Cs]).

%% =====================================================================
%% §3 DCE 校验:证明"构造结果被丢弃"会被 BEAM 优化掉,
%%    所以主表必须用 =:= Ref 消费
%% =====================================================================
bench_dce_none(D) -> L = g(D, inputs), loop_dce_none(?N_REC, L, L, 0).
loop_dce_none(0, _, _, _) -> ok;
loop_dce_none(N, L, [{_, A, _, _, _, _} | R], _) -> loop_dce_none(N - 1, L, R, A);
loop_dce_none(N, L, [], _) -> loop_dce_none(N, L, L, 0).

bench_dce_a(D) -> L = g(D, inputs), R = g(D, refs_a), loop_dce_a(?N_REC, L, L, R, R, 0).
loop_dce_a(0, _, _, _, _, _) -> ok;
loop_dce_a(N, L, [{T, A, B, C, D1, E} | R], Rs, [_Ref | RR], Acc) ->
    _V = {T, nil, {A, B, C, D1, E}},
    loop_dce_a(N - 1, L, R, Rs, RR, Acc + A);
loop_dce_a(N, L, [], Rs, RR, Acc) -> loop_dce_a(N, L, L, Rs, RR, Acc);
loop_dce_a(N, L, R, Rs, [], Acc) -> loop_dce_a(N, L, R, Rs, Rs, Acc).

bench_dce_b(D) -> L = g(D, inputs), R = g(D, refs_b), loop_dce_b(?N_REC, L, L, R, R, 0).
loop_dce_b(0, _, _, _, _, _) -> ok;
loop_dce_b(N, L, [{T, A, B, C, D1, E} | R], Rs, [_Ref | RR], Acc) ->
    _V = #{?TYPE_KEY => T, f1 => A, f2 => B, f3 => C, f4 => D1, f5 => E},
    loop_dce_b(N - 1, L, R, Rs, RR, Acc + A);
loop_dce_b(N, L, [], Rs, RR, Acc) -> loop_dce_b(N, L, L, Rs, RR, Acc);
loop_dce_b(N, L, R, Rs, [], Acc) -> loop_dce_b(N, L, R, Rs, Rs, Acc).

sec_dce(D) ->
    io:format("~n~s~n", [?BAR]),
    io:format("DCE 校验:证明丢弃结果会被优化掉(所以主表用 =:= Ref 消费)~n"),
    io:format("~s~n", [?BAR]),
    hdr(),
    Cs = [report("只遍历(无构造)", fun() -> bench_dce_none(D) end, ?N_REC),
          report("A 构造 + 丢弃", fun() -> bench_dce_a(D) end, ?N_REC),
          report("B 构造 + 丢弃", fun() -> bench_dce_b(D) end, ?N_REC),
          report("A 构造 + =:= Ref(主表)", fun() -> bench_con_a(D) end, ?N_REC),
          report("B 构造 + =:= Ref(主表)", fun() -> bench_con_b(D) end, ?N_REC)],
    io:format("~nchecksums: ~p~n", [Cs]).

%% =====================================================================
%% §4 §1.2 keyword atom 策略原型
%% =====================================================================
kw_hit_bins() ->
    [<<"user">>, <<"name">>, <<"some.existing.keyword">>, <<"line">>,
     <<"col">>, <<"file">>, <<"meta">>, <<"foo">>, <<"bar">>, <<"baz">>,
     <<"qux">>, <<"a.b.c">>, <<"x-y">>, <<"z">>, <<"w">>].

kw_miss_bins() ->
    [<<"dyn.never.seen.1">>, <<"dyn.never.seen.2">>, <<"dyn.never.seen.3">>,
     <<"dyn.never.seen.4">>, <<"dyn.never.seen.5">>, <<"dyn.never.seen.6">>,
     <<"dyn.never.seen.7">>, <<"dyn.never.seen.8">>].

%% 这些 atom 一定存在(spike 里用 binary_to_atom 建出来,污染可控)
kw_hit_pairs()  -> [{B, binary_to_atom(B, utf8)} || B <- kw_hit_bins()].
kw_miss_pairs() -> [{B, B} || B <- kw_miss_bins()].

%% §1.2 的默认策略:binary_to_existing_atom,未命中回退 {kw_dyn, Bin}
kw_new(Bin) ->
    try binary_to_existing_atom(Bin, utf8)
    catch error:badarg -> {kw_dyn, Bin}
    end.

kw_norm(A) when is_atom(A) -> A;
kw_norm({kw_dyn, Bin})       -> kw_new(Bin).

kw_eq(K1, K2) -> kw_norm(K1) =:= kw_norm(K2).

bench_kw_hit() -> L = kw_hit_pairs(), loop_kw_hit(?N_KW, L, L, 0).
loop_kw_hit(0, _, _, _) -> ok;
loop_kw_hit(N, L, [{Bin, Atom} | R], _) ->
    loop_kw_hit(N - 1, L, R, b2i(binary_to_existing_atom(Bin, utf8) =:= Atom));
loop_kw_hit(N, L, [], _) -> loop_kw_hit(N, L, L, 0).

bench_kw_miss() -> L = kw_miss_pairs(), loop_kw_miss(?N_KW, L, L, 0).
loop_kw_miss(0, _, _, _) -> ok;
loop_kw_miss(N, L, [{Bin, _} | R], _) ->
    loop_kw_miss(N - 1, L, R, b2i(kw_new(Bin) =:= {kw_dyn, Bin}));
loop_kw_miss(N, L, [], _) -> loop_kw_miss(N, L, L, 0).

bench_kw_atom() -> L = kw_hit_bins(), loop_kw_atom(?N_KW, L, L, 0).
loop_kw_atom(0, _, _, _) -> ok;
loop_kw_atom(N, L, [Bin | R], _) ->
    loop_kw_atom(N - 1, L, R, b2i(is_atom(binary_to_atom(Bin, utf8))));
loop_kw_atom(N, L, [], _) -> loop_kw_atom(N, L, L, 0).

kw_eq_atom_pairs()  -> [{A, A} || {_, A} <- kw_hit_pairs()].
kw_eq_mixed_pairs() -> [{A, {kw_dyn, B}} || {B, A} <- kw_hit_pairs()].
kw_eq_dyn_pairs()   -> [{kw_dyn(B), kw_dyn(B)} || B <- kw_hit_bins()].

kw_dyn({kw_dyn, B}) -> {kw_dyn, B};
kw_dyn(B)          -> {kw_dyn, B}.

bench_kw_eq_atom()  -> L = kw_eq_atom_pairs(),  loop_kw_eq_atom(?N_KW, L, L, 0).
loop_kw_eq_atom(0, _, _, _) -> ok;
loop_kw_eq_atom(N, L, [{A, B} | R], _) -> loop_kw_eq_atom(N - 1, L, R, b2i(kw_eq(A, B)));
loop_kw_eq_atom(N, L, [], _) -> loop_kw_eq_atom(N, L, L, 0).

bench_kw_eq_mixed() -> L = kw_eq_mixed_pairs(), loop_kw_eq_mixed(?N_KW, L, L, 0).
loop_kw_eq_mixed(0, _, _, _) -> ok;
loop_kw_eq_mixed(N, L, [{A, B} | R], _) -> loop_kw_eq_mixed(N - 1, L, R, b2i(kw_eq(A, B)));
loop_kw_eq_mixed(N, L, [], _) -> loop_kw_eq_mixed(N, L, L, 0).

bench_kw_eq_dyn()   -> L = kw_eq_dyn_pairs(),   loop_kw_eq_dyn(?N_KW, L, L, 0).
loop_kw_eq_dyn(0, _, _, _) -> ok;
loop_kw_eq_dyn(N, L, [{A, B} | R], _) -> loop_kw_eq_dyn(N - 1, L, R, b2i(kw_eq(A, B)));
loop_kw_eq_dyn(N, L, [], _) -> loop_kw_eq_dyn(N, L, L, 0).

kw_name(K) ->
    case kw_new(K) of
        A when is_atom(A) -> atom_to_binary(A, utf8);
        {kw_dyn, B}       -> B
    end.

bench_kw_name() -> L = kw_hit_bins(), loop_kw_name(?N_KW, L, L, 0).
loop_kw_name(0, _, _, _) -> ok;
loop_kw_name(N, L, [Bin | R], _) -> loop_kw_name(N - 1, L, R, erlang:size(kw_name(Bin)));
loop_kw_name(N, L, [], _) -> loop_kw_name(N, L, L, 0).

sec_keyword() ->
    io:format("~n~s~n", [?BAR]),
    io:format("§1.2 keyword atom 策略原型,每格 ~p 次迭代~n", [?N_KW]),
    io:format("  kw_new(Bin) = try binary_to_existing_atom(Bin) catch badarg -> {kw_dyn, Bin}~n"),
    io:format("  kw_eq/2     = 两边先 kw_norm 归一再 =:=~n"),
    io:format("~s~n", [?BAR]),
    hdr(),
    Cs = [report("hit  b2ea 命中(已有 atom)", fun bench_kw_hit/0, ?N_KW),
          report("miss b2ea 异常+{kw_dyn,Bin}", fun bench_kw_miss/0, ?N_KW),
          report("ctl  binary_to_atom(*allow*)", fun bench_kw_atom/0, ?N_KW),
          report("=    atom vs atom", fun bench_kw_eq_atom/0, ?N_KW),
          report("=    atom vs {kw_dyn,Bin}", fun bench_kw_eq_mixed/0, ?N_KW),
          report("=    {kw_dyn} vs {kw_dyn}", fun bench_kw_eq_dyn/0, ?N_KW),
          report("name (pr-str 面最小演示)", fun bench_kw_name/0, ?N_KW)],
    io:format("~nchecksums: ~p~n", [Cs]),
    io:format("~nkw_new(<<\"user\">>)            = ~p~n", [kw_new(<<"user">>)]),
    io:format("kw_new(<<\"never.seen.x.y\">>)   = ~p~n", [kw_new(<<"never.seen.x.y">>)]),
    io:format("kw_eq('user', {kw_dyn,<<\"user\">>})        = ~p~n",
              [kw_eq('user', {kw_dyn, <<"user">>})]),
    io:format("kw_eq('user', {kw_dyn,<<\"other\">>})       = ~p~n",
              [kw_eq('user', {kw_dyn, <<"other">>})]),
    io:format("kw_eq({kw_dyn,<<\"a\">>},{kw_dyn,<<\"a\">>}) = ~p~n",
              [kw_eq({kw_dyn, <<"a">>}, {kw_dyn, <<"a">>})]),
    UserKw = kw_new(<<"user">>),
    io:format("map key 互通性:{kw_dyn,Bin} 与 atom 形态不是同一个 key -> ~p~n",
              [maps:is_key(UserKw, #{UserKw => 1})]).

%% =====================================================================
%% §5 汇总
%% =====================================================================
sec_summary(D) ->
    io:format("~n~s~n", [?BAR]),
    io:format("汇总(A 相对 B 的加速比,median)~n"),
    io:format("~s~n", [?BAR]),
    M = fun(F) -> med(element(1, measure(fun() -> F() end))) / ?N_REC end,
    Show = fun(Label, Bf, Af) ->
        B = M(Bf), A = M(Af),
        io:format("~-24ts B=~7.2f ns   A=~7.2f ns   ~5.2fx~n", [Label, B, A, B / A])
    end,
    Show("dispatch(tag->impl)", fun() -> bench_disp_b(D) end, fun() -> bench_disp_a(D) end),
    Show("dispatch+impl call", fun() -> bench_dcall_b(D) end, fun() -> bench_dcall_a(D) end),
    Show("tag 取标签", fun() -> bench_tag_b(D) end, fun() -> bench_tag_a(D) end),
    Show("get(f2)", fun() -> bench_get_b(D) end, fun() -> bench_get_a(D) end),
    Show("= (same)", fun() -> bench_eq_b(D) end, fun() -> bench_eq_a(D) end),
    Show("= (diff)", fun() -> bench_neq_b(D) end, fun() -> bench_neq_a(D) end),
    OffB = M(fun() -> bench_off_b(D) end),
    OffA = M(fun() -> bench_off_a(D) end),
    Wmb = M(fun() -> bench_wm_b(D) end),
    Wma = M(fun() -> bench_wm_a(D) end),
    Conb = M(fun() -> bench_con_b(D) end),
    Cona = M(fun() -> bench_con_a(D) end),
    io:format("~-24ts B=~7.2f ns   A=~7.2f ns   ~5.2fx   (净值)~n",
              ["with-meta", Wmb - OffB, Wma - OffA, (Wmb - OffB) / (Wma - OffA)]),
    io:format("~-24ts B=~7.2f ns   A=~7.2f ns   ~5.2fx   (净值)~n",
              ["construct", Conb - OffB, Cona - OffA, (Conb - OffB) / (Cona - OffA)]),
    ok.