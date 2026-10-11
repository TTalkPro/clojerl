# clojerl2-005 nanopass 框架最小版

状态:已废弃(2026-10-11)——按 cleat 路线改为自研 Scheme 金属层 + 复用 nanopass-framework-scheme,本任务由 [clojerl2-031](clojerl2-031-nanopass-beam.md) 取代。设计变更见 [designs/07](../designs/07-scheme-layer.md) §0。
里程碑:M1
依赖:无

## 目标

nanopass 框架最小版([01](../designs/01-nanopass-pipeline.md) §3 与 §7 风险 1):够编译器自身冷启动使用即可,补齐工作归 clojerl2-006。

## 设计依据

- [01](../designs/01-nanopass-pipeline.md) §3 — D3 框架形态:define-language / define-pass / map 节点 + spec 校验 / 模板构造器
- [01](../designs/01-nanopass-pipeline.md) §7 风险 1 — M1 先写最小版(无 extends、手工穿通),框架自举后再补齐
- [00](../designs/00-overview.md) §7 — M1 范围:nanopass 框架骨架

## 工作内容

- [ ] `define-language`(无 `extends`):terminals/nonterminals 声明,产生式编译为 spec
- [ ] `define-pass`:手工穿通,模式 → 模板
- [ ] IR = map 节点(`{:op ...}` 形态)+ spec 校验
- [ ] 模板构造器:输出语言的构造器语法
- [ ] `define-pass` 展开期静态检查:模式键属于 Lin 的 `:op` 集;模板产出的节点键属于 Lout(§3 的双层防线之编译期层)

## 验收标准

- 在一个玩具语言上定义并运行一对 pass(如常量折叠)的演示 + 测试通过
- spec 校验能拒绝畸形 IR(运行期层防线生效)
- 展开期静态检查对越界模式键/模板键报错

## 结论

(完成后填写)
