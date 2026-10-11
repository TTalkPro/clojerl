# clojerl2-029 expander 上线(syntax-case + 库系统)

状态:未开始
里程碑:M0.5(Scheme 金属层)
依赖:028

## 目标

skeg `boot/expander/`(6,081 行,纯 Scheme)在金属层上全量运行:syntax-case 宏、`define-record-type`、R6RS `library` 系统。T3 之后所有 boot 库改经 expander 编译。

## 设计依据

- [07](../designs/07-scheme-layer.md) §5(梯子 T3)/§9(风险 1/2)
- `~/workspace/skeg/Skeg/src/scheme/boot/expander/`(core/builders/internal/library-manager/main)
- `~/workspace/skeg/Skeg/src/scheme/boot/seed-buildscript.sps`(编译顺序照搬)

## 工作内容

- [ ] T3:conditions/records/enums/hashtables/io/unicode 等 boot 库全部经 expander 编译
- [ ] 库系统:library-manager、`.ifc` 接口文件语义(skeg iron-034e:ifc 是编译器输入数据——保留,写盘路径适配 BEAM 产物目录)
- [ ] syntax-object 与源位置:与 stage0 的 annotated-call 位置贯通
- [ ] 数值塔实测:expander 实际触达的 ratnum/complex 用例统计 → 决定 026 的数值裁剪项
- [ ] 可变性压实:vector-set!/string-set!/hashtable 在 expander 真实用例下的别名语义验证(风险 1)
- [ ] `(skeg compiler)` 之前置:确认 expander 能展开 skeg 编译器库(为 031 铺路)

## 验收标准

- T3 梯子完成:boot 全部 .sls 经 expander 编译出 .beam
- r6rs 套件中 syntax-case.sls / records / conditions 相关用例通过(030 门控的子集)
- 数值塔与可变性实测记录入库(notes/expander-bringup.md)

## 结论

(完成后填写)
