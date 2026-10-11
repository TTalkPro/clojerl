# clojerl2-025 用户文档与 known-divergences 定稿

状态:已完成,一项除外(2026-10-12;真实用户试用待安排,见结论)
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

- [x] 用户文档:安装、REPL 使用、Erlang/OTP 互操作、rebar3 插件用法
- [x] 与 Clojure JVM 的差异文档:汇总全部已登记分歧——UTF-16 下标、char 码点、NaN/浮点键、跨进程绑定与记忆化、STM 缺席、hot-code 两版本重定义语义,每条给替代写法建议
- [x] known-divergences 全条目复核:每条有原因、有设计文档依据(节级引用)、与 runner 实测豁免数一致
- [ ] 邀请用户试用并记录走查反馈(安装→REPL→示例项目的完整路径)
- [x] 05/06 号文用户(IronScheme 文档受众)走查记录归档 —— 不适用:05 未立项,06/07 已作废(说明见走查记录)

## 验收标准

- 文档发布(仓库 docs/ 或站点)
- known-divergences 条目数与 runner 实测豁免数一致(CI 断言)
- 用户试用走查记录入库,阻塞级反馈有对应 issue 或修复

## 结论

- **用户文档** `clojerl2/docs/`:
  - `README.md`:现状,哪些能用、哪些没有、各自影响多少条 corpus 条目;
  - `getting-started.md`:安装、REPL、脚本、`-m`、源码路径;
  - `erlang-interop.md`:值对应表、atom 与关键字、字符串与字符列表的 unicode 转换、进程与消息、从 Erlang 调用 Clojure;
  - `rebar3.md`:项目设置、命令、缓存规则、限制;
  - `differences.md`:16 条差异,每条依次给出 JVM 行为、clojerl2 行为、替代写法和设计依据。
  文档里的 `;=>` 示例由 `make docs-check`(`test/docs-examples.sh`,已进 CI)逐条求值比对。
- **known-divergences 定稿**:从 13 条增加到 16 条。
  - 新增 `:string/code-point-indexing`、`:dynamic/per-process-bindings`、`:refs/no-stm`;
  - `:number/beam-semantics` 补上 0.0 与 -0.0、`##NaN`;
  - 每条都有 `:reason`、节级 `:design`(带 §)和 `:alternative`;替代写法里的代码逐条实测过,改正了 3 处。
- **"条目数与 runner 实测豁免数一致"(CI 断言)**,落实为三层:
  1. `clj2_divergence_evidence_tests` 每条差异对应一个测试,演示该行为;差异一旦消失,测试就失败,登记表必须同步更新。登记表 id 与测试一一对应,由 `clj2_divergences_tests:evidence_test` 断言。
  2. corpus 门控:引用差异 id 的失败条目必须是已登记的 id。16 条里有 9 条在 corpus 中有失败条目引用,共 311 条:`:exceptions/erlang-classes` 215、`:number/beam-semantics` 33、`:lazy-seq/no-chunking` 22、`:refs/no-stm` 15、`:protocols/type-designators` 11、`:fn/structural-identity` 6、`:number/no-ratio-arithmetic` 4、`:char/integer` 4、`:fn/arity-at-compile-time` 1。其余 7 条在 corpus 中观察不到(进程间行为、热代码、记忆上限等),只靠 evidence 测试佐证。
  3. `docs_test` 断言 `differences.md` 覆盖每一个 id。
- **corpus 重新归因**:
  - 原来的 `:pending/jvm-exception-classes` 其实就是已登记的设计决定 `:exceptions/erlang-classes`(designs/09 §3),该待办原因已删除;
  - 43 条元数编译错误里,42 条是 clojure.core 缺少该元数,改回 `:pending/missing-core-var`。不改的话会把真实缺口藏进"有意差异"里。
- **走查**(`clojerl2/docs/walkthrough/2026-10-12-docs-walkthrough.md`):从一份干净拷贝开始,照文档逐步执行,共 11 项发现。阻塞级和缺陷都已修复:
  - `print`/`println` 打印集合里的字符串带了引号,与 JVM 不符;
  - 字符串不支持 `nth`;
  - STM 是未解析符号,而不是设计要求的抛错;
  - Clojure 代码收不到消息:加了过渡方案 `clj2_proc:receive_any/0,2`,带模式匹配的 `receive*` 是后续工作。
  其余写进了文档:core 大多缺 docstring;Erlang map/tuple 在 Clojure 里不透明;`git_subdir` 写法未实测。corpus 通过数 1953 → 1955。
- **未完成:真实用户试用**。这需要邀请真实的人,不能由开发助手代替。走查记录里写了建议路径和记录格式;试用记录入库并处理阻塞级反馈之前,本项不算完成。
- **验证**:eunit 540 条、`make smoke`、`make docs-check`、`make example`、`make certify`(1955/4842,0 new / 0 stale)全部通过。
