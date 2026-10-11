# clojerl2 — build & test entry points.
#
#   make            compile the Erlang layer into ebin/
#   make test       compile everything and run the eunit suites
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

.PHONY: all test corpus certify corpus-rebaseline corpus-regen clean

all: $(SRC_BEAMS)

$(EBIN)/%.beam: $(SRC)/%.erl $(wildcard $(INCLUDE)/*.hrl)
	@mkdir -p $(EBIN)
	$(ERLC) $(ERLC_OPTS) -o $(EBIN) $<

$(EBIN)/%_tests.beam: $(TEST)/%_tests.erl $(SRC_BEAMS)
	@mkdir -p $(EBIN)
	$(ERLC) $(ERLC_OPTS) -DTEST -o $(EBIN) $<

test: $(SRC_BEAMS) $(TEST_BEAMS)
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

clean:
	rm -rf $(EBIN)
