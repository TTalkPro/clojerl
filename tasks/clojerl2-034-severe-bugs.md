# clojerl2-034 分诊发现的 4 个严重问题

状态:已完成(2026-10-12)
里程碑:M6(一致性收尾)
依赖:clojerl2-033

## 目标

修掉 clojerl2-033 分诊时发现的 4 个严重问题:`#()` 里的 `%&` 不可用;`(range "a")` 吃满内存;`sequence`/`eduction` 遇到无限源挂住;命名空间加载期间经 var 对象使用本模块的 var 报 undef。

## 工作内容

- [x] reader:`#()` 有 `%&` 时参数向量漏了 `&`(`(fn* [%&] ...)` → `(fn* [& %&] ...)`);reader 测试原先把错误形状当成了期望值,一并改正
- [x] `range`:调用时检查边界是数字(nil → NullPointerException,其他 → ClassCastException,`clj2_rt:not_number/1`)。Erlang 项序里数字小于一切二进制,`(< 0 "a")` 为真,原实现会无限生成
- [x] `sequence`(`eduction` 就是它):按源元素逐步推进的惰性实现,有状态 xform 在源结束或 reduced 时冲刷;xform 在第一次被实现时才实例化,所以它的状态(volatile 按进程存)属于实现它的进程——在命名空间加载进程里创建、在别的进程里遍历的 seq 也能用
- [x] 命名空间加载期间:on_load 进程里经导出表的调用都是 undef,本地 fun 可用。每个命名空间模块生成本地的 `'__var__'/1`,init 把它放进进程字典 `{clj2_loading, M}`,`clj2_rt:var_value/3` 优先用它。另外 init 期间 `*ns*` 绑定为该命名空间(与 JVM 加载文件一致;init 在独立进程里跑,不影响调用方)
- [x] corpus 的 pending 原因表改由 `clj2_corpus:pending_legend/0` 维护(`make corpus-rebaseline` 会用它重写 `:pending`;clojerl2-033 手改的说明曾被冲掉)

## 验收标准

- 4 个问题各有回归测试(`clj2_stdlib_tests`)
- `make test`、`make certify`、`make cts` 全绿

## 结论

- 远端门控:eunit 649 全过;corpus 3715 → **3739**/4841,0 新失败、0 过期、0 未登记原因;CTS 与基线一致(4882 通过);smoke 通过。
- 新通过的条目:`#()` 的 `%&` 6 条、`sequence`/`eduction` 惰性 3 条、经 var 对象使用本模块 var 11 条(deref、调用、apply 宏 var、同文件宏的 macroexpand-1、alter-meta! :macro 等)、`range` 1 条,以及顺带过的 compile-eval 2 条。
- 取舍:`sequence` 在调用时不实现第一个元素(JVM 会),保留在 `:pending/laziness`;换来的是跨进程遍历可用。
- `*ns*` 在加载期间绑定后,corpus 里 2 条读 `*ns*` 的条目改为 `:pending/corpus-environment`:JVM 生成期望值时在 REPL 的 user 里求值,测试框架则把每个条目当作独立命名空间加载。
- 顺带看到、未处理:`load-string` 里的 `ns` 形式会改变调用方的 `*ns*`(JVM 结束后会恢复)。
