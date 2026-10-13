# clojerl2-043 clojure-test-suite 清理

状态:已完成(2026-10-13)
里程碑:M6(一致性收尾)
依赖:clojerl2-042

## 目标

corpus 只剩环境问题之后,清理 clojure-test-suite(`make cts`)里不属于已登记差异的失败。

## 工作内容

- [x] map 键与 set 元素的元数据不参与比较(`{^:foo [:a 1] 17}` 含键 `[:a 1]`):集合类的键存入、查找时去掉顶层元数据(`clj2_coll:nk/1`);`:collections/exact-keys` 补充说明(取回的键不再带元数据)
- [x] 集合字面量的元数据经过宏边界保留(`(let [x 1] (meta ^:foo [x]))`,`from_value` 与值形态的集合字面量)
- [x] def 类形式(`def`/`defn`/`defmacro`/`defonce`/`defmulti` ……)名字上的元数据经过宏保留(`(when-var-exists ... (def ^:dynamic *x* ..))`):符号不能带元数据,名字以 `{clj2_msym, Sym, Meta}` 穿过宏,解析器读回;`read-string` 的数据不受影响
- [x] `case` 的向量常量也匹配相等的列表,列表常量也匹配相等的向量
- [x] `(symbol :kw)`、`(symbol #'v)`;多参数 `interleave`;`nth` 作用于 re-matcher(上次匹配的分组);数组上的 `get` 与 `contains?`;`contains?` 对列表、数字、关键字等抛 IllegalArgumentException(nil 为 false,向量的非整数键为 false);`get-in` 用哨兵值而不是 `contains?`
- [x] `some-fn` 没有匹配时返回 false,零参抛异常;`cycle`/`shuffle`/`subs`/`(pop {})`/`when-let` 多绑定的参数检查按 JVM 抛异常;`descendants` 作用于类抛 UnsupportedOperationException
- [x] `hash-set` 接受带惰性尾部的列表

## 验收标准

- `make test`、`make certify`、`make cts` 全绿;回归测试 `cts_sweep_test`

## 结论

- 本机门控:eunit 666 全过;CTS 5743 → **5816** 通过(失败 233 → 187、错误 388 → 371,基线已重写,93 个命名空间有登记的失败);corpus 4318/4841(两条"取回的键与放进去的键 identical?"改挂 `:collections/exact-keys`)。
- 剩余 CTS 失败约 550 条断言,其中约 430 条是 `:number/beam-semantics`(Inf/NaN、-0.0、long 溢出、BigInt 类、Ratio 运算),其余几乎都是 `:char/integer`(`(char? 0)`、`(int? 48)`、`(str \A)`)、`:seqs/class-model`(`(list? (seq [1 2 3]))`)、`:transients/wrapped` 与 `:collections/map-entry-vectors`。
