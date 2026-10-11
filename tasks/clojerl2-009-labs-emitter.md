# clojerl2-009 Labs 文法与 absform 发射器

状态:未开始
里程碑:M2
依赖:clojerl2-005, clojerl2-006

## 目标

定义 Labs(与 absform 一一对应的末端 IR)并实现纯序列化发射器 emit:Labs → absform 项 → `compile:forms/2`,零语义决策。

## 设计依据

- [01](../designs/01-nanopass-pipeline.md) §1.7 — Labs 边界:emit-lower 之后只剩结构翻译
- [02](../designs/02-beam-backend.md) §2 — 发射器架构与纯函数性质
- [02](../designs/02-beam-backend.md) §3.1 — 名称改编表(`? * ! < > = + - / .` 转义)
- [02](../designs/02-beam-backend.md) §3.2 — 字面量 `erl_parse:abstract/1` 技巧
- [02](../designs/02-beam-backend.md) §3.3-3.4 — 模块布局与 `__ns_init__/0` on_load 骨架
- [02](../designs/02-beam-backend.md) §4 — ANNO 纪律,禁止 `erl_anno:new(0)` 兜底

## 工作内容

- [ ] Labs `define-language`:文法与 absform 一一对应;guard-safe 子语言为独立非终结符(02 §7 风险 1)
- [ ] emit/1 纯序列化器:Labs 树进、Erlang 项出,不做任何"聪明事"
- [ ] 名称改编表实现(02 §3.1 的编码规则与 arity 后缀、`__lambda_N` 私有命名)
- [ ] 字面量两路径:编译期已知 → `erl_parse:abstract/1` 构造树;含非字面量子项 → 运行时构造函数调用
- [ ] 模块布局与 `-on_load(__ns_init__/0)` 骨架生成
- [ ] ANNO 纪律落地:每个节点带 `erl_anno:new({Line,Col})`;lint 禁止 `erl_anno:new(0)`
- [ ] `compile:forms/2` 集成(含 debug_info 选项)

## 验收标准

- emit 输出经 `compile:forms` 成功产出 beam
- Labs 每个节点的源位置出现在 beam `Line` chunk
- 发射器纯函数性测试:同一 Labs 两次 emit 字节一致

## 结论

(完成后填写)
