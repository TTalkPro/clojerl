# clojerl2-022 corpus 一致性测试体系

状态:已完成(2026-10-11;门控进 CI;2026-10-12 次级来源 clojure-test-suite 接入,见结论)
里程碑:M4
依赖:clojerl2-021

## 目标

建立一致性测试体系:corpus.edn + JVM oracle + known-divergences 门控,全量进 CI。

## 设计依据

- [04](../designs/04-bootstrap-and-conformance.md) §5.1 — 架构:corpus/runner/EDN 规范化比较/oracle regen
- [04](../designs/04-bootstrap-and-conformance.md) §5.1 — known-divergences 门控:未登记失败红、已登记却通过也红
- [04](../designs/04-bootstrap-and-conformance.md) §5.2 — 分层接入:corpus 按 core 分层打标签,全量门控自 M4 起强制
- [00](../designs/00-overview.md) §4 D12 — 一致性测试决策
- [03](../designs/03-runtime-model.md) §11 — 全部分歧(NaN/码点下标/跨进程绑定与记忆化/STM)进注册表

## 工作内容

- [x] 移植 jolt corpus.edn 格式:每条目 `{:expr :expected :tags}`;`expected` 为入库静态值
- [x] runner:clojerl2 编译并求值条目 → 两边结果经 EDN 读回再比较;不可 EDN 化的值(fun、atom)按打印表示比较并在 schema 标注
- [x] JVM Clojure oracle regen 模式:`make corpus-regen` 重新生成期望值,日常 CI 不依赖 JVM
- [x] `known-divergences.edn` 门控:未登记 failure → CI 红;登记条目意外通过 → 同样红(防注册表腐烂);每条必须带原因且与 03/02 的分歧记录一致
- [x] 次级来源接入:clojure-test-suite 整体接入(逐命名空间跑,按 jolt `cts.sh` 的方式,不转 corpus 条目);clojerl 1.0 测试套件未接入(见结论)
- [x] CI 全量门控:M4 起强制,无未登记分歧

## 验收标准

- CI 全量门控运行,`make certify` 模式绿
- 注册表每条目带原因与设计文档依据(03 §1.3/§3/§5.2/§7、02 §5 等)
- 基线通过率写入报告(按 core 分层标签分列)

## 结论

- **语料**:来历(jolt 如何从 Janet 测试表抽出、改由 JVM 生成期望值)见 `clojerl2/notes/corpus-origin.md`。直接用 jolt 的行格式 `{:suite :label :expected :actual :portability}`(`:actual` 即设计里的 `:expr`),只跑 `:common` 条目。没有手写 `:tags`:每条按它引用的最靠后的 core 层自动归层(`clj2_core:layer_vars/0`),报告按层分列。
- **判定**照 jolt:`:actual` 和 `:expected` 都是源码,各自编译求值后用 `=` 比较(向量 `:expected` 等于 seq `:actual`);`:expected :throws` 要求抛错。编译期错误按 JVM 的 CompilerException 处理,算抛错;未解析符号和不支持的形式除外。不可 EDN 化的值不走打印比较,`=` 已能覆盖。
- **修掉的 runner bug**:旧 runner 把 `:expected` 当打印文本比、不认 `:throws`(224 条)。`flatten_do` 对 regex/deref/tagged 等字面量调用 `to_data` 会崩(约 600 条)。cleanup 按前缀清模块,`corpus.e1` 会误清 `corpus.e12`,有并行竞态。
- **oracle**:`make corpus-regen` 跑 `clojerl2/tools/regen-corpus.clj`(移植自 jolt),用 JVM Clojure 1.12.5 重新生成。194 行 `:expected` 有变化,其中 38 条语义不同,20 条在 `:common` 里,比如 `dedupe` 的惰性。改成原地只改变化的行,注释保留;退出时显式 `System/exit`,否则超时 future 会让 JVM 一直不退。CI 不依赖 JVM。
- **门控**:`make certify`(`clj2_corpus:certify/0`)对照 `clojerl2/test/corpus-known-failures.edn`。未登记的失败、登记了却通过的条目、cause 不在注册表里,任一出现即红。每条的 cause 是 `known-divergences.edn` 里的分歧 id,或文件头 `:pending` 表里带原因和任务号的待办。`make corpus-rebaseline` 重写登记表,已登记条目保留手工改过的 cause。连续两次全量运行和 2 核约束下(91s)结果都一致。`clj2_divergences_tests` 检查登记表:cause 都已注册、条目都是真实的 `:common` 行。
- **基线 1880 / 4842(38.8%)**,见 `clojerl2/notes/corpus-baseline.md`。按层:00-kernel 37%、01-core 48%、02-protocols 20%、03-print 22%。2962 条失败中,12 条归到已登记的分歧:`:fn/structural-identity`(本任务新登记:Erlang fun 按值比较)、`:char/integer`、`:number/no-ratio-arithmetic`。其余是 `:pending`,大头是缺失的 core var(471)、运行时 eval/require(320)、字符串/正则/IO(306)、引用类型(235)、`catch` JVM 异常类(217)。`:pending/triage`(341 条)是能跑但与 JVM 不一致的,其中不少是真 bug,比如 `& {:keys}` kwargs 解构、`:pre`、`(sort-by f [])` 返回 nil、`(ex-data (ex-info "m" nil))`。后续任务修一条,`make certify` 就会提示把它从登记表移除。
- **次级来源:clojure-test-suite(2026-10-12 接入)**。[jank-lang/clojure-test-suite](https://github.com/jank-lang/clojure-test-suite) 以 git 子模块进 `clojerl2/vendor/clojure-test-suite`(@ 95d4a91,与 jolt/cleat 同一提交),按 jolt `host/chez/cts.sh` 的方式接入而不是转成 corpus 条目:
  - `test/cts.sh`(`make cts`,已进 CI,checkout 带 `submodules: true`):每个测试命名空间一个 VM(`bin/clojerl2 -p test/cts:vendor/... -m cts-run <ns>`,`test/cts/cts_run.clj` 打印 `CTS-RESULT ns pass fail error`),`timeout` 120 s,进程堆上限 256 MiB(`CLJ2_ERL_FLAGS=+hmax`,`bin/clojerl2` 新增该环境变量),整体跑在 Makefile 的 4G cgroup 里;CPU 数个 worker 并行,全量 104 s。
  - 门控与 certify 同款:`test/cts-known-failures.txt` 登记每个命名空间的 fail/error 数(HUNG/CRASH 也登记),变好变坏都红;数字不符的命名空间先单独重跑一次再判定,避免并行下的时序抖动。`CLJ2_CTS_WRITE_BASELINE=1 make cts` 重写登记表;`CLJ2_CTS_NS=a,b make cts` 只跑指定命名空间并打印明细。
  - 为此补上的东西:reader 条件 `#?`/`#?@`(特性 `:clje` + `:default`,拼接进 list/vector/map/set,不匹配的分支读进来再丢);`clojure.test`(按 jolt 的实现改写:登记表代替 var 扫描、atom 代替 ref、`deftest` 展开时捕获命名空间)、`clojure.walk`、`clojure.template`、`clojure.set`(移植自 jolt,EPL-1.0,文件头记来源);命名空间反射 `resolve`/`ns-resolve`/`ns-publics`/`ns-interns`/`ns-map`/`ns-refers`/`ns-aliases`/`ns-unalias`/`find-var`/`intern`/`ns-unmap`/`remove-ns`/`requiring-resolve`/`bound?`(`when-var-exists` 宏在展开时 `resolve`);编译的模块在 init 里把 `ns` 形式的 alias/refer 登记进 registry(`clj2_ns:register/4`);命名空间从它的 `ns` 形式起就存在。
  - 为了让一个文件里的个别用法不拖垮整个命名空间:`##NaN`/`##Inf`、`1.5M`、`#inst` 这类运行时没有值的字面量读得进来、求值时抛错、作 `case` 常量时不匹配(以前是编译错误);`\o`/`\x`/`\u` 单独出现是字母;`%` 不再结束 token(`:%percent`);`assoc` 奇数参数和对 set 的 `assoc` 抛错;`transient` 只接受 vector/map/set,错误信息不再打印(会实现无穷序列的)集合本身;`derive` 接受类作子标签。
  - **基线**:247 个命名空间,断言通过 4660 / 失败 414 / 错误 743,0 挂起 / 0 崩溃;139 个命名空间有失败。失败大头是数字语义(ratio 运算、`##NaN`、64 位溢出:`star`/`plus`/`mod`/`quot`/`rem` 五个命名空间占 300 多条)和 BigDecimal。10 个命名空间加载失败:`minus`/`slash`(`(-)`/`(/)` 零元数是编译错误,`:fn/arity-at-compile-time`)、`drop-while`(缺 transducer 元数,同上)、`ifn-qmark`/`remove-watch`/`var-qmark`(fn 体内 `def`/`defmulti`,`:pending/compiler`)、`ancestors`/`parents`(测试里写了 JVM 接口名 `clojure.core_test.ancestors.TestAncestorsProtocol`)、`add-watch`(`catch` 的类只给了 `:clj`/`:cljs` 等分支,没有 `:default`)、`edn-test.read-string`(`clojure.edn` 未移植)。
  - corpus 顺带从 3544 涨到 3614 / 4841(反射函数、clojure.set/walk、`vswap!`、`spit`/`slurp` 拒绝 nil 路径等 70 条),`make certify` 0 new / 0 stale。
- **仍未接入**:clojerl 1.0 的测试套件(`test/clj/clojure/test_clojure/*.clje`)——它依赖 clojerl 1.0 的宿主类型(`erlang.io.*`、`clojerl.*`),按 D1 应登记分歧而不是继承,留作后续。
- **内存**:全部目标走 `systemd-run --scope -p MemoryMax=4G`,单进程堆上限 256 MiB(含 binary)。CI 容器里没有 systemd 时只靠单进程上限兜底。
