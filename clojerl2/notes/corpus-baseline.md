# corpus 基线(clojerl2-021/022)

语料:`test/corpus.edn`(jolt `test/chez/corpus.edn` @ 6c2685e,EPL-2.0;`:expected` 经 `make corpus-regen` 以 JVM Clojure 1.12.5 重新生成),只计 `:portability :common` 条目。
生成:`make corpus`;门控:`make certify`(对照 `test/corpus-known-failures.edn`)。判定见 `src/erl/clj2_corpus.erl`。

**通过 3545 / 4841(73.2%)**

## 按 core 分层

条目归入它引用到的最靠后的 core 层(`clj2_core:layer_vars/0`)。

| 层 | 通过 | 条目 | 通过率 |
|---|---|---|---|
| 00-kernel | 1511 | 1957 | 77% |
| 01-core | 1853 | 2506 | 74% |
| 02-protocols | 85 | 188 | 45% |
| 03-print | 92 | 186 | 49% |
| 04-repl | 4 | 4 | 100% |

## 按 suite

| suite | 通过 | 条目 | 通过率 |
|---|---|---|---|
| conformance | 315 | 364 | 87% |
| numbers | 208 | 339 | 61% |
| seq | 244 | 276 | 88% |
| reader | 126 | 211 | 60% |
| predicates | 169 | 188 | 90% |
| map | 157 | 182 | 86% |
| regex | 143 | 150 | 95% |
| format | 102 | 140 | 73% |
| clojure.core | 130 | 135 | 96% |
| untested | 99 | 120 | 83% |
| macros | 93 | 119 | 78% |
| io | 61 | 119 | 51% |
| control | 99 | 102 | 97% |
| maps | 69 | 98 | 70% |
| host-interop | 52 | 97 | 54% |
| sorted | 80 | 90 | 89% |
| interop | 66 | 90 | 73% |
| set | 62 | 80 | 78% |
| metadata | 59 | 75 | 79% |
| functions | 70 | 70 | 100% |
| exceptions | 50 | 66 | 76% |
| destructure | 60 | 64 | 94% |
| transient | 54 | 63 | 86% |
| forms | 55 | 63 | 87% |
| core | 35 | 60 | 58% |
| namespaces | 28 | 56 | 50% |
| lazy | 50 | 56 | 89% |
| vector | 55 | 55 | 100% |
| seq-type-model | 10 | 53 | 19% |
| protocols | 32 | 51 | 63% |
| string | 45 | 49 | 92% |
| truthiness | 47 | 47 | 100% |
| transducers | 42 | 45 | 93% |
| ns | 8 | 44 | 18% |
| clojure.string | 42 | 42 | 100% |
| collections | 28 | 41 | 68% |
| refs | 2 | 40 | 5% |
| multimethods | 35 | 37 | 95% |
| equality | 32 | 32 | 100% |
| vars | 11 | 31 | 35% |
| state | 30 | 31 | 97% |
| uuid | 30 | 30 | 100% |
| records | 15 | 30 | 50% |
| clojure.edn | 2 | 27 | 7% |
| printer | 20 | 26 | 77% |
| charsets | 1 | 26 | 4% |
| clojure.math | 0 | 25 | 0% |
| hierarchy | 24 | 24 | 100% |
| defn | 13 | 24 | 54% |
| syntax-quote | 11 | 22 | 50% |
| sequences | 21 | 21 | 100% |
| seqs | 19 | 21 | 90% |
| strings | 16 | 20 | 80% |
| regex-parity | 15 | 20 | 75% |
| list | 20 | 20 | 100% |
| errors | 4 | 19 | 21% |
| inst | 1 | 18 | 6% |
| deftype | 5 | 15 | 33% |
| clojure.set | 0 | 14 | 0% |
| arrays | 13 | 14 | 93% |
| clojure.walk | 0 | 12 | 0% |
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
| *ns* | 6 | 8 | 75% |
| locking | 7 | 7 | 100% |
| fn identity | 1 | 7 | 14% |
| chunking-model | 0 | 7 | 0% |
| take | 0 | 6 | 0% |
| string as a seqable of chars | 6 | 6 | 100% |
| streams | 0 | 6 | 0% |
| stdlib | 0 | 6 | 0% |
| nth | 3 | 6 | 50% |
| meta | 4 | 6 | 67% |
| instance? | 6 | 6 | 100% |
| distinct | 6 | 6 | 100% |
| compile-eval | 2 | 6 | 33% |
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
| clojure.template | 0 | 2 | 0% |
| assert | 2 | 2 | 100% |
| walk | 0 | 1 | 0% |
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
| `:pending/triage` | 360 |
| `:pending/compiler` | 207 |
| `:pending/missing-core-var` | 120 |
| `:pending/reader` | 111 |
| `:pending/runtime-eval` | 83 |
| `:pending/numbers` | 67 |
| `:host/jvm-classes` | 61 |
| `:number/beam-semantics` | 54 |
| `:seqs/class-model` | 42 |
| `:pending/stdlib-namespaces` | 26 |
| `:collections/map-order` | 24 |
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
| wrong value | 358 |
| threw (unexpected) | 307 |
| compile: unresolved symbol | 172 |
| compile: unsupported literal tagged | 95 |
| compile: error | 82 |
| compile: unsupported literal bigdec | 67 |
| compile: syntax | 56 |
| expected a throw | 37 |
| compile: read | 22 |
| compile: link | 15 |
| compile: driver | 12 |
| compile: unsupported special form set! | 11 |
| compile: on_load_failure | 11 |
| compile: unsupported literal syntax_quote | 10 |
| compile: resolve | 10 |
| compile: declare | 8 |
| timeout | 6 |
| compile: unsupported | 5 |
| compile: other | 4 |
| compile: verify | 2 |
| :expected does not evaluate | 2 |
| crashed | 1 |
| compile: unsupported literal unquote | 1 |
| compile: unsupported literal fnstar | 1 |
| compile: no such var | 1 |

## 最常见的未解析符号(缺失的 core 函数/宏的线索)

| 符号 | 条目 |
|---|---|
| `resolve` | 13 |
| `reify` | 12 |
| `with-redefs` | 9 |
| `read` | 9 |
| `print-method` | 8 |
| `ns-aliases` | 6 |
| `read+string` | 6 |
| `reader-conditional` | 6 |
| `ref-min-history` | 5 |
| `ns-map` | 5 |
| `tagged-literal` | 4 |
| `line-seq` | 4 |
| `intern` | 4 |
| `chunk-first` | 3 |
| `ns-unalias` | 3 |
| `alter-var-root` | 3 |
| `StringWriter.` | 3 |
| `inst-ms` | 3 |
| `ref-max-history` | 3 |
| `__reader-features` | 3 |
| `sorted-set?` | 3 |
| `thread-bound?` | 3 |
| `bigdec` | 3 |
| `ns-publics` | 3 |
| `ns-resolve` | 3 |
| `chunk-buffer` | 3 |
| `refer` | 2 |
| `ns-refers` | 2 |
| `ns-interns` | 2 |
| `xml-seq` | 2 |
| `sorted-map?` | 2 |
| `ref?` | 2 |
| `ns-unmap` | 2 |
| `keyword-identical?` | 2 |
| `object?` | 1 |
| `bogus-head` | 1 |
| `use` | 1 |
| `file-seq` | 1 |
| `corpus.e3887` | 1 |
| `undefined?` | 1 |
| `update-proxy` | 1 |
| `construct-proxy` | 1 |
| `test` | 1 |
| `ref-history-count` | 1 |
| `InputStream` | 1 |
| `with-redefs-fn` | 1 |
| `print-dup` | 1 |
| `iterator-seq` | 1 |
| `init-proxy` | 1 |
| `get-thread-bindings` | 1 |
| `bound?` | 1 |
| `ns-imports` | 1 |
| `requiring-resolve` | 1 |
| `defstruct` | 1 |
| `java.nio.file.attribute.FileAttribute` | 1 |
| `remove-ns` | 1 |
| `Inst` | 1 |
| `refer-clojure` | 1 |
| `a` | 1 |
| `java.net.URL.` | 1 |
