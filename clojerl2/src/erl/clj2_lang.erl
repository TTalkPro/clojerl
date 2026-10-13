%%%-------------------------------------------------------------------
%%% @doc clj2_lang — the language chain of the compiler (designs/01 §1).
%%%
%%% Every language is plain data; later languages are written as a
%%% difference against an earlier one (`extends'), exactly like
%%% nanopass's `(define-language L1 (extends L0) ...)'.
%%%
%%%   lcore ─parse─▶ L0 ─declare─▶ L0 ─resolve─▶ L1 ─validate-recur─▶ L1
%%%         ─lower-loop─▶ L2 ─lower-letfn─▶ L3 ─link─▶ L4 ─const-fold*─▶ L4
%%%         ─normalize-anf─▶ L5 ─verify─▶ L5 ─lower-labs─▶ labs ─emit─▶ absform
%%%
%%% A compile unit is a list of `top' nodes (one namespace).
%%%
%%% Node shape: `{Op, Anno, Field...}', Anno is an `erl_anno()' carrying
%%% the Clojure source position straight through to the BEAM.
%%%-------------------------------------------------------------------
-module(clj2_lang).

-export([get/1, names/0, is_uid/1, is_guard_bif/1]).

-compile({no_auto_import, [get/1]}).

names() -> [l0, l1, l2, l3, l4, l5, labs].

%% @doc The fully expanded language `Name'.
get(Name) ->
    finish(Name, spec(Name)).

%%====================================================================
%% Definitions
%%====================================================================

%% L0 — output of parse: special forms are nodes, symbols are unresolved.
spec(l0) ->
    #{entry => top,
      terminals =>
          #{sym   => fun is_atom/1,
            atom  => fun is_atom/1,
            value => fun(_) -> true end,
            meta  => fun is_map/1,
            class => fun is_atom/1},
      nonterminals =>
          #{top =>
                #{ns_decl => [sym, value, meta],        %% name, [#{ns, as, refer}], #{':doc'}
                  def     => [sym, meta, {opt, expr}],   %% name, metadata, init?
                  eval    => [expr],                     %% any other top-level form
                  %% extend-type: type designator, protocol, methods. The
                  %% driver compiles each into its own impl module
                  %% (designs/03 §4), out of the namespace unit.
                  extend  => [sym, sym, {list, top}],
                  method  => [atom, expr]},              %% an impl module function (a fn*)
            expr =>
                #{const  => [value],
                  sym    => [sym],
                  the_var => [sym],                      %% (var x), #'x: resolved to a constant
                  'if'   => [expr, expr, expr],
                  do     => [{list, expr}, expr],
                  'let'  => [{list, binding}, expr],
                  loop   => [{list, binding}, expr],
                  recur  => [{list, expr}],
                  fn     => [{opt, sym}, {list, clause}],     %% name?, arities
                  letfn  => [{list, binding}, expr],
                  invoke => [expr, {list, expr}],
                  list   => [{list, expr}],                    %% an Erlang list of values
                  throw  => [expr],
                  'try'  => [expr, {list, 'catch'}, {opt, expr}],
                  'case' => [expr, {list, cclause}, {opt, expr}],  %% case*: test, clauses, default?
                  %% receive: clauses, after-timeout?, after-body? (an
                  %% Erlang selective receive; clj2_p_parse:receive_form/3)
                  'receive' => [{list, rclause}, {opt, expr}, {opt, expr}]},
            cclause => #{cclause => [value, expr]},                %% constants (a list), result
            %% pattern (data: {pvar, I} | wild | {plit, V} | {ptuple, Ps} |
            %% {pmap, [{K, P}]} | {ppin, J}), the variables it binds (I-th),
            %% the expressions it matches the value of (~x, J-th), body
            rclause => #{rclause => [value, {list, sym}, {list, expr}, expr]},
            binding => #{bind   => [sym, expr]},
            clause  => #{clause => [{list, sym}, {opt, sym}, expr]},   %% fixed, rest?, body
            'catch' => #{'catch' => [class, sym, expr]}}};

%% L1 — symbols resolved: locals are unique ids, `mod/fun' heads are
%% Erlang remote calls. Every binder becomes a uid.
spec(l1) ->
    {extends, l0,
     #{terminals => #{uid => fun ?MODULE:is_uid/1, atom => fun is_atom/1},
       remove => #{top => [ns_decl], expr => [sym, the_var]},
       add =>
           #{expr =>
                 #{local    => [uid],
                   varref   => [atom, atom, meta],      %% module, var name, var info
                   erl_call => [atom, atom, {list, expr}],
                   fn       => [{opt, uid}, {list, clause}]},
             binding => #{bind => [uid, expr]},
             clause  => #{clause => [{list, uid}, {opt, uid}, expr]},
             rclause => #{rclause => [value, {list, uid}, {list, expr}, expr]},
             'catch' => #{'catch' => [class, uid, expr]}}}};

%% L2 — loop*/recur gone: every fn clause has a name (an Erlang named
%% fun), loop* is an immediately invoked fn, recur is a self call.
spec(l2) ->
    {extends, l1,
     #{remove => #{expr => [loop, recur]},
       add =>
           #{expr   => #{self_call => [uid, {list, expr}]},
             clause => #{clause => [uid, {list, uid}, {opt, uid}, expr]}}}};

%% L3 — letfn* gone: mutually recursive fns become one named "group"
%% fun indexed by member number (no lambda lifting needed).
spec(l3) ->
    {extends, l2,
     #{terminals => #{index => fun(I) -> is_integer(I) andalso I > 0 end},
       remove => #{expr => [letfn]},
       add =>
           #{expr =>
                 #{fn_group  => [uid, {list, expr}],
                   group_ref => [uid, index]}}}};

%% L4 — vars linked: direct calls to var functions, accessor calls for
%% value vars, fun values for fn vars used as values.
spec(l4) ->
    {extends, l3,
     #{remove => #{expr => [varref]},
       add =>
           #{expr =>
                 #{call_var => [atom, atom, {list, expr}],     %% M:Name(Args), local if M is the unit's
                   fn_var   => [atom, atom, value, value]}}}};  %% fixed arities, variadic min | nil

%% L5 — A-normal form: every argument position holds a trivial
%% expression (a local or a constant), so evaluation order is explicit
%% (Clojure is left to right; Erlang leaves argument order unspecified)
%% and the test of `if'/`case' can be used in guards. An invoke head is
%% trivial or a fn literal.
spec(l5) ->
    {extends, l4,
     #{remove => #{expr => [local, const]},
       includes => #{expr => [triv]},
       add =>
           #{triv => #{local => [uid], const => [value]},
             expr =>
                 #{'if'      => [triv, expr, expr],
                   'case'    => [triv, {list, cclause}, {opt, expr}],
                   invoke    => [expr, {list, triv}],
                   erl_call  => [atom, atom, {list, triv}],
                   call_var  => [atom, atom, {list, triv}],
                   self_call => [uid, {list, triv}],
                   list      => [{list, triv}],
                   throw     => [triv],
                   'receive' => [{list, rclause}, {opt, triv}, {opt, expr}]},
             rclause => #{rclause => [value, {list, uid}, {list, triv}, expr]}}}};

%% Labs — one node per absform construct (designs/02 §2). Every
%% Clojure-level decision is made by lower-labs; emit only serializes.
%% Guards are their own sublanguage (designs/02 §7 risk 1): only
%% variables, literals, operators and guard BIFs, so a non-guard call in
%% a guard is a grammar error here, not an erl_lint error later.
spec(labs) ->
    #{entry => etop,
      terminals =>
          #{atom  => fun is_atom/1,
            int   => fun is_integer/1,
            uid   => fun ?MODULE:is_uid/1,
            value => fun(_) -> true end,
            gbif  => fun ?MODULE:is_guard_bif/1},
      includes => #{e => [eatom], eguard => [eatom]},
      nonterminals =>
          #{etop =>
                #{eattr     => [atom, value],                  %% -Key(Value).
                  efunction => [atom, int, {list, eclause}]},
            eclause =>
                #{eclause => [{list, e}, {list, {list, eguard}}, {list, e}]},  %% patterns, guards, body
            eassoc => #{eassoc => [e, e]},
            eatom =>
                #{evar     => [uid],
                  ewild    => [],
                  elit     => [value]},
            eguard =>
                #{gop      => [atom, {list, eguard}],
                  gcall    => [gbif, {list, eguard}]},
            e =>
                #{eblock   => [{list, e}],
                  ematch   => [e, e],
                  ecall    => [atom, {list, e}],               %% local / auto-imported BIF
                  eremote  => [atom, atom, {list, e}],
                  eapply   => [e, {list, e}],                  %% call a fun value
                  efun     => [{list, eclause}],
                  enamed   => [uid, {list, eclause}],
                  efunref  => [atom, int],                     %% fun f/N
                  eextref  => [atom, atom, int],               %% fun M:f/N
                  ecase    => [e, {list, eclause}],
                  eif      => [{list, eclause}],
                  etry     => [{list, e}, {list, eclause}, {list, e}],
                  etuple   => [{list, e}],
                  ereceive => [{list, eclause}, {opt, e}, {list, e}],  %% clauses, after T?, after body
                  emapp    => [{list, eassoc}],                %% a map pattern (K := P)
                  emap     => [{list, eassoc}],
                  elist    => [{list, e}],
                  eop      => [atom, {list, e}]}}};

spec(Other) ->
    erlang:error({clj2_lang, {unknown_language, Other}}).

is_uid({S, N}) -> is_atom(S) andalso is_integer(N);
is_uid(_) -> false.

is_guard_bif(F) when is_atom(F) ->
    lists:any(fun(N) -> erl_internal:guard_bif(F, N) end, [0, 1, 2, 3]);
is_guard_bif(_) -> false.

%%====================================================================
%% extends
%%====================================================================

finish(Name, {extends, Base, Diff}) ->
    B = ?MODULE:get(Base),
    Ts = maps:merge(maps:get(terminals, B), maps:get(terminals, Diff, #{})),
    NTs0 = maps:get(nonterminals, B),
    NTs1 = maps:fold(fun(NT, Ops, Acc) ->
                         Acc#{NT := maps:without(Ops, maps:get(NT, Acc))}
                     end, NTs0, maps:get(remove, Diff, #{})),
    NTs2 = maps:fold(fun(NT, Ops, Acc) ->
                         maps:update_with(NT, fun(Old) -> maps:merge(Old, Ops) end,
                                          Ops, Acc)
                     end, NTs1, maps:get(add, Diff, #{})),
    Incl = maps:merge_with(fun(_, X, Y) -> lists:usort(X ++ Y) end,
                           maps:get(includes, B, #{}), maps:get(includes, Diff, #{})),
    index(#{name => Name, entry => maps:get(entry, B), includes => Incl,
            terminals => Ts, nonterminals => NTs2});
finish(Name, Spec) ->
    index(Spec#{name => Name}).

index(Lang = #{nonterminals := NTs}) ->
    Idx = maps:fold(
            fun(NT, Ops, Acc) ->
                maps:fold(fun(Op, _, A) ->
                              case A of
                                  #{Op := Other} ->
                                      erlang:error({clj2_lang, {op_in_two_nonterminals, Op, NT, Other}});
                                  _ -> A#{Op => NT}
                              end
                          end, Acc, Ops)
            end, #{}, NTs),
    Lang#{op_index => Idx}.
