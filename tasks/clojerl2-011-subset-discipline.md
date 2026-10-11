# clojerl2-011 编译器源码子集纪律落地

状态:未开始
里程碑:M3
依赖:clojerl2-010

## 目标

落地 04 §2.4 的子集纪律:静态 lint 保证编译器与框架源码始终可被 stage0(clojerl 1.0)编译,封死种子血统耦合。

## 设计依据

- [04](../designs/04-bootstrap-and-conformance.md) §2.4 — 子集纪律的允许/禁止特性表与执行机制
- [04](../designs/04-bootstrap-and-conformance.md) §2.2 — 方案 (b):子集 = clojerl 1.0 已支持特性集
- [04](../designs/04-bootstrap-and-conformance.md) §9 风险 1 — 子集边界蠕变的双门缓解
- [00](../designs/00-overview.md) §6 风险 1 — 自寄宿冷启动的子集大小约束

## 工作内容

- [ ] `script/check-subset`:静态 lint,白名单特殊形式 + 黑名单符号线查,覆盖 04 §2.4 表
- [ ] lint 作用域:全部编译器源码与 nanopass 框架源码(00-kernel 消费者)
- [ ] CI 每提交运行 check-subset
- [ ] CONTRIBUTING 写入约定:子集边界变更必须与 04 号文同 PR 修改

## 验收标准

- lint 覆盖全部编译器与框架源码,无豁免清单外漏网
- 人为引入越界特性(如 `eval`、clojerl 1.0 独有 BEAM 扩展特殊形式)时 CI 变红,有测试用例证明

## 结论

(完成后填写)
