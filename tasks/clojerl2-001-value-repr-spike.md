# clojerl2-001 值表示 spike

状态:已完成
里程碑:M0
依赖:无

## 目标

验证 [03](../designs/03-runtime-model.md) §1 的值表示选择:打标元组 `{Tag, Meta, Data}` vs clojerl 1.0 的 map+`?TYPE` 键,在协议分派热路径(按标签模式匹配)上的性能差。

## 设计依据

- [03](../designs/03-runtime-model.md) §1.4 — 打标元组 vs map+`?TYPE` 的三条否决理由,需数据确认
- [03](../designs/03-runtime-model.md) §1.2 — keyword 的 atom 策略与 `{kw_dyn, Bin}` 回退
- [00](../designs/00-overview.md) §7 — M0 spike 范围含值表示

## 工作内容

- [ ] Erlang 手写两种值表示:三槽打标元组与 clojerl 1.0 式 `#{?TYPE => ...}` map
- [ ] 基准四项:构造、解构、标签判定(协议分派热路径的等价物)、`with-meta` 拷贝
- [ ] keyword 的 atom 策略原型:`binary_to_existing_atom` 命中/未命中两路径 + `{kw_dyn, Bin}` 回退的相等性判定成本
- [ ] 覆盖 §1.1 总表中的代表类型:vector / hashmap / hashset / record
- [ ] 报告提交入库(notes/ 或 bench/)

## 验收标准

- 基准报告入库,含原始数据与运行环境说明
- 按数据选定值表示,报告含明确结论(采纳或调整 03 §1 的选定)
- keyword atom 策略原型可运行,回退路径行为与 03 §1.2 一致

## 结论

已完成(OTP 28,i9-13900H)。采纳 A=`{Tag,Meta,Data}`(D8 维持):dispatch 1.31x、tag 1.51x、
get 1.36x、with-meta 净值 2.71x、construct 净值 1.89x;唯一回退 `=` 0.86-0.92x(非热路径,可接受)。
keyword 原型确认 `{kw_dyn,Bin}` 与 atom 形态 map key 不互通 → reader 改为 keyword=冒号前缀 atom
(见 notes/reader-format.md),`binary_to_existing_atom` 回退方案放弃。agent 初版 escript 有 4 类 bug
(空输入死循环、refs 列表不复位、eq 循环第二列表覆盖、~s 打中文崩溃)已修复;迭代量下调 20x。
报告:[../clojerl2/notes/spike-001-value-repr.md](../clojerl2/notes/spike-001-value-repr.md)。
