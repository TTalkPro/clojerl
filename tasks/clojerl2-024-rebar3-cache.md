# clojerl2-024 rebar3 插件与编译缓存

状态:未开始
里程碑:M5
依赖:clojerl2-023

## 目标

实现 rebar3 插件与编译缓存:缓存键覆盖源、编译器版本、OTP 主版本与选项指纹;provider 提供 compile/repl/clean。

## 设计依据

- [02](../designs/02-beam-backend.md) §6 — 缓存键:`sha256(源文本) + 编译器版本 + OTP 主版本 + 编译选项指纹`;产物为 .beam 二进制,命中跳过整条管线
- [02](../designs/02-beam-backend.md) §6 — 粒度 NS 级;extend 只新增 impl 模块,不触发 NS 重编译(D9 红利)
- [02](../designs/02-beam-backend.md) §6 — 缓存目录 `_build/<profile>/clojerl2_cache/`;结构与 `rebar3_clojerl` 对齐
- [04](../designs/04-bootstrap-and-conformance.md) §7 M5 — 判据:插件可对示例项目完成 compile/repl;缓存命中下二次构建 < 首次 20%

## 工作内容

- [ ] 缓存实现:键 = sha256(源)+ 编译器版本 + OTP 主版本 + 选项指纹;命中即写回 .beam 产物,跳过管线
- [ ] provider `compile`:编译前查缓存,miss 才调编译器
- [ ] provider `repl`:启动带项目 code path 的 clojerl2 REPL
- [ ] provider `clean`:清缓存目录
- [ ] 插件结构与命令面与 `rebar3_clojerl` 对齐,降低用户迁移成本
- [ ] 示例项目(含多 NS 依赖)作为验收载体

## 验收标准

- 示例项目 `rebar3 clojerl2 compile` / `rebar3 clojerl2 repl` 可用
- 缓存命中下二次构建时间 < 首次的 20%(M5 判据,实测数据写入结论)
- 改单个 NS 只重编译该 NS;extend 新类型不触发已有 NS 重编译

## 结论

(完成后填写)
