# clojerl2-015 Var 与命名空间运行时

状态:未开始
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

- [ ] ETS NS 注册表:一张 `named + read_concurrency` 表,单 gen_server 持有,写串行、读直连(03 §2.1)
- [ ] `^:dynamic`/`^:redef` var 的 ETS 间接表,调用点编译为 `clj_rt_var:deref(NsMod, Name)`
- [ ] NS 模块 `__ns_init__/0` on_load 注册 var 清单(02 §3.4),注意 on_load 禁止远程调用的限制
- [ ] resolve-symbols pass 侧配合:编译期解析到的静态 var 直接生成 `NsMod:fn/N`;先跑 declare pass 收集全 NS 的 def 清单以解决前向引用
- [ ] REPL 重定义的热代码两版本语义写入文档(02 §5:旧代码跑旧版,新调用链新版,不模拟 JVM 全局立即生效)

## 验收标准

- 编译产物中静态 var 调用为直接 `M:F/N`:grep beam 反汇编(`beam_disasm`)确认无 `__val`/fake_fun 残留
- 重定义语义测试:`defn` 重定义后新调用走新代码、持有旧 fun 的进程行为不变
- 注册表并发测试:多进程并发建/删 NS 与读 var 清单无竞争错误

## 结论

(完成后填写)
