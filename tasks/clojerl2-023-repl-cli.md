# clojerl2-023 REPL 与 clojerl2 CLI

状态:未开始
里程碑:M5
依赖:clojerl2-013, clojerl2-021

## 目标

实现 REPL 与 `clojerl2` CLI:单轨编译求值,无解释器,每个顶层 form 走同一条编译路径。

## 设计依据

- [02](../designs/02-beam-backend.md) §5 — 求值单轨(D11):per-eval 生成 `__eval_N` 模块,`compile:forms` + `code:load_binary`
- [02](../designs/02-beam-backend.md) §5 — 热代码两版本语义的文档化承诺
- [02](../designs/02-beam-backend.md) §5 — `compile:forms` 在专用编译进程执行,避免污染 REPL 进程的 code server 状态
- [02](../designs/02-beam-backend.md) §8 — eval 模块 GC 策略为开放问题,实测后定
- [04](../designs/04-bootstrap-and-conformance.md) §4.3 — 编译器启动时打印自身 seed 的 git 提交号

## 工作内容

- [ ] per-eval 模块 `__eval_N`(N 单调递增)生成:导出 `__eval/0` 返回 form 值;`def`/`defn` 副作用经 on_load 注册路径写入当前 NS
- [ ] eval 模块 GC 策略:N 超阈值或值已读取后 `code:purge`/`code:delete`;滑动窗口 vs LRU 按 REPL 实测定(02 §8 开放问题,结论回填文档)
- [ ] 编译进程隔离:专用编译进程执行 `compile:forms`
- [ ] CLI:`clojerl2` 可执行(escript 或 release 启动脚本),启动时打印 seed 提交号
- [ ] REPL 基本设施:readline、历史、`doc` 宏(库侧在 04-repl 层,本任务做接线)
- [ ] REPL 冒烟脚本:覆盖求值、defn、重定义、宏展开、错误报告

## 验收标准

- REPL 冒烟脚本通过(进 CI)
- `defn` 重定义语义符合 02 §5 文档:旧 fun 值继续跑旧代码,新调用走新版
- 连续 eval 不泄漏模块:阈值 purge 生效,长跑会话模块数有界(测试断言)

## 结论

(完成后填写)
