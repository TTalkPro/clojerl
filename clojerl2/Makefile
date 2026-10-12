# clojerl2 — build & test entry points.
#
#   make            compile the Erlang layer and clojure.core into ebin/
#                   (bin/clojerl2 runs from there)
#   make test       compile everything and run the eunit suites
#   make smoke      REPL / CLI smoke test (test/repl-smoke.sh)
#   make example    the rebar3 plugin on examples/hello (test/rebar3-example.sh)
#   make docs-check the `;=>' examples in docs/*.md (test/docs-examples.sh)
#   make cts        the clojure-test-suite gate (test/cts.sh): per-namespace
#                   fail/error counts must match test/cts-known-failures.txt
#   make corpus     run the conformance corpus, write notes/corpus-baseline.md
#   make certify    the corpus gate: fails on an unlisted failure or a stale
#                   entry in test/corpus-known-failures.edn
#   make corpus-rebaseline   rewrite test/corpus-known-failures.edn
#   make corpus-regen        re-derive the corpus :expected from JVM Clojure
#   make clean      remove build artefacts
#
# Requires Erlang/OTP 27+ (developed against OTP 28).

ERLC     ?= erlc
EBIN     := ebin
SRC      := src/erl
TEST     := test
INCLUDE  := include

ERLC_OPTS := -I $(INCLUDE) \
             +debug_info \
             +warn_unused_vars \
             +warn_unused_import \
             +warn_shadow_vars \
             +warn_unused_function \
             +warn_exported_vars \
             +warn_obsolete_guard

ERL_FLAGS := -noshell -pa $(EBIN)

SRCS       := $(wildcard $(SRC)/*.erl)
TESTS      := $(wildcard $(TEST)/*_tests.erl)
SRC_BEAMS  := $(patsubst $(SRC)/%.erl,$(EBIN)/%.beam,$(SRCS))
TEST_BEAMS := $(patsubst $(TEST)/%.erl,$(EBIN)/%.beam,$(TESTS))
comma      := ,
empty      :=
space      := $(empty) $(empty)
TEST_MODS  := $(subst $(space),$(comma),$(strip $(basename $(notdir $(TESTS)))))

.PHONY: all test smoke example docs-check cts FORCE corpus certify corpus-rebaseline corpus-regen clean

CORE_SRCS := $(wildcard priv/clj2/core/*)

STDLIB_SRCS := $(shell find priv/clj2/stdlib -name '*.clj' 2>/dev/null)

all: $(SRC_BEAMS) $(EBIN)/clojure.core.beam $(EBIN)/clj2.stdlib $(EBIN)/clj2.build

# clojure.core prebuilt, so the CLI starts without compiling it
# (clj2_core:ensure/0 falls back to compiling when it is missing)
$(EBIN)/clojure.core.beam: $(SRC_BEAMS) $(CORE_SRCS)
	erl $(ERL_FLAGS) -eval '{ok, _, _} = clj2_core:build("$(EBIN)"), halt().'

# the standard library namespaces (clojure.string ...), prebuilt like core;
# without them they compile from priv/clj2/stdlib on first use
$(EBIN)/clj2.stdlib: $(EBIN)/clojure.core.beam $(STDLIB_SRCS)
	erl $(ERL_FLAGS) -eval '#{} = clj2_build:build(#{src_dirs => ["priv/clj2/stdlib"], ebin_dir => "$(EBIN)", cache_dir => "_build/clj2_stdlib_cache"}), halt().'
	@touch $@

# the commit the CLI reports (designs/04 §4.3)
$(EBIN)/clj2.build: FORCE
	@mkdir -p $(EBIN)
	@v=$$(git describe --always --dirty 2>/dev/null || echo dev); \
	  [ "$$(cat $@ 2>/dev/null)" = "$$v" ] || echo "$$v" > $@

FORCE:

$(EBIN)/%.beam: $(SRC)/%.erl $(wildcard $(INCLUDE)/*.hrl)
	@mkdir -p $(EBIN)
	$(ERLC) $(ERLC_OPTS) -o $(EBIN) $<

$(EBIN)/%_tests.beam: $(TEST)/%_tests.erl $(SRC_BEAMS)
	@mkdir -p $(EBIN)
	$(ERLC) $(ERLC_OPTS) -DTEST -o $(EBIN) $<

test: all $(TEST_BEAMS)
	erl $(ERL_FLAGS) -eval 'case eunit:test([$(TEST_MODS)], []) of ok -> halt(0); _ -> halt(1) end.'

# The VM runs in its own cgroup with a hard memory cap (systemd-run, when a
# user manager is available) so a runaway entry kills this VM, not the session.
CORPUS_MEM ?= 4G
CORPUS_RUN := $(shell command -v systemd-run >/dev/null 2>&1 && systemd-run --user --scope -q true 2>/dev/null && \
                echo systemd-run --user --scope -q -p MemoryMax=$(CORPUS_MEM) -p MemorySwapMax=0)

corpus: $(SRC_BEAMS)
	$(CORPUS_RUN) erl $(ERL_FLAGS) -eval 'R = clj2_corpus:run(), io:format("~p~n", [clj2_corpus:report(R, "notes/corpus-baseline.md")]), halt().'

certify: $(SRC_BEAMS)
	$(CORPUS_RUN) erl $(ERL_FLAGS) -eval '{S, _} = clj2_corpus:certify(), halt(case S of ok -> 0; _ -> 1 end).'

corpus-rebaseline: $(SRC_BEAMS)
	$(CORPUS_RUN) erl $(ERL_FLAGS) -eval 'io:format("~p~n", [clj2_corpus:rebaseline()]), halt().'

# The JVM oracle (designs/04 §5.1): only for regenerating; CI never needs a JVM.
CLOJURE_VERSION ?= 1.12.5
corpus-regen:
	clojure -Sdeps '{:deps {org.clojure/clojure {:mvn/version "$(CLOJURE_VERSION)"}}}' -M tools/regen-corpus.clj $(REGEN_FLAGS)

smoke: all
	sh test/repl-smoke.sh

example: all
	sh test/rebar3-example.sh

docs-check: all
	sh test/docs-examples.sh

# the vendored clojure-test-suite, one VM per namespace, in the same
# memory-capped scope as the corpus (CLJ2_CTS_WRITE_BASELINE=1 rewrites
# the baseline)
cts: all
	$(CORPUS_RUN) sh test/cts.sh

clean:
	rm -rf $(EBIN)
