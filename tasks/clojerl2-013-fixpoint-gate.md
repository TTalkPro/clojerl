# clojerl2-013 字节级不动点门控

状态:已废弃(2026-10-11)——编译器改用 Erlang 写,不再自寄宿,无种子/不动点/子集纪律可言。见 [designs/09](../designs/09-erlang-hosted-compiler.md) §4。
里程碑:M3
依赖:clojerl2-012

## 目标

实现 `make selfhost`(stage2==stage3 规范化字节比较)与 `make remint` / `remint --check`,把"种子可信任因为它能再生自己"落成 CI 门。

## 设计依据

- [04](../designs/04-bootstrap-and-conformance.md) §4.1 — 不动点定义:normalize(stage2) == normalize(stage3)
- [04](../designs/04-bootstrap-and-conformance.md) §4.2 — normalization(剥 debug_info/Docs、chunk 排序)与确定性三风险点
- [04](../designs/04-bootstrap-and-conformance.md) §4.3 — selfhost/remint 命令与 jolt remint 陷阱
- [04](../designs/04-bootstrap-and-conformance.md) §9 风险 2/4 — 抖动假阳性禁止放宽口径;seed 过期双门
- [01](../designs/01-nanopass-pipeline.md) §4 — D5 纯函数约束是确定性穿线的前提

## 工作内容

- [ ] stage2/stage3 构建管线:`compile(seed, src)` → `compile(stage2, src)`
- [ ] normalization 工具:剥离 `debug_info`/`Docs` chunk、chunk 按名排序后逐文件字节比较;保守口径,不做进一步豁免
- [ ] emitter 确定性审计:map 按键序遍历(禁 `maps:to_list` 未定义序)、编译期计数器全部显式穿线
- [ ] `make remint`:迭代编译至收敛,覆盖 `bootstrap/seed/`,并校验新 seed 过 selfhost
- [ ] `remint --check` CI 门:重算 manifest 源哈希,与入库 manifest 不一致即失败
- [ ] 编译器启动打印自身 seed 的 git 提交号

## 验收标准

- CI 上 `make selfhost` 绿(stage2==stage3,同一 OTP 版本内)
- `remint --check` 对过期 seed 变红(jolt remint 陷阱防线生效)

## 结论

(完成后填写)
