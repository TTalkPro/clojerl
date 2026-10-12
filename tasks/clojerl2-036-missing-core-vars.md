# clojerl2-036 补缺失的 clojure.core 函数

状态:已完成(2026-10-12)
里程碑:M6(一致性收尾)
依赖:clojerl2-033, clojerl2-035

## 目标

清掉 `:pending/missing-core-var`(114 条)。这一类是 corpus 按"未解析符号/元数不符"自动猜的,其中约一半其实不是缺函数,要改登记到真正的原因。

## 工作内容

- [x] 新增:`sorted-map?`/`sorted-set?`、`thread-bound?`、`get-thread-bindings`、`tagged-literal`/`tagged-literal?`、`reader-conditional`/`reader-conditional?`(按值相等、字段按键读、不是 map、打印为 `#tag form`/`#?(...)`)、`Inst` 协议与 `inst-ms`/`inst?`、`xml-seq`、`iterator-seq`、`test`、struct map(`defstruct`/`create-struct`/`struct-map`/`struct`/`accessor`)、proxy 的桩函数(`get-proxy-class`/`construct-proxy` 抛错,`init-proxy`/`update-proxy` 为 nil)、`print-dup`(抛错)、ClojureScript 的 `object?`/`undefined?`/`keyword-identical?`、`bytes`/`bytes?`
- [x] 补元数:`conj!` 变参、`partitionv-all` 的 transducer、`read-string` 的 opts(`:eof`)
- [x] 修:`loop` 的解构绑定按顺序求值(后面的初值能用前面解构出的名字);`vector-of` 按元素类型转换;`extend`/`extends?` 接受简单类名(`'String`)
- [x] 删掉 01-core 里几个过时的桩(`bytes`、`tagged-literal?`、`reader-conditional?`):clojerl2-032 之后同一单元重复的 def 是"后者覆盖",桩会盖掉真正的定义;查过 core 里已没有其他重名定义
- [x] 改登记(57 条):ref 相关 → `:refs/no-stm`;`bigdec` → `:pending/numbers`;`String.` 构造与字符集 → `:pending/host-types`;java.nio/文件/URL/reader mark → `:host/jvm-classes`;`print-method` 多方法 → `:pending/printer`;`read+string`、无参 `ns-aliases` → `:pending/runtime-eval`;局部 var 的 binding → `:pending/var-surface`;jolt 自己的 `__reader-features` 与故意不存在的符号 → `:pending/corpus-environment`

## 验收标准

- `:pending/missing-core-var` 清零;`make test`、`make certify`、`make cts` 全绿

## 结论

- 远端门控:eunit 651 全过;corpus 3853 → **3903**/4841,0 新失败、0 过期;CTS 与基线一致(5040 通过);`:pending/missing-core-var` 清零。
- CTS 剩下的失败基本都是数值:BigDecimal 约 300 个断言(`:pending/numbers`)、分数算术 96 个(`:number/no-ratio-arithmetic`)、Inf/NaN 约 250 个(`:number/beam-semantics`)。
