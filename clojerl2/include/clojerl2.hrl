%%%-------------------------------------------------------------------
%%% @doc clojerl2 shared compile-time contracts.
%%%
%%% This header is the single place where the *reader <-> compiler*
%%% boundary vocabulary of clojerl2 is spelled out. It is included by
%%% the runtime layer (`src/erl/'), by the compiler driver and by the
%%% tests; nothing here depends on any other clojerl2 module.
%%%
%%% The only term defined here is the source-location wrapper
%%%
%%%     {clj2_loc, Line, Col, Form, Meta}
%%%
%%% mandated by designs/01 §1.1 (Lcore: "Clojure data itself, carrying
%%% {:line :column} metadata") and consumed by designs/02 §4 (the ANNO
%%% discipline: "the reader emits positions, every pass must preserve
%%% them").
%%%
%%% Rules (see notes/reader-format.md for the full contract):
%%%
%%%   * `Line' is 1-based, counted by `\n'.
%%%   * `Col'  is 1-based, counted in Unicode code points, tab == 1.
%%%   * `Form' is the payload, already stripped of its own wrapper.
%%%   * `Meta' is user metadata attached by the `^m' reader macro,
%%%     normalized JVM-Clojure style: always a map or `nil'.
%%%     `^:a' -> `#{':a' => true}', `^sym' -> `#{tag => sym}',
%%%     `^"s"' -> `#{tag => <<"s">>}', `^{:a 1}' -> the map itself
%%%     (keyword keys stay colon-prefixed atoms). Repeated metadata
%%%     merges, outer (first written) winning on key conflicts.
%%%
%%% Wrappers must be removed before data is handed to the macro
%%% expander ({@link clj2_reader:strip/1}).
%%%-------------------------------------------------------------------
-ifndef(CLOJERL2_HRL).
-define(CLOJERL2_HRL, true).

%% The tag atom of the wrapper tuple.
-define(CLJ2_LOC_TAG, clj2_loc).

%% {Line, Col, Form} -> {clj2_loc, Line, Col, Form, nil}
-define(CLJ2_LOC(Line, Col, Form),
        {clj2_loc, Line, Col, Form, nil}).

%% {Line, Col, Form, Meta} -> {clj2_loc, Line, Col, Form, Meta}
-define(CLJ2_LOC_M(Line, Col, Form, Meta),
        {clj2_loc, Line, Col, Form, Meta}).

%% Guard-safe type test.
-define(CLJ2_IS_LOC(Term),
        (is_tuple(Term)
         andalso tuple_size(Term) =:= 5
         andalso element(1, Term) =:= clj2_loc)).

-define(CLJ2_LOC_LINE(Term), element(2, Term)).
-define(CLJ2_LOC_COL(Term),  element(3, Term)).
-define(CLJ2_LOC_FORM(Term), element(4, Term)).
-define(CLJ2_LOC_META(Term), element(5, Term)).

%% {Line, Col} of a wrapped form.
-define(CLJ2_LOC_POS(Term), {element(2, Term), element(3, Term)}).

%% Replace the payload of a wrapper, keeping its position.
-define(CLJ2_LOC_WITH_FORM(Term, Form),
        setelement(4, Term, Form)).

%% Replace the metadata slot of a wrapper, keeping position and payload.
-define(CLJ2_LOC_WITH_META(Term, Meta),
        setelement(5, Term, Meta)).

-endif.
