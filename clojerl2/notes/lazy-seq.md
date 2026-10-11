# 惰性序列实现与吞吐基线(clojerl2-019)

实现:`src/erl/clj2_lazy.erl`(记忆单元、实现、delay),`clj2_coll`(seq 原语认识惰性值),
`priv/clj2/core/00-kernel.clj`(惰性的 map/filter/concat/take/drop/range/iterate/repeat/cycle/...)。
设计:[designs/03](../../designs/03-runtime-model.md) §5.3、§6。

## 表示

- `lazy-seq` = `{lazy_seq, Meta, {Key, Thunk}}`;实现结果是 nil 或 cons 单元 `[First | Rest]`,Rest 可以仍是惰性的(Erlang 非正规列表),所以逐元素实现,`first`/`rest` 仍是 `hd`/`tl`。
- 记忆单元按 Key 存在 pdict(默认)或 ETS(开关);thunk 返回另一个 lazy-seq 时迭代实现(常量栈)。
- 记忆单元有上限(默认 100000),超过即清空——见 known-divergences `:lazy-seq/bounded-memo`。

## 吞吐基线(OTP 28,本机,best effort,`escript` + `-mode(compile)`)

| 场景 | pdict | ets | ets/pdict |
|---|---|---|---|
| `(reduce + (take 10000 (filter even? (map inc (range)))))` | 34.2 ms | 92.5 ms | 2.7× |
| `(reduce + (range 100000))` | 54.8 ms(≈550 ns/元素) | 120.3 ms | 2.2× |
| 惰性 fib,`nth 5000` | 3.5 ms | 7.5 ms | 2.1× |
| 同一个 10k 惰性序列走两遍 | 14.8 ms | 33.2 ms | 2.2× |

每元素的固定成本:分配 ref + 闭包、记忆单元两次 pdict 写、`+` 作为多 arity var 值经 `clj2_rt:invoke` 慢路径。后续优化方向:chunked seq(03 §6,v1 不做)、`:inline` 内联算术、`clj2_fn` 记录的调用快路径。

## 与 clojerl 1.0 的对比:本机未能完成

任务验收要求"与 clojerl 1.0 同级代码吞吐差不超 003 报告固化的阈值"。两点如实记录:

1. **003 报告没有固化这样的阈值**(它比较的是 pdict 与 ETS,结论是默认 pdict)。
2. **clojerl 1.0 在本机 OTP 28 上编不完整**:`rebar3 clojerl compile` 在 `clojure/instant.clje:46`(正则字面量作为 var 初值,"Init value ... is not a literal")处失败,产物 `clojure.core` 缺 `range/0` 等函数,无法运行同级代码。

因此对比留作开放项(需要 OTP 26 环境或修好 clojerl 1.0 的构建);上表作为 clojerl2 自己的基线入库。
