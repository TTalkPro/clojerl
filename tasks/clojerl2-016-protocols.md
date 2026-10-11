# clojerl2-016 协议运行时

状态:未开始
里程碑:M4
依赖:clojerl2-015, clojerl2-002

## 目标

实现协议运行时:impl 模块(`Protocol__Type`)+ ETS 存在性缓存分派,`extend` 只编译新 impl 模块,协议模块与其他 impl 模块一律不动。

## 设计依据

- [03](../designs/03-runtime-model.md) §4.1 — 分派形状:`clj_rt_protocol:impl/2` + `apply`,Default 回退
- [03](../designs/03-runtime-model.md) §4.2 — 方案取舍与退回 ETS fun 表的备选
- [03](../designs/03-runtime-model.md) §9 未决问题 3 — 负缓存:impl 模块在负缓存写入之后才加载的场景,加载时主动清负缓存
- [02](../designs/02-beam-backend.md) §2 — impl 模块经同一 absform 路径发射
- [00](../designs/00-overview.md) §6 风险 2 — 分派性能基准判据(不低于直接调用的 1/3)

## 工作内容

- [ ] `defprotocol`:生成协议模块(方法元数据、默认实现引用)与 `Protocol__Default` impl 模块
- [ ] `extend-type`/`extend-protocol`/`deftype`/`defrecord` 的 pass 侧与运行时侧:只编译新 `Protocol__Type` impl 模块并 `code:load_binary`
- [ ] impl 模块经 absform 路径发射,与其他编译产物同一管线
- [ ] 存在性缓存:ETS(key = `{Protocol, TypeTag}`),未命中走 `code:ensure_loaded` 探测并回填,含负缓存
- [ ] 负缓存失效:impl 模块加载时主动清对应负缓存(03 §9 未决问题 3,正确性需测试验证)
- [ ] `satisfies?` = 存在性探测,同走缓存
- [ ] 若 clojerl2-002 基准判据未通过,按 03 §4.2 退回 ETS fun 表方案并接受闭包拷贝与热升级损失

## 验收标准

- extend N 个类型后协议模块零重编译:与 clojerl 1.0 的 O(n²) 累积重编译对比,extend 成本为 O(本类型方法数)
- `satisfies?`/分派正确性测试,含 Default 回退路径
- REPL 交错加载场景测试:负缓存写入后再 extend,`satisfies?` 立即转真

## 结论

(完成后填写)
