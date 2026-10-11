# clojerl2

基于 nanopass 的 Clojure on ERTS 全新实现。设计文档见 [../designs/](../designs/),任务索引见 [../TASK.md](../TASK.md)。

## 目标环境

Erlang/OTP **27+**(本机开发用 28)。设计决策与里程碑判据见 designs/00 与 designs/04 §7。

## 目录布局

| 目录 | 内容 | 归属设计 |
|---|---|---|
| `src/erl/` | 原语层与工具(Erlang):值构造/谓词、Var/NS、协议分派、引用类型、IO | designs/03 §8 第 0 层 |
| `src/clj2/` | 编译器与 core 库(Clojure,`.cljc`):nanopass 框架、pass 链、core 各层 | designs/01 §3、designs/04 §6 |
| `bootstrap/seed/` | 入库种子 beam + manifest(d2 决策) | designs/04 §3 |
| `bench/` | 基准与 spike 代码(escript) | tasks/001-003 |
| `notes/` | spike 报告与实测基线 | tasks/001-003 |
| `test/` | 测试(eunit / corpus) | designs/04 §5 |
| `script/` | 构建期脚本(`check-subset` 等) | designs/04 §2.4 |

## 现状

M0(spike 验证阶段)。运行基准:

```sh
escript clojerl2/bench/spike-001-value-repr.escript
escript clojerl2/bench/spike-002-protocol-dispatch.escript
escript clojerl2/bench/spike-003-lazy-memo.escript
```

基准结论见 `notes/`,会回填对应任务文件的"结论"节。

## 自举约束(编译器源码)

编译器与框架源码(Clojure)必须限制在 clojerl 1.0 支持的特性集内(clojerl2-011 落地为 `script/check-subset` 的 lint)。允许/禁止清单见 designs/04 §2.4。
