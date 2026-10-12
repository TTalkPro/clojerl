# corpus 基线(clojerl2-021/022)

语料:`test/corpus.edn`(jolt `test/chez/corpus.edn` @ 6c2685e,EPL-2.0;`:expected` 经 `make corpus-regen` 以 JVM Clojure 1.12.5 重新生成),只计 `:portability :common` 条目。
生成:`make corpus`;门控:`make certify`(对照 `test/corpus-known-failures.edn`)。判定见 `src/erl/clj2_corpus.erl`。

**通过 3975 / 4841(82.1%)**

## 按 core 分层

条目归入它引用到的最靠后的 core 层(`clj2_core:layer_vars/0`)。

| 层 | 通过 | 条目 | 通过率 |
|---|---|---|---|
| 00-kernel | 1654 | 1894 | 87% |
| 01-core | 2114 | 2557 | 83% |
| 02-protocols | 101 | 200 | 51% |
| 03-print | 102 | 186 | 55% |
| 04-repl | 4 | 4 | 100% |

## 按 suite

| suite | 通过 | 条目 | 通过率 |
|---|---|---|---|
| conformance | 344 | 364 | 95% |
| numbers | 285 | 339 | 84% |
| seq | 265 | 276 | 96% |
| reader | 149 | 211 | 71% |
| predicates | 179 | 188 | 95% |
| map | 164 | 182 | 90% |
| regex | 143 | 150 | 95% |
| format | 108 | 140 | 77% |
| clojure.core | 134 | 135 | 99% |
| untested | 113 | 120 | 94% |
| macros | 105 | 119 | 88% |
| io | 66 | 119 | 55% |
| control | 100 | 102 | 98% |
| maps | 69 | 98 | 70% |
| host-interop | 58 | 97 | 60% |
| sorted | 86 | 90 | 96% |
| interop | 73 | 90 | 81% |
| set | 66 | 80 | 83% |
| metadata | 61 | 75 | 81% |
| functions | 70 | 70 | 100% |
| exceptions | 62 | 66 | 94% |
| destructure | 61 | 64 | 95% |
| transient | 60 | 63 | 95% |
| forms | 61 | 63 | 97% |
| core | 39 | 60 | 65% |
| namespaces | 49 | 56 | 88% |
| lazy | 50 | 56 | 89% |
| vector | 55 | 55 | 100% |
| seq-type-model | 10 | 53 | 19% |
| protocols | 33 | 51 | 65% |
| string | 48 | 49 | 98% |
| truthiness | 47 | 47 | 100% |
| transducers | 42 | 45 | 93% |
| ns | 42 | 44 | 95% |
| clojure.string | 42 | 42 | 100% |
| collections | 37 | 41 | 90% |
| refs | 2 | 40 | 5% |
| multimethods | 37 | 37 | 100% |
| equality | 32 | 32 | 100% |
| vars | 24 | 31 | 77% |
| state | 30 | 31 | 97% |
| uuid | 30 | 30 | 100% |
| records | 15 | 30 | 50% |
| clojure.edn | 2 | 27 | 7% |
| printer | 20 | 26 | 77% |
| charsets | 1 | 26 | 4% |
| clojure.math | 0 | 25 | 0% |
| hierarchy | 24 | 24 | 100% |
| defn | 14 | 24 | 58% |
| syntax-quote | 14 | 22 | 64% |
| sequences | 21 | 21 | 100% |
| seqs | 19 | 21 | 90% |
| strings | 20 | 20 | 100% |
| regex-parity | 15 | 20 | 75% |
| list | 20 | 20 | 100% |
| errors | 16 | 19 | 84% |
| inst | 3 | 18 | 17% |
| deftype | 5 | 15 | 33% |
| clojure.set | 14 | 14 | 100% |
| arrays | 13 | 14 | 93% |
| clojure.walk | 7 | 12 | 58% |
| interop-fixes | 9 | 11 | 82% |
| integer-box-model | 3 | 11 | 27% |
| edn | 2 | 11 | 18% |
| casts | 4 | 11 | 36% |
| typed-throws | 9 | 10 | 90% |
| reduce | 9 | 10 | 90% |
| print | 0 | 10 | 0% |
| quoted-literal constants | 6 | 9 | 67% |
| iref | 4 | 9 | 44% |
| contracts | 7 | 9 | 78% |
| ISeq call forms | 9 | 9 | 100% |
| murmur3 | 0 | 8 | 0% |
| *ns* | 7 | 8 | 88% |
| locking | 7 | 7 | 100% |
| fn identity | 1 | 7 | 14% |
| chunking-model | 0 | 7 | 0% |
| take | 0 | 6 | 0% |
| string as a seqable of chars | 6 | 6 | 100% |
| streams | 0 | 6 | 0% |
| stdlib | 1 | 6 | 17% |
| nth | 6 | 6 | 100% |
| meta | 4 | 6 | 67% |
| instance? | 6 | 6 | 100% |
| distinct | 6 | 6 | 100% |
| compile-eval | 4 | 6 | 67% |
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
| read-string | 3 | 4 | 75% |
| for | 2 | 4 | 50% |
| fn | 4 | 4 | 100% |
| dynamic vars | 4 | 4 | 100% |
| defmacro | 0 | 4 | 0% |
| clojure 1.12 | 3 | 4 | 75% |
| tagged literals | 2 | 3 | 67% |
| string-model | 0 | 3 | 0% |
| permissive | 2 | 3 | 67% |
| munging | 3 | 3 | 100% |
| lazy-seq | 3 | 3 | 100% |
| ifn | 3 | 3 | 100% |
| defonce | 2 | 3 | 67% |
| clojure.repl | 0 | 3 | 0% |
| analyze | 1 | 3 | 33% |
| special forms | 2 | 2 | 100% |
| record hasheq cache | 2 | 2 | 100% |
| reader-model | 1 | 2 | 50% |
| identical? lowering | 2 | 2 | 100% |
| fn identity hash | 2 | 2 | 100% |
| defprotocol | 1 | 2 | 50% |
| def | 2 | 2 | 100% |
| concurrency-model | 0 | 2 | 0% |
| clojure.template | 2 | 2 | 100% |
| assert | 2 | 2 | 100% |
| walk | 1 | 1 | 100% |
| try | 1 | 1 | 100% |
| structmaps | 1 | 1 | 100% |
| sort | 1 | 1 | 100% |
| seq hasheq cache | 1 | 1 | 100% |
| scope | 1 | 1 | 100% |
| reflection | 1 | 1 | 100% |
| realized? | 1 | 1 | 100% |
| quote | 0 | 1 | 0% |
| pprint | 0 | 1 | 0% |
| delay | 1 | 1 | 100% |
| defmulti | 1 | 1 | 100% |
| core vars | 1 | 1 | 100% |
| compare | 0 | 1 | 0% |
| bit-ops | 0 | 1 | 0% |
| binding | 1 | 1 | 100% |
| assoc | 1 | 1 | 100% |

## 失败原因(known-failures 登记)

| cause | 条目 |
|---|---|
| `:pending/compiler` | 149 |
| `:pending/reader` | 120 |
| `:host/jvm-classes` | 77 |
| `:number/beam-semantics` | 53 |
| `:pending/host-types` | 49 |
| `:seqs/class-model` | 45 |
| `:collections/map-order` | 35 |
| `:refs/no-stm` | 33 |
| `:pending/runtime-eval` | 31 |
| `:pending/printer` | 29 |
| `:pending/stdlib-namespaces` | 22 |
| `:collections/exact-keys` | 22 |
| `:lazy-seq/no-chunking` | 21 |
| `:pending/core-bugs` | 19 |
| `:pending/var-surface` | 14 |
| `:protocols/type-designators` | 12 |
| `:symbol/no-metadata` | 12 |
| `:pending/regex-edge` | 10 |
| `:number/no-ratio-arithmetic` | 10 |
| `:pending/laziness` | 9 |
| `:values/no-identity` | 8 |
| `:pending/corpus-environment` | 8 |
| `:char/integer` | 8 |
| `:pending/format-edge` | 8 |
| `:pending/records` | 7 |
| `:macros/defmacro-form` | 6 |
| `:fn/structural-identity` | 6 |
| `:collections/map-entry-vectors` | 5 |
| `:pending/ref-types` | 5 |
| `:pending/metadata` | 5 |
| `:pending/special-forms` | 5 |
| `:pending/strings-io` | 4 |
| `:transients/wrapped` | 4 |
| `:fn/arity-at-compile-time` | 4 |
| `:string/code-point-indexing` | 3 |
| `:vars/core-direct-linked` | 2 |
| `:vars/forward-references` | 2 |
| `:sorted/comparator-calls` | 2 |
| `:interop/erlang-module-calls` | 1 |
| `:exceptions/erlang-classes` | 1 |

## 失败类别

| 类别 | 条目 |
|---|---|
| wrong value | 332 |
| threw (unexpected) | 310 |
| compile: unresolved symbol | 69 |
| compile: error | 44 |
| compile: syntax | 16 |
| compile: resolve | 13 |
| compile: read | 12 |
| compile: driver | 12 |
| expected a throw | 11 |
| compile: on_load_failure | 11 |
| compile: unsupported literal syntax_quote | 10 |
| compile: link | 7 |
| compile: unsupported | 5 |
| compile: other | 4 |
| :expected does not evaluate | 3 |
| timeout | 2 |
| compile: verify | 2 |
| compile: unsupported special form set! | 1 |
| compile: unsupported literal unquote | 1 |
| compile: unsupported literal fnstar | 1 |

## 最常见的未解析符号(缺失的 core 函数/宏的线索)

| 符号 | 条目 |
|---|---|
| `reify` | 12 |
| `read` | 9 |
| `print-method` | 8 |
| `read+string` | 6 |
| `ref-min-history` | 5 |
| `line-seq` | 4 |
| `ref-max-history` | 3 |
| `chunk-first` | 3 |
| `chunk-buffer` | 3 |
| `StringWriter.` | 3 |
| `__reader-features` | 3 |
| `ref?` | 2 |
| `corpus.e3887` | 1 |
| `ref-history-count` | 1 |
| `ns-imports` | 1 |
| `file-seq` | 1 |
| `bogus-head` | 1 |
| `java.nio.file.attribute.FileAttribute` | 1 |
| `InputStream` | 1 |
| `java.net.URL.` | 1 |
