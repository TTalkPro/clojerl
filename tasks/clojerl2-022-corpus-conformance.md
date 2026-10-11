# clojerl2-022 corpus 一致性测试体系

状态:未开始
里程碑:M4
依赖:clojerl2-021

## 目标

建立一致性测试体系:corpus.edn + JVM oracle + known-divergences 门控,全量进 CI。

## 设计依据

- [04](../designs/04-bootstrap-and-conformance.md) §5.1 — 架构:corpus/runner/EDN 规范化比较/oracle regen
- [04](../designs/04-bootstrap-and-conformance.md) §5.1 — known-divergences 门控:未登记失败红、已登记却通过也红
- [04](../designs/04-bootstrap-and-conformance.md) §5.2 — 分层接入:corpus 按 core 分层打标签,全量门控自 M4 起强制
- [00](../designs/00-overview.md) §4 D12 — 一致性测试决策
- [03](../designs/03-runtime-model.md) §11 — 全部分歧(NaN/码点下标/跨进程绑定与记忆化/STM)进注册表

## 工作内容

- [ ] 移植 jolt corpus.edn 格式:每条目 `{:expr :expected :tags}`;`expected` 为入库静态值
- [ ] runner:clojerl2 编译并求值条目 → 两边结果经 EDN 读回再比较;不可 EDN 化的值(fun、atom)按打印表示比较并在 schema 标注
- [ ] JVM Clojure oracle regen 模式:`make corpus-regen` 重新生成期望值,日常 CI 不依赖 JVM
- [ ] `known-divergences.edn` 门控:未登记 failure → CI 红;登记条目意外通过 → 同样红(防注册表腐烂);每条必须带原因且与 03/02 的分歧记录一致
- [ ] 次级来源接入:clojure-test-suite 按标签筛选转 corpus 条目;clojerl 1.0 测试套件作回归参考,语义分歧处登记而非盲目继承
- [ ] CI 全量门控:M4 起强制,无未登记分歧

## 验收标准

- CI 全量门控运行,`make certify` 模式绿
- 注册表每条目带原因与设计文档依据(03 §1.3/§3/§5.2/§7、02 §5 等)
- 基线通过率写入报告(按 core 分层标签分列)

## 结论

(完成后填写)
