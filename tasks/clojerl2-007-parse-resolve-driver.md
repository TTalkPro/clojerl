# clojerl2-007 parse/resolve 与 form-at-a-time 驱动器

状态:未开始
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

- [ ] parse(Lcore→L0):特殊形式表落地为 `:op` 节点;未知 list 头归 `invoke`;全表覆盖 01 §1.2 产生式
- [ ] resolve-symbols(L0→L1):词法作用域栈 + env 显式参数穿线;局部绑定 → `uid`,其余 → `varref`;未解析符号带位置报错,不留 fake_fun 式补救
- [ ] 驱动器:逐顶层 form 读入;宏展开(effectful,走 02 §5 单轨编译执行)在驱动层;展开结果进入纯 pass 链
- [ ] `def`/`in-ns` 的 env 增量由 pass 返回,驱动提交到运行时 NS 表(03 §2)

## 验收标准

- 特殊形式全集落地,L0 spec 校验通过
- env 纯函数性测试:同一 env+form 两次编译产出相同 IR
- 宏展开边界测试:宏对后续 form 立即可见(04 §6.2)

## 结论

(完成后填写)
