# clojerl2-018 引用类型

状态:未开始
里程碑:M4
依赖:clojerl2-015, clojerl2-003

## 目标

实现引用类型:atom = ETS 行 + `ets:select_replace` CAS;agent = 专用进程;delay = thunk + 记忆单元;promise/future = 进程 + 消息;STM/ref 诚实 raise。

## 设计依据

- [03](../designs/03-runtime-model.md) §5.2 — 引用类型诚实降级总表(atom/agent/delay/ref/promise/future)
- [03](../designs/03-runtime-model.md) §5.2 — atom 备选"每值一进程"的否决理由
- [03](../designs/03-runtime-model.md) §5.3 — 记忆化机制选型(pdict 默认,ETS 开关)
- [03](../designs/03-runtime-model.md) §3 — pdict 动态绑定与 `bound-fn` 帧快照
- [03](../designs/03-runtime-model.md) §10 风险 5 — 热点 atom CAS 争用,文档劝用 agent

## 工作内容

- [ ] atom:ETS 行存值,`swap!` = `ets:select_replace` CAS 重试循环,`reset!` = 单写,`deref` = ETS 读;watch 列表随行存储、变更后异步通知
- [ ] agent:专用进程(gen_server 风格),`send`/`send-off` 的顺序性 = 消息队列顺序;动作执行携带绑定帧
- [ ] delay:thunk + 记忆单元,默认 pdict 版;ETS 开关版按 003 spike 结论实现
- [ ] promise/future:进程 + 消息,`deref` = `receive`,`deliver` = `send`;`future` 宏用 `bound-fn` 语义
- [ ] `bound-fn`:创建时快照 pdict 绑定帧,调用时重建(03 §3)
- [ ] STM 族(`ref`/`dosync`/`alter`/`commute`):明确 raise,错误信息指向 known-divergences 条目

## 验收标准

- atom CAS 并发正确性测试:多进程并发 `swap!` 无丢失更新
- agent 动作顺序性测试:`send` 序列按提交顺序执行
- 调 STM 族宏 raise 信息明确的错误,且该分歧已登记 known-divergences

## 结论

(完成后填写)
