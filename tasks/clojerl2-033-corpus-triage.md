# clojerl2-033 corpus 分诊:334 条 `:pending/triage`

状态:已完成(2026-10-12)
里程碑:M6(一致性收尾)
依赖:clojerl2-022, clojerl2-032

## 目标

`:pending/triage` 是"能跑但结果和 JVM 不一致、原因未知"的大杂烩(334 条,corpus 最大的一类)。逐条看实际结果,归到具体原因下:已登记的有意差异、新登记的差异,或者一个说得清要做什么的 pending 类别,让后续修复有明确的范围和工作量。

## 工作内容

- [x] `tools/triage-dump.sh [cause]`:导出某个原因下全部失败条目(源码、期望、实际、原因),在远端跑约 3 分钟
- [x] 逐条阅读 334 条,按 suite + label 归类后改写 `:cause`
- [x] 新 pending 类别写进 `test/corpus-known-failures.edn` 的 `:pending`,每类有说明
- [x] 新的有意差异登记(known-divergences.edn、differences.md、佐证测试)

## 验收标准

- `:pending/triage` 为 0;`make certify` 0 新失败、0 过期、0 未登记原因
- 新差异各有佐证测试,`clj2_divergences_tests` 通过

## 结论

334 条全部归类,`:pending/triage` 清零(该原因保留,作为新失败的落脚处)。

**归到已有差异的 87 条**:`:number/beam-semantics` 14(类型提示不做转换、Inf/NaN)、`:collections/map-order` 11、`:host/jvm-classes` 10、`:symbol/no-metadata` 10、`:values/no-identity` 6、`:number/no-ratio-arithmetic` 5、`:char/integer` 4、`:transients/wrapped` 4、`:string/code-point-indexing` 3、`:seqs/class-model` 2、`:collections/exact-keys` 2。

**新登记的差异 15 条**(共 31 条差异):
- `:macros/defmacro-form` 6:defmacro 是编译器形式,`macroexpand-1` 原样返回;
- `:collections/map-entry-vectors` 5:map entry 就是二元向量;
- `:sorted/comparator-calls` 2:sorted 集合调用比较器次数不同;
- `:vars/forward-references` 2:同一文件里可以先用后定义。

**待修的 232 条,按新类别**(优先级见下):

| 类别 | 条目 | 内容 |
|---|---|---|
| `:pending/jvm-exceptions` | 53 | 抛了错,但不是 JVM 的异常类/信息(badarith/badarg/function_clause 和 clj2 错误项要映射到 CCE/NPE/IAE/IOOBE) |
| `:pending/arg-checks` | 49 | core fn 对参数的检查与 JVM 不同(该拒绝的接受了,或反之) |
| `:pending/var-surface` | 21 | Var 的 Java 方法;**命名空间加载期间经 var 对象使用本模块的 var 报 undef**;core var 没有 :doc |
| `:pending/printer` | 19 | *print-length*/*print-level*/*print-meta*/*print-namespace-maps*、Class 的 str、次正规浮点数、ex-info 的 str |
| `:pending/reader` | +18 | 读错误的 JVM 信息、`0xFFN`、`"\000"`、`#=`、`garbage!@` |
| `:pending/core-bugs` | 17 | **`#()` 里的 `%&` 报元数错误**、`for` 的 `:while`、`definline`、`cond->`、map 的 rest 解构、多输入 map transducer、case 混合常量 …… |
| `:pending/laziness` | 15 | **`sequence`/`eduction` 是急切的(无限源会挂住)**、iterate 提前调用 f、mapcat/dedupe、pmap |
| `:pending/host-types` | +12 | Thread、Math 静态方法、Keyword 方法、`java.util.List/.size` …… |
| `:pending/regex-edge` | 10 | Java 正则转译的边角 |
| `:pending/format-edge` | 8 | format 的边角 |
| `:pending/records` | 7 | record 的 map?/coll?、conj、__extmap |
| `:pending/metadata` | +6 | 列表 conj/pop/into 丢元数据、select-keys 丢元数据 |
| `:pending/ref-types` | 5 | atom 的 :meta/:validator 构造选项、atom 上的 alter-meta! |
| 其他 | 12 | compiler 2、runtime-eval 2、numbers 1、corpus-environment 2(要 override,不是修) |

**看到的严重问题**(建议最先修):`#(... %&)` 不可用;`(range "a")` 把内存吃满被杀;`sequence`/`eduction` 对无限源挂住;命名空间加载期间经 var 对象用本模块的 var 报 undef。
