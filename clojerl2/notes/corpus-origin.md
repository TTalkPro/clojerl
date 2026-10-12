# corpus 的来历(jolt 如何做出 corpus.edn)

clojerl2 的一致性语料 `test/corpus.edn` 拷自 jolt 的 `test/chez/corpus.edn`。本文记录 jolt 是怎样做出这份语料的,依据是 jolt 仓库(`~/workspace/jolt`)里的 `test/conformance/SPEC.md`、`CONTRIBUTING.md` 和 `corpus.edn` 的 git 历史(2026-10-12 查阅)。

## 概要

jolt 的 corpus 不是一次性设计出来的:先从早期单元测试里抽出来,再随修 bug 一条条增长,后来把期望值改为由 JVM Clojure 生成,并升格为一份与宿主无关的语言规范。

## 演变

| 时间 | 提交 | 事件 |
|---|---|---|
| 2026-06-17 | `c9316dd3` "Chez Phase 0a+0b" | 从 Janet 版的 `test/spec/*.janet` `defspec` 表抽出,共 2655 条 |
| 2026-06-20 | `635bbbcc` "Conformance inc2" | 并入另一处 355 个手写用例,去重后 +261 条,共 2919 条 |
| 2026-06-20 | `f54e99cc` "Conformance inc3" | 升格为文档化的可移植规范:唯一 id、profile、SPEC.md |
| 之后 | 共 591 次提交改动该文件 | 随修 bug 补条目,长到约 7166 行 |

### 1. 起点:从 Janet 版的测试表抽出

- jolt 最早跑在 Janet 上,测试写成 `test/spec/*.janet` 里的 `defspec` 表。
- 准备移植到 Chez Scheme 时,作者用 `test/chez/extract-corpus.janet` 把这些表抽成 `corpus.edn`。文件格式既是合法 EDN,也是合法 Janet 数据。
- 同时写了一个 runner(`run-corpus.janet`),经命令行驱动任意 jolt 实现(`JOLT_BIN` 可换),逐条在子进程里跑。同一份语料检验每个宿主,这是"与宿主无关"的出发点。当时 Janet 版通过 2641 / 2655,14 条已知分歧登记在案,门控只在出现新分歧时失败。

### 2. 合并散落的手写用例

`test/integration/conformance-test.janet` 里有 355 个内联手写用例(惰性序列、IFn、解构、transducer 等),原本不在语料里,别的宿主看不到。`extract-corpus.janet` 改为也抽取它们,按 `:actual` 去重后增加 261 条,按原文件的 `###` 章节归入 41 个 `conformance / <section>` suite。

### 3. 期望值改由 JVM 生成,升格为规范

- 早期每条 `:expected` 都是手写的,可能写错。作者加了两个工具:
  - `test/conformance/certify.clj`:在 JVM Clojure 上逐条求值 `:actual` 和 `:expected`,核对 jolt 的期望值;对不上的必须分类登记,门控在出现新分歧或登记过期时失败。
  - `test/conformance/regen-corpus.clj`:在一个 JVM 进程里求值每条 `:actual`,把 JVM 的结果写回 `:expected`。
- 从此 `corpus.edn` 是"冻结的契约":答案以 JVM 为准;新条目直接写进 `corpus.edn`,再用 `regen-corpus.clj` 重新生成答案。
- `[:suite :label]` 定为唯一的条目 id,重复的 label 加 ` (N)` 区分。
- `test/conformance/profile.edn`(`certify.clj --profile` 生成)给不可移植的条目标上所需的宿主能力,例如 `:host/jvm-interop`、`:numerics/double-only`、`:concurrency/snapshot`、`:runtime/eval`。没被标的条目算可移植,任何忠实的 Clojure 实现都应通过。一个实现的"一致性等级"就是可移植条目加上它实现了的能力族。
- `test/conformance/known-divergences.edn` 登记少数无法回读的行:JVM 结果是不透明的宿主对象(数组、transient、atom、bean、proxy 打印成 `#object[..@addr]`),语料只好保留 jolt 的值。
- `SPEC.md` 写明行格式、比较规则,以及新宿主怎样写一个约 30 行的 harness 来跑它。

### 4. 随修 bug 持续增长

修一个 bug 时补上能复现它的条目,有些条目旁的注释里带着 jolt 的问题编号(如 `jolt-nku`)。最近的提交如 "vswap! is a macro, as on the JVM"、"StringBuilder and StringBuffer follow the JDK" 都是这样加进来的。

## 行格式与比较规则

```edn
{:suite       "numbers / arithmetic"   ; 分组;"<suite> :: <label>" 是条目 id
 :label       "integer add"            ; suite 内唯一
 :actual      "(+ 1 2)"                ; 要求值的 Clojure 源码
 :expected    "3"                      ; 其值必须与之相等的源码,或 :throws
 :portability :common}                 ; :common 任何方言都应满足;
                                       ; :jvm 用到宿主互操作,非 JVM 方言跳过
```

- 比较用 `=` 比值,不比打印文本,所以 map/set 的迭代顺序无关。
- 因此类型和惰性上的差异,值比较看不出来:`(= [0 1] '(0 1))` 为真。规范要求另写谓词条目钉住类型(`seq?`、`vector?`),用无限序列上的 `take` 钉住惰性(不惰性时会挂起,而不只是结果不同)。
- `:expected :throws` 断言求值 `:actual` 会抛错。

## clojerl2 如何使用它

- 来源:jolt `test/chez/corpus.edn` @ 6c2685e(EPL-2.0),原样拷入 `test/corpus.edn`。
- 只跑 `:portability :common` 条目,共 4841 条。
- 期望值:用 jolt 的 `regen-corpus.clj`(移植为 `tools/regen-corpus.clj`)在 JVM Clojure 1.12.5 上重新生成,入口 `make corpus-regen`;日常 CI 不需要 JVM(clojerl2-022)。
- 判定照 jolt:`:actual` 与 `:expected` 各自用 clojerl2 求值,再用 `=` 比较(`src/erl/clj2_corpus.erl`)。
- jolt 自己的失败登记、`profile.edn` 和 `known-divergences.edn` 没有沿用。clojerl2 用自己的 `test/corpus-known-failures.edn`(每条失败的原因:待办 `:pending/...` 或分歧 id)和 `test/known-divergences.edn`,由 `make certify` 门控,基线见 [corpus-baseline.md](corpus-baseline.md)。
- 第二套来源 clojure-test-suite 也是照 jolt 的 `host/chez/cts.sh` 接入的(`make cts`,clojerl2-022)。
