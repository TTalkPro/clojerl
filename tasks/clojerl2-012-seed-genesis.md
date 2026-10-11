# clojerl2-012 首枚种子生成与入库

状态:未开始
里程碑:M3
依赖:clojerl2-011, clojerl2-014

## 目标

用 clojerl 1.0 作 stage0 宿主编译编译器源码 + 00-kernel,产出 `bootstrap/seed/beam/*.beam` + `manifest.edn` 并提交入库,fresh clone 即可启动。

## 设计依据

- [04](../designs/04-bootstrap-and-conformance.md) §2 — stage0 来源决策:clojerl 1.0 首选,Erlang 直译为回退
- [04](../designs/04-bootstrap-and-conformance.md) §3 — 种子布局、manifest 字段、fresh clone 加载路径
- [04](../designs/04-bootstrap-and-conformance.md) §6.2 — form-at-a-time 对 stage0 宿主的要求(1.0 满足)
- [00](../designs/00-overview.md) §4 D2 — 种子入库、自我再生、stage0 退场

## 工作内容

- [ ] 种子构建脚本:clojerl 1.0 编译编译器源码(子集内)+ 00-kernel → beam 集
- [ ] manifest.edn 生成:源文件 sha256、stage0 版本、git 提交号作 `:built-at`(不用墙钟,04 §3)
- [ ] fresh clone 加载路径:rebar3 pre-compile hook 检测 `bootstrap/seed/beam` 加入 code path
- [ ] 无 seed 时的报错与 `make remint` 指引(04 §3 回退路径)
- [ ] 提交 seed 入库;不提交含绝对路径/时间戳的中间产物

## 验收标准

- 干净 clone 仅靠入库 seed 即可启动 clojerl2 编译器并完成源码重建第一步
- manifest 字段与 04 §3 示意完全一致(`:clojerl2-version`/`:stage0`/`:sources`/`:core-layers`/`:built-at`)

## 结论

(完成后填写)
