# clojerl2-026 Scheme 原语层(Erlang)

状态:未开始
里程碑:M0.5(Scheme 金属层)
依赖:无

## 目标

把 skeg `Skeg.Core`(C#,11.7K 行)的 boot 库实际依赖子集移植为 Erlang 原语模块 `sk_*`,承载金属层的全部运行时服务。值表示按 [07](../designs/07-scheme-layer.md) §3。

## 设计依据

- [07](../designs/07-scheme-layer.md) §2/§3(值表示、可变单元裁决、异常映射)
- `~/workspace/skeg/Skeg/src/Skeg.Core/`(移植蓝本)
- `~/workspace/skeg/Skeg/src/scheme/boot/primitives.ss`(原语清单参考;我们按需自列)

## 工作内容

- [ ] 值构造与谓词:pair/list/symbol/boolean/integer/float/char/string/vector/bytevector/procedure/record 谓词与访问器
- [ ] **可变单元(ets 承载)**:string/vector/bytevector 的 set! 族、box、hashtable(eq?)——统一 `{Type, N, Tab, Key}` 形状与 ets 行读写
- [ ] 数值:fixnum/bignum(原生)/flonum;fixnum 边界、`fx*`/`fl*` 谓词族;ratnum/complex 视 029 实测决定(登记项)
- [ ] 多值:`values` → `{values, [V…]}`、`call-with-values`
- [ ] 异常与条件:`raise`/`raise-continuable`、`{scheme_exception, Cond}` 包装、Erlang 异常捕获为 `{erlang_exception, Class, Reason, Stack}`、`guard`/`try` 的运行时支撑原语、`call-with-return`(Tag 防穿透)
- [ ] parameter:`make-parameter`/`parameterize`(pdict 栈)
- [ ] gensym:全局计数器 + `--deterministic` 语义
- [ ] IO/文件子集:`file:*` 映射、字符串端口(iodata accumulator)、format/printf/pretty-print 的底层
- [ ] 全局值槽:REPL 用的 symbol-value 槽(pdict `{skglobal, Sym}`)

## 验收标准

- 原语单测全绿(每族至少含异常路径)
- boot 库编译所需原语清单与 primitives.ss 对齐的缺口清单入库
- `(call-with-return …)` 逃逸 + 无关 throw 穿透不误捕获,有专项单测
- `nil` 与 `'()` 区分单测

## 结论

(完成后填写)
