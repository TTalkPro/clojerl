# clojerl2-015 Var 与命名空间运行时

状态:已完成(2026-10-11)
里程碑:M4
依赖:clojerl2-010

## 目标

实现 Var/NS 运行时模型:一个 NS = 一个 BEAM 模块,直接链接为默认,废除 clojerl 1.0 的 `__val` 远程调用与 fake_fun 补救机制。

## 设计依据

- [03](../designs/03-runtime-model.md) §2.1 — NS = BEAM 模块、var = 模块函数、直接链接默认
- [03](../designs/03-runtime-model.md) §2.1 — 前向引用在 NS 编译粒度解决,废除 fake_fun
- [03](../designs/03-runtime-model.md) §2.3 — `^:dynamic`/`^:redef` 间接表选 ETS 而非 persistent_term
- [02](../designs/02-beam-backend.md) §3.4 — `on_load(__ns_init__/0)` 注册路径
- [02](../designs/02-beam-backend.md) §5 — 热代码两版本语义
- [01](../designs/01-nanopass-pipeline.md) §5 — resolve-symbols pass 的编译期 var 解析

## 工作内容

- [x] ETS NS 注册表:一张 `named + read_concurrency` 表,单 gen_server 持有,写串行、读直连(03 §2.1)
- [x] `^:dynamic`/`^:redef` var 的 ETS 间接表,调用点编译为访问器 `NsMod:Name()` → `clj2_var:deref/2`
- [x] NS 模块 `__ns_init__/0` on_load 注册 var 清单(02 §3.4);实测限制是"不可远程调用本模块",同 NS 引用一律本地调用
- [x] resolve-symbols pass 侧配合:编译期解析到的静态 var 直接生成 `NsMod:fn/N`(link pass);先跑 declare pass 收集全 NS 的 def 清单以解决前向引用
- [x] REPL 重定义的热代码两版本语义写入文档(02 §5:旧代码跑旧版,新调用链新版,不模拟 JVM 全局立即生效)

## 验收标准

- 编译产物中静态 var 调用为直接 `M:F/N`:grep beam 反汇编(`beam_disasm`)确认无 `__val`/fake_fun 残留
- 重定义语义测试:`defn` 重定义后新调用走新代码、持有旧 fun 的进程行为不变
- 注册表并发测试:多进程并发建/删 NS 与读 var 清单无竞争错误

## 结论

2026-10-11 完成,设计落点见 [designs/03](../designs/03-runtime-model.md) §2.1a、[designs/02](../designs/02-beam-backend.md) §3.1/§3.4、[designs/09](../designs/09-erlang-hosted-compiler.md) §2/§3。

- 代码:`clj2_ns`(注册表 gen_server)、`clj2_var`(根值 + 动态绑定栈)、`clj2_p_declare`、`clj2_p_link`;`clj2_p_parse`/`clj2_p_resolve`/`clj2_p_emit`/`clj2_compiler` 相应扩展(`compile_ns/1,2`、`load_ns/1,2`、`eval/2` 的 `ns` 选项)。
- 测试 `clojerl2/test/clj2_ns_tests.erl`,三条验收:
  - 直接链接:`beam_disasm` 断言跨 NS 调用是 `call_ext` 到 `{'t.basic', f, 1}`、同 NS 调用是本地 `call`,且无 `erlang:apply`/`clj2_rt:invoke`;
  - 重定义:新调用走新代码,旧版本闭包仍返回旧值;有进程停在旧版本代码里时拒绝再次加载(不杀进程),进程退出后可以加载;
  - 注册表并发:20 个写进程各做 50 轮注册/查询/删除,5 个读进程并发 `all/0`,无错误、无残留。
- 偏离原设计:不做名称改编、arity 不进函数名(02 §3.1 修订);arity 不匹配的直接调用是编译错误(登记分歧);`ns` 暂由 parse 直接处理,只支持 `(:require [ns :as a :refer [...]])`。
- 未做:`#'x` / Var 对象、`binding` 宏(需宏系统,运行时 `push_binding`/`pop_binding` 已就绪)、按源路径查找并加载 NS 文件(023/024)。
