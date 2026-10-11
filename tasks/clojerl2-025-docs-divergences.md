# clojerl2-025 用户文档与 known-divergences 定稿

状态:未开始
里程碑:M5
依赖:clojerl2-022, clojerl2-024

## 目标

发布用户文档并把 known-divergences 定稿:方言定位(D1)的对外面,全部已登记分歧有原因、有设计依据。

## 设计依据

- [00](../designs/00-overview.md) §1 D1 — 方言定位:分歧诚实登记,不背兼容包袱
- [03](../designs/03-runtime-model.md) §7/§1.3 — 字符串 UTF-16 下标分歧、char 码点分歧、NaN/浮点键分歧
- [03](../designs/03-runtime-model.md) §3/§5.3 — 跨进程动态绑定与记忆化分歧
- [03](../designs/03-runtime-model.md) §5.2 — STM 缺席(诚实 raise)
- [02](../designs/02-beam-backend.md) §5 — 热代码两版本重定义语义
- [04](../designs/04-bootstrap-and-conformance.md) §5.1 — 注册表每条目必须带原因且与方言定位一致

## 工作内容

- [ ] 用户文档:安装、REPL 使用、Erlang/OTP 互操作、rebar3 插件用法
- [ ] 与 Clojure JVM 的差异文档:汇总全部已登记分歧——UTF-16 下标、char 码点、NaN/浮点键、跨进程绑定与记忆化、STM 缺席、hot-code 两版本重定义语义,每条给替代写法建议
- [ ] known-divergences 全条目复核:每条有原因、有设计文档依据(节级引用)、与 runner 实测豁免数一致
- [ ] 邀请用户试用并记录走查反馈(安装→REPL→示例项目的完整路径)
- [ ] 05/06 号文用户(IronScheme 文档受众)走查记录归档

## 验收标准

- 文档发布(仓库 docs/ 或站点)
- known-divergences 条目数与 runner 实测豁免数一致(CI 断言)
- 用户试用走查记录入库,阻塞级反馈有对应 issue 或修复

## 结论

(完成后填写)
