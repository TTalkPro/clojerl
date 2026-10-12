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

## 与 clojerl 1.0 的对比(2026-10-12)

任务验收要求"与 clojerl 1.0 同级代码吞吐差不超 003 报告固化的阈值"。**003 报告没有固化这样的阈值**(它比较的是 pdict 与 ETS,结论是默认 pdict),所以这里只记录实测。

clojerl 1.0 原本在 OTP 28 上编不过(`clojure/instant.clje:46`,正则字面量作 var 初值,"Init value ... is not a literal"):OTP 28 的 `re:compile` 结果含 reference,不能作模块常量。把 `erlang.util.Regex` 改为只存 pattern、用时按进程缓存编译之后(`src/erl/erlang/erlang.util.Regex.erl`),1.0 完整构建。

同一台机器,OTP 28,`bin/clojerl2 -e '(time ...)'` 对 `bin/clojerl -e '(time ...)'`,各三次(ms):

| 场景 | clojerl2(pdict) | clojerl 1.0 | 2 / 1.0 |
|---|---|---|---|
| `(reduce + (take 10000 (filter even? (map inc (range)))))` | 62 / 65 / 67 | 10.2 / 8.6 / 9.7 | ≈ 6.5× |
| `(reduce + (range 100000))` | 83 / 107 / 117 | 7.2 / 8.1 / 7.9 | ≈ 11× |
| 惰性 fib,`(nth (map first (iterate (fn [[a b]] [b (+ a b)]) [0 1])) 5000)` | 8.8 / 8.3 / 8.3 | 7.9 / 10.1 / 9.6 | ≈ 0.9× |
| 同一个 10k 惰性序列走两遍 | 20.1 / 18.7 / 16.6 | 14.9 / 14.4 / 16.8 | ≈ 1.2× |

差距集中在 range 和 map/filter 链:clojerl 1.0 的 `range` 是专门的类型,`reduce` 走它的内部归约;clojerl2 逐元素实现、每个元素一次记忆单元写入、`+` 经多 arity var 值的慢路径。惰性 fib 和两遍遍历(记忆化命中)持平。优化方向见上节。
