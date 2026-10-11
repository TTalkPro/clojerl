# clojerl2-023 REPL 与 clojerl2 CLI

状态:已完成(2026-10-11)
里程碑:M5
依赖:clojerl2-014, clojerl2-021

## 目标

实现 REPL 与 `clojerl2` CLI:单轨编译求值,无解释器,每个顶层 form 走同一条编译路径。

## 设计依据

- [02](../designs/02-beam-backend.md) §5 — 求值单轨(D11):per-eval 生成 `__eval_N` 模块,`compile:forms` + `code:load_binary`
- [02](../designs/02-beam-backend.md) §5 — 热代码两版本语义的文档化承诺
- [02](../designs/02-beam-backend.md) §5 — `compile:forms` 在专用编译进程执行,避免污染 REPL 进程的 code server 状态
- [02](../designs/02-beam-backend.md) §8 — eval 模块 GC 策略为开放问题,实测后定
- [04](../designs/04-bootstrap-and-conformance.md) §4.3 — 编译器启动时打印自身 seed 的 git 提交号

## 工作内容

- [x] per-eval 模块 `__eval_N`(N 单调递增)生成:导出 `__eval/0` 返回 form 值;`def`/`defn` 副作用经 on_load 注册路径写入当前 NS
- [x] eval 模块 GC 策略:N 超阈值或值已读取后 `code:purge`/`code:delete`;滑动窗口 vs LRU 按 REPL 实测定(02 §8 开放问题,结论回填文档)
- [x] 编译进程隔离:专用编译进程执行 `compile:forms`
- [x] CLI:`clojerl2` 可执行(escript 或 release 启动脚本),启动时打印 seed 提交号
- [x] REPL 基本设施:readline、历史、`doc` 宏(库侧在 04-repl 层,本任务做接线)
- [x] REPL 冒烟脚本:覆盖求值、defn、重定义、宏展开、错误报告

## 验收标准

- REPL 冒烟脚本通过(进 CI)
- `defn` 重定义语义符合 02 §5 文档:旧 fun 值继续跑旧代码,新调用走新版
- 连续 eval 不泄漏模块:阈值 purge 生效,长跑会话模块数有界(测试断言)

## 结论

- **求值**(`clj2_compiler:eval`):逐 form 求值,前一个 form 定义的宏下一个就能用。
  - 表达式编译进一次性的 `clj2_eval_N` 模块。名字沿用已有的 `clj2_eval_N`,没有改成 `__eval_N`,导出 `run/0`。
  - `def` 编译进该 var 自己的模块 `<ns>$v$<name>`,与编译期 segment 同一机制,再把 var 写进命名空间注册表,`module` 字段指向它。原因:命名空间模块是整体编译的,REPL 里没法往里追加函数。
  - `ns` 切换当前命名空间并登记 alias/refer;`extend-type` 编出 impl 模块。
  - `user` 命名空间始终存在,但没有自己的模块:OTP kernel 已经有 `user` 模块。
- **重定义语义**(验收项):跨模块取 fn var 的值时,通过定义模块里隐藏的 `'__fn__'/1` 取本地 fun,绑定在当时的模块版本上。原来的外部 fun 总是调用最新版本,做不到这一点。于是 `(def g f)` 之后重定义 `f`,`g` 跑旧代码,经 var 的调用走新代码,与 02 §5 一致。BEAM 只保留两个版本:第二次重定义后,持有最旧版本的 fun 值调用会报 `badfun`。已写进 02 §5 和 `:namespaces/hot-code-two-versions`,并有测试断言。同一 var 的定义用 `global:trans` 串行化:corpus 里并发重定义暴露过 purge/load 竞争。
- **eval 模块 GC**(02 §8 开放问题已关闭):固定滑动窗口,保留最近 100 个。LRU 在这里没有意义,eval 模块只运行一次。测试连续求值 250 次,断言模块数不超过 100。
- **编译进程隔离**:所有 `compile:forms` 都在一次性进程里跑(`compile_forms/2`)。测试断言求值后调用者的进程字典只多出动态绑定和惰性序列的 memo。
- **运行时求值**(新模块 `clj2_rt_eval`,core 01 层加了对应函数):`*ns*`(动态 var,按进程绑定)、`in-ns`、`eval`、`read-string`、`load-string`、`load-file`、`macroexpand(-1)`、`require`(源码路径、`:as`/`:refer`/`:refer :all`/`:reload`)、`find-ns`、`the-ns`、`create-ns`、`all-ns`、`ns-name`。编译命名空间期间 `*ns*` 绑定为该命名空间,编译结束后恢复。命名空间就是符号,登记为 `:namespaces/symbols`。
- **CLI**:`bin/clojerl2`,底层是 `erl -noshell -run clj2_cli main`。
  - 无参数进 REPL;`-e` 求值;`FILE ARGS` 逐 form 跑脚本并设置 `*command-line-args*`;`-m NS` 调用其 `-main`;`-p` 指定源码路径;出错退出码为 1。
  - `make` 把 clojure.core 预编译进 `ebin/`(`clj2_core:build/1`),启动约 0.5s;从源码编译要 1.07s。
  - banner 和 `--version` 打印构建时的 `git describe`(`ebin/clj2.build`)。04 §4.3 原本要求打印 seed 的提交号,但 seed 路线已作废(designs/09),所以改为打印构建提交号。
- **REPL**(`clj2_repl`):多行输入,读到完整 form 才求值(依据 reader 的 `EOF while reading`);一行可以有多个 form。支持 `*1`/`*2`/`*3`/`*e` 和 `:repl/quit`。错误按 Clojure 的样式报告:无法解析的符号、arity、ExceptionInfo;BEAM 自己的异常保留原名,如 `error:badarith`。行编辑和历史用 OTP 的 `shell:start_interactive({noshell, cooked})` 加 `-kernel shell_history enabled`;不是终端时(管道、CI)静默跳过。`doc` 已接线。
- **Unicode**:终端 I/O 切到 unicode 加 binary 行。修了四处 list 与 binary 混转的 bug:
  - `clj2_print:pr_str` 原来用 `iolist_to_binary` 拼 `~p` 的输出,遇到码点大于 255 就崩;
  - `format` 原来按字节处理格式串,padding 也按字节算;
  - reader 读 `:中文` 这样的关键字字面量会崩;
  - `clj2_corpus` 里的 `<<"…§…">>` 缺 `/utf8`。
  另外,BEAM 模块名必须是 latin1,所以 var 模块名里的非 latin1 码点转写成 `$uXXXX$`。测试覆盖中文字符串、关键字、var 名、format 和打印。
- **数学运算对齐 BEAM**(项目决定):登记 `:number/beam-semantics`,包括整数无界、类型提示不做强转、浮点除零是 `badarith`、比较不检查类型。corpus 里 33 条改挂到它,另有 1 条 ratio 改挂 `:number/no-ratio-arithmetic`。`mod`/`quot` 对浮点报 `badarith`、`(apply bit-or …)` 失败,这两项是真 bug,仍在 triage。
- **reader 修正**:未闭合的 map 原来报 "even number of forms",现在报 EOF;错误信息里的 `expected 41` 改成 `expected )`。
- **corpus**:1952 / 4842,原来 1880。72 条变成通过后被门控标为 stale,已从登记表移除。会改动全局命名空间的条目(`ns`/`in-ns`/`eval`/`load-string`/`require`…)改为串行运行,结束后清掉它们创建的命名空间:并行跑时它们会互相重定义 var,门控结果不稳定。`:pending/runtime-eval` 剩 59 条,是命名空间反射一类(`ns-publics`/`intern`/var 对象等),它的待办改标为本任务的后续。原先挂在它名下的 125 条现在归入 `:pending/stdlib-namespaces`:`clojure.string`/`clojure.set` 等还没移植。
- **验证**:eunit 520 条(新增 `clj2_repl_tests`);`make smoke`(`test/repl-smoke.sh`,覆盖 REPL、`-e`、脚本、`-m`、退出码和中文)已进 CI。
