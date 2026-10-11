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

clojure.core(目前是 00-kernel 层)由 `clj2_core:boot()` 按 `src/clj2/core/boot-order.edn` 加载;之后的命名空间与 `eval` 自动 refer 它:

```sh
erl -pa ebin -eval '{ok, _} = clj2_core:boot(), io:format("~p~n", [clj2_compiler:eval(<<"(->> (range 10) (filter even?) (map inc) (reduce +))">>)]), halt().'
```

pass 链见 `clj2_compiler:pipeline/0`;加优化 = 往列表里加一个 pass 模块。`clj2_compiler:eval(Src, #{trace => [PassName]})` 打印该 pass 的输出。
