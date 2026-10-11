# clojerl2

基于 nanopass 的 Clojure on ERTS 全新实现。设计文档见 [../designs/](../designs/),任务索引见 [../TASK.md](../TASK.md)。

## 目标环境

Erlang/OTP **27+**(本机开发用 28)。设计决策与里程碑判据见 designs/00 与 designs/04 §7。

## 目录布局

| 目录 | 内容 | 归属设计 |
|---|---|---|
| `src/erl/` | 编译器(Erlang):reader `clj2_reader`、nanopass 框架 `clj2_np`/`clj2_lang`、pass `clj2_p_*`、驱动 `clj2_compiler`;运行时 `clj2_rt` | designs/09、designs/01、designs/02 |
| `src/clj2/` | core 库(Clojure,`.cljc`):分层 core | designs/04 §6 |
| `bench/` | 基准与 spike 代码(escript) | tasks/001-003 |
| `notes/` | spike 报告与实测基线 | tasks/001-003 |
| `test/` | 测试(eunit / corpus) | designs/04 §5 |
| `script/` | 构建期脚本(`check-subset` 等) | designs/04 §2.4 |

## 现状

M0 spike 已完成;M1(reader + Erlang nanopass 框架)已完成;M2 pass 链进行中(designs/09 §2)。M0 基准:

```sh
escript clojerl2/bench/spike-001-value-repr.escript
escript clojerl2/bench/spike-002-protocol-dispatch.escript
escript clojerl2/bench/spike-003-lazy-memo.escript
```

基准结论见 `notes/`,会回填对应任务文件的"结论"节。

## 编译器

编译器用 Erlang 写(designs/09):

```sh
make test     # 编译 src/erl/ 并跑全部 eunit 套件
erl -pa ebin -eval 'io:format("~p~n", [clj2_compiler:eval(<<"(let* [f (fn* [x] (erlang/* x x))] (f 7))">>)]), halt().'
```

clojure.core(00-kernel 至 04-repl 五层)由 `clj2_core:boot()` 按 `src/clj2/core/boot-order.edn` 加载;之后的命名空间与 `eval` 自动 refer 它:

```sh
erl -pa ebin -eval '{ok, _} = clj2_core:boot(), io:format("~p~n", [clj2_compiler:eval(<<"(->> (range 10) (filter even?) (map inc) (reduce +))">>)]), halt().'
```

## REPL 与 CLI(clojerl2-023)

`make` 会把编译器和预编译好的 clojure.core 放进 `ebin/`,之后:

```sh
bin/clojerl2                          # REPL(Ctrl-D 或 :repl/quit 退出)
bin/clojerl2 -e '(+ 1 2)'             # 求值,打印非 nil 结果
bin/clojerl2 script.clj a b           # 逐 form 求值脚本;*command-line-args* 为 ("a" "b")
bin/clojerl2 -p src -m my.app x       # 从源码路径 require my.app,调用其 -main
make smoke                            # REPL/CLI 冒烟测试(进 CI)
```

REPL 里可以 `def`/`defn`/`defmacro`、`ns`/`in-ns`、`require`、`eval`、`read-string`、`macroexpand`。每个 var 编译进自己的模块,重定义遵循 BEAM 的两版本语义:之前取到的 fn 值继续跑旧代码,新调用走新版(designs/02 §5)。中文等非 ASCII 文本直接可用:字符串是 UTF-8 binary,终端 I/O 走 unicode 模式。

## 一致性语料(designs/04 §5)

`test/corpus.edn`(jolt corpus,`:expected` 来自 JVM Clojure)的 `:common` 条目逐条编译求值,用 `=` 与 `:expected` 比较:

```sh
make corpus             # 跑全量,写 notes/corpus-baseline.md(按 core 分层/suite/失败原因)
make certify            # 门控:失败必须登记在 test/corpus-known-failures.edn,登记了却通过也算失败
make corpus-rebaseline  # 修好或新增失败后重写登记表(已登记条目保留原 cause)
make corpus-regen       # 用 JVM Clojure(需要 `clojure` CLI)重新生成 :expected;CI 不需要 JVM
```

登记表里每条失败的 `:cause` 要么是 `test/known-divergences.edn` 里登记的有意分歧,要么是文件头 `:pending` 表里的待办原因(写明由哪个任务消除)。
这些目标在独立 cgroup 里跑,内存上限 4G(`CORPUS_MEM`);**不要裸跑 `clj2_corpus:run()`**:失控的条目曾把整个会话 OOM 掉。

pass 链见 `clj2_compiler:pipeline/0`;加优化 = 往列表里加一个 pass 模块。`clj2_compiler:eval(Src, #{trace => [PassName]})` 打印该 pass 的输出。
