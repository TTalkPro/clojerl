# clojerl2-044 嵌入 API

状态:已完成(2026-10-13)
里程碑:M7(嵌入式 DSL 与规则引擎,designs/10)
依赖:clojerl2-043

## 目标

宿主应用在运行时加载、调用、替换 Clojure 代码的正式入口。

## 工作内容

- [x] 模块 `clj2`(`src/erl/clj2.erl`):`ensure/0`、`load/1,2`(源码 → 命名空间,再次加载即热替换,选项 `file`)、
  `call/3`(函数名为 atom 或 binary)、`eval/1,2`、`unload/1`、`is_loaded/1`、`module/1`
- [x] 错误以数据返回:`#{kind => read | syntax | load | runtime, message, line, column, reason}`,
  消息与 REPL 的报错一致(`error_info/3`);命名空间初始化抛出的异常、加载失败(`old_code_in_use`)也一样

## 结论

回归测试 `clj2_embed_tests:load_call_test`、`errors_are_data_test`。
