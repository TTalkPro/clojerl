# clojerl2-014 00-kernel 层划定

状态:已完成(2026-10-11)
里程碑:M3
依赖:clojerl2-010

## 目标

实测划定 00-kernel 的最小函数集——仅含编译器自身使用的结构函数,打破"编译器依赖它要编译的库"的循环。

## 设计依据

- [04](../designs/04-bootstrap-and-conformance.md) §6.1 — 分层 core 表与 kernel 定位;`boot-order.edn` 显式层序
- [04](../designs/04-bootstrap-and-conformance.md) §8 O2 — kernel 确切清单需实测划定,结果回填 §6.1
- [00](../designs/00-overview.md) §6 风险 1 — 冷启动:子集小而能直译、大而能编译真实源码
- [03](../designs/03-runtime-model.md) — kernel 唯一允许依赖的 Erlang 运行时原语层

## 工作内容

- [x] kernel 函数集:编译器是 Erlang,改为按"clojure.core 最底层"划定——序列、集合、谓词、数与相等、符号与字符串、基础宏与解构(清单见 04 §6.1)
- [x] `core/boot-order.edn`:显式声明各层文件列表与依赖层,不做隐式文件序(依赖必须在前,违反即报错)
- [x] lint 规则:kernel 只准依赖 Erlang 原语层(`:allowed-ns []`,编译器 `allowed_ns` 选项执行);~~编译器源码只准依赖 kernel~~ 不适用(编译器是 Erlang)
- [x] kernel 层独立编译加载验证(`clj2_core:boot(#{upto => '00-kernel'})`)
- [x] 划定结果回填 04 §6.1,关闭开放问题 O2

## 验收标准

- kernel 层可独立编译加载,编译器在其上完整运行
- lint 拒绝编译器源码对 kernel 之外 core 层的任何引用(CI 变红用例证明)
- 04 §6.1 已回填实测清单,O2 标记关闭

## 结论

2026-10-11 完成。

- 代码:`clojerl2/src/clj2/core/00-kernel.clj`、`core/boot-order.edn`、`clj2_core`(加载器);第 0 层原语扩充于 `clj2_coll`/`clj2_rt`。
- 编译器配合:自动 refer `clojure.core`(`:refer-clojure :exclude`,本 NS 定义优先)、syntax-quote 限定 core 符号、`allowed_ns` lint、`refer_clojure => false`(加载 core 自身)、与自动导入 BIF 同名的 var 函数生成 `no_auto_import`、`compile_ns/load_ns` 接受已读入的形式列表。
- 顺带修正:reader 允许任意形式作 map 键(map 解构需要);宏实参里的 `#()` 与 syntax-quote 先展开再交给宏;常量集合字面量按元素值构造(原先 `{:a '(1)}` 会得到 `(quote (1))`)。
- 验收(`clojerl2/test/clj2_core_tests.erl`):
  - kernel 独立加载,序列/集合/数/字符串/宏/解构用例全过,用户命名空间对 core 的调用是 `call_ext`;
  - lint:假 core 引用另一个 Clojure 命名空间时编译报 `{lint, {namespace_not_allowed, ...}}`,只用 Erlang 模块时通过;boot-order 依赖在后报错;
  - 04 §6.1 已回填,O2 关闭。
- 已知分歧:symbol 是 atom、不带元数据,`defn-` 等同 `defn`,名字上的 `^:private` 等元数据丢失(`defn` 的文档字符串保留);`/` 不整除时得浮点数(无 ratio 运算);seq 为急切列表。
