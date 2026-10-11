# clojerl2-020 字符串与 IO 原语层

状态:未开始
里程碑:M4
依赖:clojerl2-010

## 目标

实现字符串与 IO 原语层:string = UTF-8 binary,IO 走 Erlang io 协议,`*out*`/`*in*`/`*err*` 动态 var 对接。

## 设计依据

- [03](../designs/03-runtime-model.md) §7 — string = binary(UTF-8);char = integer 码点
- [03](../designs/03-runtime-model.md) §7 — 下标 O(n) 分歧:按码点 `char_at`,文档劝用 seq/reduce 遍历
- [03](../designs/03-runtime-model.md) §7 — 拼接走 iolist 累积,避免 O(n²) 拷贝
- [03](../designs/03-runtime-model.md) §8 — 运行时第 0 层:字符串原语与 IO(走 Erlang io 协议)属"必须接触 BEAM 机制"的部分
- [03](../designs/03-runtime-model.md) §1.3 — char 与 JVM UTF-16 的分歧登记

## 工作内容

- [ ] 字符串原语:`char_at`(按码点,O(n))、iolist 拼接(`str` 多参直接产 iolist)、`subs`、比较
- [ ] `pr-str`/`prn`/`println` 族的第 0 层部分(打印协议本身的 Clojure 侧归 04 §6.1 的 03-print 层)
- [ ] `*out*`/`*in*`/`*err*` 动态 var 与 Erlang io 协议对接:`binding [*out* ...]` 重定向生效
- [ ] char = integer 码点的字面量与谓词支持(surrogate pair 即单码点)
- [ ] known-divergences 条目:UTF-16 下标分歧、char 语义分歧,各带原因与 03 §7 依据

## 验收标准

- 字符串 round-trip 测试:读 → 打印 → 读回相等(含多字节 UTF-8)
- IO 重定向测试:`binding [*out* (StringIO...)]` 内 `println` 输出被捕获
- 全部字符串/char 分歧条目进 known-divergences 注册表且带 03 §7 引用

## 结论

(完成后填写)
