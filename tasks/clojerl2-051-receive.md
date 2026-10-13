# clojerl2-051 带模式匹配的 receive

状态:已完成(2026-10-13)
里程碑:M7
依赖:clojerl2-050

## 工作内容

- [x] 特殊形式 `receive*` 与宏 `receive`:`(receive 模式 表达式 ... (after 毫秒 表达式 ...))`,编译成 Erlang 原生 `receive`(选择性接收:
  不匹配的消息留在邮箱)
- [x] 模式:向量匹配同长度的 tuple 或 list;map 匹配含这些(字面量)键的 map;符号绑定新的局部量,同一模式里重复出现要求相等;`_` 通配;
  关键字、数字、字符串、nil/true/false 与 `'quoted` 数据匹配自身;`~x` 匹配局部量的当前值
- [x] 编译器:L0/L1/L5 新节点 `receive`/`rclause`(模式作为数据,绑定变量与 pin 作为子节点),resolve、recur(子句体是尾位置)、anf、
  verify、labs(`ereceive`、map 模式 `emapp`;向量模式展开为 tuple 与 list 两种子句,组合超过 16 种时只用 tuple)、emit
- [x] 不支持 `:when` 守卫(先取出再用 `cond` 判断)

## 结论

回归测试 `clj2_interop_tests:receive_test`、`receive_server_test`;文档 `docs/erlang-interop.md`「进程与消息」。
