# clojerl2-007 parse/resolve 与 form-at-a-time 驱动器

状态:已完成(2026-10-11)
里程碑:M2
依赖:clojerl2-004, clojerl2-005

## 目标

实现管线头两条 pass(parse、resolve-symbols)与顶层驱动器,落实 D5 纯函数纪律:pass 链只过数据,宏展开与 NS 提交是驱动层的效果边界。

## 设计依据

- [01](../designs/01-nanopass-pipeline.md) §5 #1-2 — parse/resolve-symbols 的一句话规格
- [01](../designs/01-nanopass-pipeline.md) §4 — D5:env 显式穿线,`def`/`in-ns` 效应以返回值回传
- [01](../designs/01-nanopass-pipeline.md) §1.2-1.3 — L0/L1 文法定义
- [04](../designs/04-bootstrap-and-conformance.md) §6.2 — form-at-a-time 驱动与宏自举边界
- [00](../designs/00-overview.md) §2.6 — fake_fun 补救被废除的教训依据

## 工作内容

- [x] parse(Lcore→L0):特殊形式落地为节点;未知 list 头归 `invoke`。01 §1.2 中 `case*`、互操作、`deftype*`/`reify*`、`receive*`、`var`、`set!` 仍报 unsupported,归后续任务
- [x] resolve-symbols(L0→L1):词法作用域栈 + env 显式参数穿线;局部绑定 → `uid`,其余 → `varref`;未解析符号带位置报错,不留 fake_fun 式补救
- [x] 驱动器:逐顶层 form 读入;宏展开(effectful)在驱动层,以能力注入 parse;同文件宏经编译期段模块可用
- [x] `def` 的 env 增量由 declare pass 返回(var 表),运行时 NS 表由模块 on_load 提交(03 §2,015);`in-ns` 不做(NS = 编译单元)

## 验收标准

- 特殊形式全集落地,L0 spec 校验通过
- env 纯函数性测试:同一 env+form 两次编译产出相同 IR
- 宏展开边界测试:宏对后续 form 立即可见(04 §6.2)

## 结论

2026-10-11 完成,机制见 [designs/09](../designs/09-erlang-hosted-compiler.md) §4.1。

- 代码:`clj2_p_parse`(宏展开、syntax-quote、`defmacro`、集合字面量、`#()`)、`clj2_compiler`(form-at-a-time 驱动、编译期段模块、展开能力、`macroexpand_1/2`)、`clj2_form`(宏边界的 form ↔ 值)、`clj2_coll`(D8 集合的最小构造)。
- 验收:
  - 宏对后续 form 立即可见:`clj2_macro_tests:same_ns_test_/0`(同文件 `defmacro` 后立即使用、宏在展开期调用前面定义的函数、定义宏的宏);
  - 纯函数性:同一源码两次 `compile_ns` 产出逐字节相同的 .beam(`clj2_macro_tests:deterministic_test/0`,含 gensym);
  - L0 校验:`clj2_np:run` 每个 pass 后整树校验,全部测试默认开启。
- 局限:symbol 是 atom、带不了元数据,所以 `defmacro` 暂为内核形式;`ns` 也仍由 parse 直接处理。
