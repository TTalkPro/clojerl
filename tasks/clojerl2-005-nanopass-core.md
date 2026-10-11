# clojerl2-005 nanopass 框架最小版

状态:已完成(2026-10-11,改为 Erlang 实现)——宿主由 Clojure 改为 Erlang,见 [designs/09](../designs/09-erlang-hosted-compiler.md) §1。下方工作内容中 Clojure 宏形态的条目作废,对应物见结论。
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

2026-10-11 以 Erlang 实现完成([designs/09](../designs/09-erlang-hosted-compiler.md) §1):

- `clojerl2/src/erl/clj2_lang.erl`:语言即数据(终结符谓词 + 非终结符 `#{Op => [FieldKind]}`),已含 `extends`。
- `clojerl2/src/erl/clj2_np.erl`:`descend/4`、`mapfold/4`(自动穿通)、`fold/4`、`children/2`、`check/2`(带路径的整树校验)、`run/3`(pipeline 驱动,每个 pass 边界校验 + trace)。
- IR 为 absform 形状的元组 `{Op, Anno, ...}`(不是原设计的 map 节点),便于函数头模式匹配,Anno 直通 BEAM。
- "展开期静态检查"不做(Erlang 无宏层),由运行期每个 pass 边界的整树校验替代。
- 测试:`clj2_compiler_tests` 的 `lang_extends_test`、`check_accepts_and_rejects_test`、`descend_auto_passthrough_test`、`pipeline_checks_every_boundary_test`。
