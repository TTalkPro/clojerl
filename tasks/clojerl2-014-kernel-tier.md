# clojerl2-014 00-kernel 层划定

状态:未开始
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

- [ ] 从编译器源码(含 nanopass 框架)的实际依赖反推 kernel 最小函数集:序列基本操作、map/set 操作、symbol/keyword 构造、`defn`/`defmacro` 展开最小宏集
- [ ] `core/boot-order.edn`:显式声明各层文件列表与依赖层,不做隐式文件序
- [ ] lint 规则:kernel 只准依赖 Erlang 原语层;编译器源码只准依赖 kernel(对 kernel 之外 core 层的引用拒绝)
- [ ] kernel 层独立编译加载验证
- [ ] 划定结果回填 04 §6.1,关闭开放问题 O2

## 验收标准

- kernel 层可独立编译加载,编译器在其上完整运行
- lint 拒绝编译器源码对 kernel 之外 core 层的任何引用(CI 变红用例证明)
- 04 §6.1 已回填实测清单,O2 标记关闭

## 结论

(完成后填写)
