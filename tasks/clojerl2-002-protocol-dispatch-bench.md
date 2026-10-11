# clojerl2-002 协议分派基准

状态:已完成
里程碑:M0
依赖:无

## 目标

对 [03](../designs/03-runtime-model.md) §4.2 指定的协议分派三方案做基准:直接远程调用 / impl 模块 ETS 存在性缓存 + apply / ETS fun 表,量化相对开销。

## 设计依据

- [03](../designs/03-runtime-model.md) §4.1 — impl 模块 + 存在性缓存的分派形状
- [03](../designs/03-runtime-model.md) §4.2 — 三方案对比表与 spike 判据(不低于直接调用的 1/3 即采纳)
- [00](../designs/00-overview.md) §6 — 风险 2:协议分派性能

## 工作内容

- [ ] 搭建 100 协议 × 50 类型规模的分派基准(协议模块、`Protocol__Type` impl 模块、`Protocol__Default` 模块的程序化生成)
- [ ] 三组分派路径:直接远程调用、`clj_rt_protocol:impl/2` ETS 读 + apply、ETS fun 表调用
- [ ] 测量吞吐与延迟,含存在性缓存命中/未命中(负缓存)两种情形
- [ ] 按判据判定:impl 模块方案不低于直接调用的 1/3 即采纳,否则退回 ETS fun 表并接受闭包拷贝代价

## 验收标准

- 基准代码与报告入库
- 报告给出三方案在同一规模下的可比较数据
- 按 03 §4.2 判据固化 03 §4 的最终方案选择(采纳或退回,写入报告结论)

## 结论

已完成(OTP 28)。S2(impl 模块 + ETS 存在性缓存 + apply/3)/ S1(直接远程调用) = 0.607,
远超 03 §4.2 阈值 0.333 → **采纳 S2,不退回 ETS fun 表**。S3 最快形态(零环境外部 fun)虽快 ~21%,
但闭包 fun 形态反而比 S2 慢,且判据允许该档差距。复现验证:1M/3/100K 参数下 S2/S1=0.6073,
与报告 0.6082 一致(噪声内)。
报告:[../clojerl2/notes/spike-002-protocol-dispatch.md](../clojerl2/notes/spike-002-protocol-dispatch.md)。
