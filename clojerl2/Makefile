# clojerl2 — build & test entry points.
#
#   make            compile the Erlang layer into ebin/
#   make test       compile everything and run the eunit suites
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

SRC_BEAMS  := $(EBIN)/clj2_reader.beam
TEST_BEAMS := $(EBIN)/clj2_reader_tests.beam

.PHONY: all test clean

all: $(SRC_BEAMS)

$(EBIN)/clj2_reader.beam: $(SRC)/clj2_reader.erl $(INCLUDE)/clojerl2.hrl
	@mkdir -p $(EBIN)
	$(ERLC) $(ERLC_OPTS) -o $(EBIN) $(SRC)/clj2_reader.erl

$(EBIN)/clj2_reader_tests.beam: $(TEST)/clj2_reader_tests.erl $(EBIN)/clj2_reader.beam
	@mkdir -p $(EBIN)
	$(ERLC) $(ERLC_OPTS) -DTEST -o $(EBIN) $(TEST)/clj2_reader_tests.erl

test: $(SRC_BEAMS) $(TEST_BEAMS)
	erl $(ERL_FLAGS) -eval 'case eunit:test([clj2_reader_tests], []) of ok -> halt(0); _ -> halt(1) end.'

clean:
	rm -rf $(EBIN)
