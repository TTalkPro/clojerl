# corpus 基线(clojerl2-021/022)

语料:`test/corpus.edn`(jolt `test/chez/corpus.edn` @ 6c2685e,EPL-2.0;`:expected` 经 `make corpus-regen` 以 JVM Clojure 1.12.5 重新生成),只计 `:portability :common` 条目。
生成:`make corpus`;门控:`make certify`(对照 `test/corpus-known-failures.edn`)。判定见 `src/erl/clj2_corpus.erl`。

**通过 3648 / 4841(75.4%)**

## 按 core 分层

条目归入它引用到的最靠后的 core 层(`clj2_core:layer_vars/0`)。

| 层 | 通过 | 条目 | 通过率 |
|---|---|---|---|
| 00-kernel | 1523 | 1932 | 79% |
| 01-core | 1940 | 2531 | 77% |
| 02-protocols | 88 | 188 | 47% |
| 03-print | 93 | 186 | 50% |
| 04-repl | 4 | 4 | 100% |

## 按 suite

| suite | 通过 | 条目 | 通过率 |
|---|---|---|---|
| conformance | 321 | 364 | 88% |
| numbers | 210 | 339 | 62% |
| seq | 245 | 276 | 89% |
| reader | 129 | 211 | 61% |
| predicates | 170 | 188 | 90% |
| map | 157 | 182 | 86% |
| regex | 143 | 150 | 95% |
| format | 102 | 140 | 73% |
| clojure.core | 130 | 135 | 96% |
| untested | 102 | 120 | 85% |
| macros | 97 | 119 | 82% |
| io | 61 | 119 | 51% |
| control | 99 | 102 | 97% |
| maps | 69 | 98 | 70% |
| host-interop | 52 | 97 | 54% |
| sorted | 80 | 90 | 89% |
| interop | 66 | 90 | 73% |
| set | 62 | 80 | 78% |
| metadata | 61 | 75 | 81% |
| functions | 70 | 70 | 100% |
| exceptions | 52 | 66 | 79% |
| destructure | 60 | 64 | 94% |
| transient | 55 | 63 | 87% |
| forms | 56 | 63 | 89% |
| core | 36 | 60 | 60% |
| namespaces | 39 | 56 | 70% |
| lazy | 50 | 56 | 89% |
| vector | 55 | 55 | 100% |
| seq-type-model | 10 | 53 | 19% |
| protocols | 32 | 51 | 63% |
| string | 45 | 49 | 92% |
| truthiness | 47 | 47 | 100% |
| transducers | 42 | 45 | 93% |
| ns | 41 | 44 | 93% |
| clojure.string | 42 | 42 | 100% |
| collections | 28 | 41 | 68% |
| refs | 2 | 40 | 5% |
| multimethods | 35 | 37 | 95% |
| equality | 32 | 32 | 100% |
| vars | 12 | 31 | 39% |
| state | 30 | 31 | 97% |
| uuid | 30 | 30 | 100% |
| records | 15 | 30 | 50% |
| clojure.edn | 2 | 27 | 7% |
| printer | 20 | 26 | 77% |
| charsets | 1 | 26 | 4% |
| clojure.math | 0 | 25 | 0% |
| hierarchy | 24 | 24 | 100% |
| defn | 14 | 24 | 58% |
| syntax-quote | 11 | 22 | 50% |
| sequences | 21 | 21 | 100% |
| seqs | 19 | 21 | 90% |
| strings | 17 | 20 | 85% |
| regex-parity | 15 | 20 | 75% |
| list | 20 | 20 | 100% |
| errors | 4 | 19 | 21% |
| inst | 2 | 18 | 11% |
| deftype | 5 | 15 | 33% |
| clojure.set | 14 | 14 | 100% |
| arrays | 13 | 14 | 93% |
| clojure.walk | 7 | 12 | 58% |
| interop-fixes | 7 | 11 | 64% |
| integer-box-model | 3 | 11 | 27% |
| edn | 2 | 11 | 18% |
| casts | 3 | 11 | 27% |
| typed-throws | 2 | 10 | 20% |
| reduce | 9 | 10 | 90% |
| print | 0 | 10 | 0% |
| quoted-literal constants | 6 | 9 | 67% |
| iref | 2 | 9 | 22% |
| contracts | 0 | 9 | 0% |
| ISeq call forms | 9 | 9 | 100% |
| murmur3 | 0 | 8 | 0% |
| *ns* | 8 | 8 | 100% |
| locking | 7 | 7 | 100% |
| fn identity | 1 | 7 | 14% |
| chunking-model | 0 | 7 | 0% |
| take | 0 | 6 | 0% |
| string as a seqable of chars | 6 | 6 | 100% |
| streams | 0 | 6 | 0% |
| stdlib | 1 | 6 | 17% |
| nth | 3 | 6 | 50% |
| meta | 4 | 6 | 67% |
| instance? | 6 | 6 | 100% |
| distinct | 6 | 6 | 100% |
| compile-eval | 3 | 6 | 50% |
| calls | 6 | 6 | 100% |
| vectors | 5 | 5 | 100% |
| var-meta | 3 | 5 | 60% |
| resolution | 4 | 5 | 80% |
| printing | 1 | 5 | 20% |
| eval & load-string as values | 3 | 5 | 60% |
| concurrency | 0 | 5 | 0% |
| chunked-seq | 1 | 5 | 20% |
| time | 0 | 4 | 0% |
| symbols | 4 | 4 | 100% |
| reflect | 3 | 4 | 75% |
| read-string | 0 | 4 | 0% |
| for | 2 | 4 | 50% |
| fn | 4 | 4 | 100% |
| dynamic vars | 4 | 4 | 100% |
| defmacro | 0 | 4 | 0% |
| clojure 1.12 | 1 | 4 | 25% |
| tagged literals | 0 | 3 | 0% |
| string-model | 0 | 3 | 0% |
| permissive | 2 | 3 | 67% |
| munging | 3 | 3 | 100% |
| lazy-seq | 3 | 3 | 100% |
| ifn | 3 | 3 | 100% |
| defonce | 1 | 3 | 33% |
| clojure.repl | 0 | 3 | 0% |
| analyze | 1 | 3 | 33% |
| special forms | 2 | 2 | 100% |
| record hasheq cache | 2 | 2 | 100% |
| reader-model | 0 | 2 | 0% |
| identical? lowering | 2 | 2 | 100% |
| fn identity hash | 2 | 2 | 100% |
| defprotocol | 1 | 2 | 50% |
| def | 2 | 2 | 100% |
| concurrency-model | 0 | 2 | 0% |
| clojure.template | 2 | 2 | 100% |
| assert | 2 | 2 | 100% |
| walk | 1 | 1 | 100% |
| try | 1 | 1 | 100% |
| structmaps | 0 | 1 | 0% |
| sort | 1 | 1 | 100% |
| seq hasheq cache | 1 | 1 | 100% |
| scope | 1 | 1 | 100% |
| reflection | 1 | 1 | 100% |
| realized? | 1 | 1 | 100% |
| quote | 0 | 1 | 0% |
| pprint | 0 | 1 | 0% |
| delay | 1 | 1 | 100% |
| defmulti | 0 | 1 | 0% |
| core vars | 1 | 1 | 100% |
| compare | 0 | 1 | 0% |
| bit-ops | 0 | 1 | 0% |
| binding | 1 | 1 | 100% |
| assoc | 0 | 1 | 0% |

## 失败原因(known-failures 登记)

| cause | 条目 |
|---|---|
| `:pending/triage` | 336 |
| `:pending/compiler` | 177 |
| `:pending/missing-core-var` | 117 |
| `:pending/reader` | 105 |
| `:pending/numbers` | 67 |
| `:host/jvm-classes` | 61 |
| `:number/beam-semantics` | 52 |
| `:pending/runtime-eval` | 49 |
| `:seqs/class-model` | 42 |
| `:collections/map-order` | 24 |
| `:pending/stdlib-namespaces` | 22 |
| `:refs/no-stm` | 22 |
| `:lazy-seq/no-chunking` | 21 |
| `:collections/exact-keys` | 20 |
| `:pending/host-types` | 20 |
| `:pending/ref-types` | 12 |
| `:protocols/type-designators` | 12 |
| `:pending/special-forms` | 11 |
| `:fn/structural-identity` | 6 |
| `:number/no-ratio-arithmetic` | 5 |
| `:pending/strings-io` | 4 |
| `:fn/arity-at-compile-time` | 3 |
| `:values/no-identity` | 2 |
| `:char/integer` | 2 |
| `:symbol/no-metadata` | 1 |

## 失败类别

| 类别 | 条目 |
|---|---|
| threw (unexpected) | 441 |
| wrong value | 366 |
| compile: unresolved symbol | 130 |
| compile: syntax | 57 |
| compile: error | 44 |
| expected a throw | 35 |
| compile: link | 19 |
| compile: resolve | 14 |
| compile: read | 12 |
| compile: driver | 12 |
| compile: unsupported special form set! | 11 |
| compile: on_load_failure | 11 |
| compile: unsupported literal syntax_quote | 10 |
| compile: declare | 8 |
| timeout | 6 |
| compile: unsupported | 5 |
| compile: other | 4 |
| :expected does not evaluate | 3 |
| compile: verify | 2 |
| crashed | 1 |
| compile: unsupported literal unquote | 1 |
| compile: unsupported literal fnstar | 1 |

## 最常见的未解析符号(缺失的 core 函数/宏的线索)

| 符号 | 条目 |
|---|---|
| `reify` | 12 |
| `with-redefs` | 9 |
| `read` | 9 |
| `print-method` | 8 |
| `inst-ms` | 7 |
| `reader-conditional` | 6 |
| `read+string` | 6 |
| `ref-min-history` | 5 |
| `tagged-literal` | 4 |
| `line-seq` | 4 |
| `alter-var-root` | 3 |
| `__reader-features` | 3 |
| `chunk-first` | 3 |
| `ref-max-history` | 3 |
| `chunk-buffer` | 3 |
| `StringWriter.` | 3 |
| `thread-bound?` | 3 |
| `sorted-set?` | 3 |
| `bigdec` | 3 |
| `ref?` | 2 |
| `keyword-identical?` | 2 |
| `inst-ms*` | 2 |
| `Inst` | 2 |
| `sorted-map?` | 2 |
| `xml-seq` | 2 |
| `undefined?` | 1 |
| `iterator-seq` | 1 |
| `java.nio.file.attribute.FileAttribute` | 1 |
| `java.net.URL.` | 1 |
| `print-dup` | 1 |
| `defstruct` | 1 |
| `test` | 1 |
| `ns-imports` | 1 |
| `a` | 1 |
| `object?` | 1 |
| `construct-proxy` | 1 |
| `init-proxy` | 1 |
| `update-proxy` | 1 |
| `file-seq` | 1 |
| `corpus.e3887` | 1 |
| `ref-history-count` | 1 |
| `get-proxy-class` | 1 |
| `with-redefs-fn` | 1 |
| `get-thread-bindings` | 1 |
| `InputStream` | 1 |
| `bogus-head` | 1 |
