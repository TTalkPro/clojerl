# clojerl2-017 多方法

状态:未开始
里程碑:M4
依赖:clojerl2-015

## 目标

实现多方法:保留 clojerl 1.0 的"每多方法一个分派模块"模式(`Ns.name__dispatch__`),生成方式从 cerl 改为直出 absform。

## 设计依据

- [03](../designs/03-runtime-model.md) §5.1 — 分派模块模式保留,`defmethod` 时重生成并热加载
- [03](../designs/03-runtime-model.md) §5.1 — `derive`/`isa?`/prefer 存 ETS 表,不碰全局状态机
- [02](../designs/02-beam-backend.md) §2 — 分派模块与其他编译产物同一 absform 发射路径,消除 cerl 依赖
- [02](../designs/02-beam-backend.md) §5 — BEAM 两版本热替换语义

## 工作内容

- [ ] 分派模块(`Ns.name__dispatch__`)生成:`defmethod` 时按当前方法表重新生成并经 absform 路径热加载
- [ ] `derive`/`isa?`/`prefer!` 的 ETS 表:祖先链与偏好查询;`defmethod` 只改表 + 重发分派模块
- [ ] dispatch fn 值形态:`dispatch/1` 的 fun;分派结果查方法表,未命中走 `:default`
- [ ] 层次查询的缓存与失效(derive 变更后 isa? 缓存刷新)
- [ ] pass 侧:`defmulti`/`defmethod` 的展开与运行时 API 对接

## 验收标准

- `defmethod` 增量生效:新增方法后新调用立即可见
- 两版本语义测试:进行中调用旧分派模块的进程不受影响,完成后再调用走新表
- 层次正确性测试:`derive` 多级祖先、`isa?`、冲突时 `prefer!` 生效

## 结论

(完成后填写)
