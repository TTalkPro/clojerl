# clojerl2-028 boot 库移植(三项修正落地)

状态:未开始
里程碑:M0.5(Scheme 金属层)
依赖:026, 027

## 目标

skeg `boot/*.sls`(14.9K 行)在 stage0 上编译通过;三项语言修正(call-with-return / try·catch·finally / nil)落到库层。

## 设计依据

- [07](../designs/07-scheme-layer.md) §2(修正落点)/§5(自举梯子 T2)
- `~/workspace/skeg/Skeg/src/scheme/boot/`(复用源)
- `~/workspace/skeg/RESUME.md`(guard 双形态、try 宏展开技巧、specials 清单——IronScheme 上已实测)

## 工作内容

- [ ] boot 源码 vendor 入库(`clojerl2/scheme/boot/`,保留版权头,登记 skeg 来源提交号)
- [ ] `call-with-return` 特殊原语登记 + `(rnrs control)` 子集导出
- [ ] `try`/`catch`/`finally` 宏(多 catch 递归展开、不匹配重抛、finally 与 catch 组合)
- [ ] `guard` 双形态宏(skeg core.sls guard-macro 移植:条件对象形态 + Erlang 异常形态 + 重抛)
- [ ] `nil` 常量进 reader 与自求值表(库代码不用,只为 Clojure 桥)
- [ ] `conditions.sls`/`exceptions.sls` 与 `{scheme_exception}`/`{erlang_exception}` 的互通层
- [ ] r5rs.sls / compat.sls 的裁剪对照表(dynamic-wind 删除点逐条核对 skeg RESUME 清单)

## 验收标准

- T2 梯子:`internal.sls` → `core.sls`(expander 核心)经 stage0 编译出 .beam 并可加载
- try/guard/call-with-return 行为单测(含 skeg RESUME"验证过的行为"清单逐条复验)
- 已知裁剪清单入库(notes/boot-port-notes.md)

## 结论

(完成后填写)
