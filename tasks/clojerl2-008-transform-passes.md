# clojerl2-008 变换 pass 组

状态:未开始
里程碑:M2
依赖:clojerl2-007

## 目标

实现 01 §5 #3-9 的七条变换/分析 pass,每条由一句话规格展开为完整规格,输入输出语言对经 spec 校验。

## 设计依据

- [01](../designs/01-nanopass-pipeline.md) §5 — pass 清单 #3-9 的一句话规格
- [01](../designs/01-nanopass-pipeline.md) §1.4-1.6 — L2a/L2/L3/L4/L5 文法定义
- [01](../designs/01-nanopass-pipeline.md) §6.3 — letfn* 互递归的 SCC 分类降低
- [01](../designs/01-nanopass-pipeline.md) §6.4 — ANF 服务 Erlang 子句守卫约束的理由
- [01](../designs/01-nanopass-pipeline.md) §2 — 文法校验在 pass 边界抓 bug 的完整 nanopass 理由

## 工作内容

- [ ] expand-destructuring(L1→L2a):vector/map 模式消解为 `primop` 取件 + `let*` 链
- [ ] normalize-arities(L2a→L2):多 arity `fn*` → 每 arity 一函数 + 显式 dispatcher 节点;变参 → 定长 + 集 list 前奏
- [ ] validate-recur(L2→L2,分析):尾位置标注遍历,违规报带源位置的编译错误,不改树
- [ ] lower-loop(L2→L3):`loop*` → 命名局部递归 fun,`recur` → 自尾调用
- [ ] lower-letfn(L2→L3):绑定图 SCC 分类——自递归 → named-fun;互递归 → 模块私有生成函数 + `modcall`(01 §6.3)
- [ ] normalize-anf(L3→L4):复杂子表达式经 `let*` 提取;重点保证 case/receive 子句模式与守卫无任意调用
- [ ] lower-case(L4→L5):`case*` 常量分派 → 字面量模式匹配树
- [ ] 每 pass 先写完整规格(展开 01 §5 一句话),再实现

## 验收标准

- 每条 pass 单测齐备,输入输出语言经 spec 校验
- `recur` 出现在非尾位置时报带源位置的编译错误
- `letfn*` 互递归用例正确降低为生成函数 + `modcall`

## 结论

(完成后填写)
