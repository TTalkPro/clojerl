# clojerl2-010 端到端管线打通(M2 验收)

状态:未开始
里程碑:M2
依赖:clojerl2-008, clojerl2-009

## 目标

端到端打通 `(fn [x] (+ x 1))` 级程序:read → pass 链 → emit → `compile:forms` → beam → ERTS 执行,满足 04 §7 的 M2 判据。

## 设计依据

- [04](../designs/04-bootstrap-and-conformance.md) §7 — M2 客观验收判据(e2e 返回 2,CI 可复现)
- [00](../designs/00-overview.md) §5 — 总体架构三条数据契约边界
- [00](../designs/00-overview.md) §7 — M2 里程碑范围
- [03](../designs/03-runtime-model.md) §8 — primitives 表(最小原语集来源)
- [02](../designs/02-beam-backend.md) §5 — 单轨求值路径(beam → `code:load_binary` → 执行)

## 工作内容

- [ ] e2e 测试驱动夹具:源文本 → 编译 → 加载 → 调用 → 断言返回值
- [ ] 最小原语集:`erlang/+` 等算术 primop,建立 primitives 表雏形(03 §8)
- [ ] 整条管线串联排错:reader → parse → … → emit-lower → emit → beam
- [ ] CI 接入:固定 OTP 版本(02 §7 风险 4:OTP 27+),保证可复现

## 验收标准

- 断言 `(f 1) => 2` 的 e2e 测试进 CI 且绿
- 04 §7 的 M2 判据逐字满足:reader → pass 链 → absform → `compile:forms` → beam → ERTS 执行返回 2(对输入 1),全程 CI 可复现

## 结论

(完成后填写)
