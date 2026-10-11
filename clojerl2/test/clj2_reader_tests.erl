%%%-------------------------------------------------------------------
%%% coding: utf-8
%%% @doc eunit suite for the clojerl2 reader (Lcore boundary).
%%%
%%% Every case asserts the full contract at once: the returned position,
%%% the position carried by the `clj2_loc' wrapper, and the stripped
%%% data. Error cases assert the exact `{error, {Line, Col}, _}' shape.
%%%
%%% NOTE: `coding: utf-8' must stay within the first two lines for epp
%%% to honour it, and non-ASCII binary literals must carry an explicit
%%% `/utf8' modifier (a `coding' comment alone makes codepoints >127
%%% land in the binary truncated to latin-1 bytes).
%%%-------------------------------------------------------------------
-module(clj2_reader_tests).

-include_lib("eunit/include/eunit.hrl").
-include("clojerl2.hrl").

%%%====================================================================
%% Helpers
%%%====================================================================

%% {Src, Loc, Value}: read Src, expect Loc, and Value once stripped.
form({Src, Loc, Value}) ->
    case clj2_reader:read(Src, #{}) of
        {ok, Form, Loc, <<>>} ->
            ?assertEqual(Loc, clj2_reader:loc(Form)),
            ?assertEqual(Value, clj2_reader:strip(Form));
        Other ->
            erlang:error({unexpected_result, Src, Loc, Other})
    end;
%% Read a multi-line source and check the unread remainder as well.
form({Src, Loc, Value, Rest}) ->
    case clj2_reader:read(Src, #{}) of
        {ok, Form, Loc, Rest} ->
            ?assertEqual(Value, clj2_reader:strip(Form));
        Other ->
            erlang:error({unexpected_result, Src, Loc, Other})
    end.

%% {Src, Loc}: expect `{error, Loc, Msg}'.
err({Src, Loc}) ->
    case clj2_reader:read(Src, #{}) of
        {error, Loc, Msg} when is_binary(Msg), byte_size(Msg) > 0 -> ok;
        Other ->
            erlang:error({unexpected_error, Src, Loc, Other})
    end.

fnterm(Args, Body) ->
    {fnstar, [], [{arity, [], [{vector, [], Args}, Body]}]}.

all_forms(Cases) ->
    [?_test(form(C)) || C <- Cases].

%%%====================================================================
%% Leaves: nil, booleans, symbols, keywords
%%%====================================================================

leaves_test_() ->
    all_forms(
      [ {<<"nil">>,   {1,1}, nil}
      , {<<"true">>,  {1,1}, true}
      , {<<"false">>, {1,1}, false}
      , {<<"x">>,     {1,1}, 'x'}
      , {<<"foo-bar">>, {1,1}, 'foo-bar'}
      , {<<"ns/name">>, {1,1}, 'ns/name'}
      , {<<">=">>,    {1,1}, '>='}
      , {<<"*ns*">>,  {1,1}, '*ns*'}
      , {<<"+">>,     {1,1}, '+'}
      , {<<"-">>,     {1,1}, '-'}
      , {<<"/">>,     {1,1}, '/'}
      , {<<"a/b">>,   {1,1}, 'a/b'}
      , {<<"x'">>,    {1,1}, 'x\''}
      , {<<"foo#bar">>, {1,1}, 'foo#bar'}
      , {<<"?foo">>,  {1,1}, '?foo'}
      , {<<":foo">>,  {1,1}, ':foo'}
      , {<<"::foo">>, {1,1}, '::foo'}
      , {<<":ns/name">>, {1,1}, ':ns/name'}
      , {<<":a.b/c">>, {1,1}, ':a.b/c'}
      , {<<":+">>,    {1,1}, ':+'}
      , {<<"  42">>,  {1,3}, 42}
      , {<<"\n\nfoo">>, {3,1}, foo}
      , {<<";; a comment\nfoo">>, {2,1}, foo}
      , {<<"foo;; trailing comment">>, {1,1}, foo, <<";; trailing comment">>}
      , {<<"foo , bar">>, {1,1}, foo, <<" , bar">>}
      ]).

%%%====================================================================
%% Numbers
%%%====================================================================

integers_test_() ->
    all_forms(
      [ {<<"0">>,      {1,1}, 0}
      , {<<"1">>,      {1,1}, 1}
      , {<<"-1">>,     {1,1}, -1}
      , {<<"+1">>,     {1,1}, 1}
      , {<<"007">>,    {1,1}, 7}
      , {<<"123456789012345678901234567890">>, {1,1},
         123456789012345678901234567890}
      , {<<"0x1F">>,   {1,1}, 31}
      , {<<"0Xff">>,   {1,1}, 255}
      , {<<"-0x10">>,  {1,1}, -16}
      , {<<"+0x10">>,  {1,1}, 16}
      , {<<"0o17">>,   {1,1}, 15}
      , {<<"0b1010">>, {1,1}, 10}
      , {<<"0B11">>,   {1,1}, 3}
      , {<<"2r1010">>, {1,1}, 10}
      , {<<"8r17">>,   {1,1}, 15}
      , {<<"16rFF">>,  {1,1}, 255}
      , {<<"36rZZ">>,  {1,1}, 1295}
      , {<<"-2r101">>, {1,1}, -5}
      , {<<"10r999">>, {1,1}, 999}
      ]).

%% BEAM integers are arbitrary precision, so the `N' marker adds nothing.
bigints_test_() ->
    all_forms(
      [ {<<"123N">>,      {1,1}, 123}
      , {<<"-123N">>,     {1,1}, -123}
      , {<<"2r1010N">>,   {1,1}, 10}
      ]).

floats_test_() ->
    all_forms(
      [ {<<"1.5">>,    {1,1}, 1.5}
      , {<<"-1.5">>,   {1,1}, -1.5}
      , {<<"+1.5">>,   {1,1}, 1.5}
      , {<<".5">>,     {1,1}, 0.5}
      , {<<"-.5">>,    {1,1}, -0.5}
      , {<<"1.">>,     {1,1}, 1.0}
      , {<<"1e3">>,    {1,1}, 1000.0}
      , {<<"1E3">>,    {1,1}, 1000.0}
      , {<<"1e-3">>,   {1,1}, 0.001}
      , {<<"1.5e-3">>, {1,1}, 0.0015}
      , {<<"1.5e+3">>, {1,1}, 1500.0}
      , {<<"3.14">>,   {1,1}, 3.14}
      ]).

%% BigDecimal: BEAM has none, so the literal is kept as a tagged form.
bigdec_test_() ->
    all_forms(
      [ {<<"1M">>,   {1,1}, {bigdec, [], <<"1">>}}
      , {<<"1.5M">>, {1,1}, {bigdec, [], <<"1.5">>}}
      , {<<"-1.5M">>, {1,1}, {bigdec, [], <<"-1.5">>}}
      , {<<".5M">>,  {1,1}, {bigdec, [], <<".5">>}}
      , {<<"1.5e3M">>, {1,1}, {bigdec, [], <<"1.5e3">>}}
      ]).

ratios_test_() ->
    all_forms(
      [ {<<"1/2">>,  {1,1}, {ratio, 1, 2}}
      , {<<"-1/2">>, {1,1}, {ratio, -1, 2}}
      , {<<"+1/2">>, {1,1}, {ratio, 1, 2}}
      , {<<"22/7">>, {1,1}, {ratio, 22, 7}}
      , {<<"0/5">>,  {1,1}, {ratio, 0, 5}}
      ]).

%%%====================================================================
%% Characters
%%%====================================================================

chars_test_() ->
    all_forms(
      [ {<<"\\a">>,           {1,1}, 97}
      , {<<"\\A">>,           {1,1}, 65}
      , {<<"\\b">>,           {1,1}, 98}     %% the letter b, not backspace
      , {<<"\\n">>,           {1,1}, 110}
      , {<<"\\newline">>,     {1,1}, 10}
      , {<<"\\space">>,       {1,1}, 32}
      , {<<"\\tab">>,         {1,1}, 9}
      , {<<"\\return">>,      {1,1}, 13}
      , {<<"\\backspace">>,   {1,1}, 8}
      , {<<"\\formfeed">>,    {1,1}, 12}
      , {<<"\\e">>,           {1,1}, 27}
      , {<<"\\f">>,           {1,1}, 12}
      , {<<"\\v">>,           {1,1}, 11}
      , {<<"\\0">>,           {1,1}, 0}
      , {<<"\\(">>,           {1,1}, 40}
      , {<<"\\)">>,           {1,1}, 41}
      , {<<"\\[">>,           {1,1}, 91}
      , {<<"\\x41">>,         {1,1}, 65}
      , {<<"\\x7f">>,         {1,1}, 127}
      , {<<"\\o101">>,        {1,1}, 65}
      , {<<"\\o377">>,        {1,1}, 255}
      , {<<"\\u0041">>,       {1,1}, 65}
      , {<<"\\u00e9">>,       {1,1}, 233}
      , {<<"\\u{1F600}">>,    {1,1}, 128512}
      , {<<"\\u{0}">>,        {1,1}, 0}
      , {<<"\\u{10FFFF}">>,   {1,1}, 1114111}
      , {<<"\\; comment">>,   {1,1}, 59, <<" comment">>}
      ]).

%%%====================================================================
%% Strings
%%%====================================================================

strings_test_() ->
    all_forms(
      [ {<<"\"\"">>,        {1,1}, <<>>}
      , {<<"\"abc\"">>,    {1,1}, <<"abc">>}
      , {<<"\"a b\"">>,    {1,1}, <<"a b">>}
      , {<<"\"\\n\"">>,    {1,1}, <<"\n">>}
      , {<<"\"\\t\"">>,    {1,1}, <<"\t">>}
      , {<<"\"\\r\"">>,    {1,1}, <<"\r">>}
      , {<<"\"\\\\\"">>,   {1,1}, <<"\\">>}
      , {<<"\"\\\"\"">>,   {1,1}, <<"\"">>}
      , {<<"\"\\b\"">>,    {1,1}, <<8>>}
      , {<<"\"\\f\"">>,    {1,1}, <<12>>}
      , {<<"\"\\u00e9\"">>, {1,1}, <<195, 169>>}
      , {<<"\"a\\nb\"">>,  {1,1}, <<"a\nb">>}
      , {<<"\"(\"">>,      {1,1}, <<"(">>}
      ]).

%%%====================================================================
%% Collections
%%%====================================================================

collections_test_() ->
    all_forms(
      [ {<<"()">>,        {1,1}, []}
      , {<<"(1 2)">>,     {1,1}, [1, 2]}
      , {<<"(a b c)">>,   {1,1}, ['a', 'b', 'c']}
      , {<<"(1)">>,       {1,1}, [1]}
      , {<<"[]">>,        {1,1}, {vector, [], []}}
      , {<<"[1 2]">>,     {1,1}, {vector, [], [1, 2]}}
      , {<<"{}">>,        {1,1}, {map, [], []}}
      , {<<"{:a 1}">>,    {1,1}, {map, [], [{':a', 1}]}}
      , {<<"{:a 1 :b 2}">>, {1,1}, {map, [], [{':a', 1}, {':b', 2}]}}
      , {<<"#{}">>,       {1,1}, {set, [], []}}
      , {<<"#{1}">>,      {1,1}, {set, [], [1]}}
      , {<<"#{1 2 3}">>,  {1,1}, {set, [], [1, 2, 3]}}
      ]).

%% Commas are whitespace and a trailing comma is allowed.
commas_test_() ->
    all_forms(
      [ {<<"[1,2]">>,     {1,1}, {vector, [], [1, 2]}}
      , {<<"[1, 2,]">>,   {1,1}, {vector, [], [1, 2]}}
      , {<<"(1, ,2,)">>,  {1,1}, [1, 2]}
      , {<<"{:a 1, :b 2,}">>, {1,1}, {map, [], [{':a', 1}, {':b', 2}]}}
      , {<<"#{1,}">>,     {1,1}, {set, [], [1]}}
      , {<<",,,42,,">>,   {1,4}, 42, <<",,">>}
      ]).

nesting_test_() ->
    all_forms(
      [ {<<"[[1] [2]]">>,   {1,1}, {vector, [], [{vector, [], [1]}, {vector, [], [2]}]}}
      , {<<"#{#{1}}">>,     {1,1}, {set, [], [{set, [], [1]}]}}
      , {<<"{:a [1 #{2}]}">>, {1,1},
         {map, [], [{':a', {vector, [], [1, {set, [], [2]}]}}]}}
      , {<<"((()))">>,      {1,1}, [[[]]]}
      , {<<"[{:a (:b)}]">>, {1,1}, {vector, [], [{map, [], [{':a', [':b']}]}]}}
      ]).

map_keys_test_() ->
    all_forms(
      [ {<<"{\"s\" 1}">>,  {1,1}, {map, [], [{<<"s">>, 1}]}}
      , {<<"{1 :a}">>,     {1,1}, {map, [], [{1, ':a'}]}}
      , {<<"{\\a :a}">>,  {1,1}, {map, [], [{97, ':a'}]}}
      , {<<"{nil 1}">>,    {1,1}, {map, [], [{nil, 1}]}}
      , {<<"{true 1}">>,   {1,1}, {map, [], [{true, 1}]}}
      , {<<"{sym 1}">>,    {1,1}, {map, [], [{sym, 1}]}}
      , {<<"{1/2 1}">>,    {1,1}, {map, [], [{{ratio, 1, 2}, 1}]}}
      , {<<"{'k 1}">>,     {1,1}, {map, [], [{{var, [], k}, 1}]}}
      ]).

%%%====================================================================
%% Quote family, deref, metadata
%%%====================================================================

quote_test_() ->
    all_forms(
      [ {<<"'x">>,        {1,1}, {var, [], x}}
      , {<<"'ns/x">>,    {1,1}, {var, [], 'ns/x'}}
      , {<<"'()">>,      {1,1}, {var, [], []}}
      , {<<"'[1 2]">>,   {1,1}, {var, [], {vector, [], [1, 2]}}}
      , {<<"''x">>,      {1,1}, {var, [], {var, [], x}}}
      , {<<"#'x">>,      {1,1}, {var, [], x}}
      , {<<"`x">>,       {1,1}, {syntax_quote, [], x}}
      , {<<"`(a b)">>,   {1,1}, {syntax_quote, [], [a, b]}}
      , {<<"~x">>,       {1,1}, {unquote, [], x}}
      , {<<"~@x">>,      {1,1}, {unquote_splicing, [], x}}
      , {<<"@a">>,       {1,1}, {deref, [], a}}
      , {<<"@(atom 1)">>, {1,1}, {deref, [], [atom, 1]}}
      , {<<"`(a ~b ~@c)">>, {1,1},
         {syntax_quote, [], [a, {unquote, [], b}, {unquote_splicing, [], c}]}}
      , {<<"`(a ~(b))">>, {1,1},
         {syntax_quote, [], [a, {unquote, [], [b]}]}}
      , {<<"`(1 2)">>,   {1,1}, {syntax_quote, [], [1, 2]}}
      ]).

meta_test_() ->
    all_forms(
      [ {<<"^:a x">>,        {1,5}, x}
      , {<<"^sym x">>,      {1,6}, x}
      , {<<"^\"s\" x">>,    {1,6}, x}
      , {<<"^\\a x">>,      {1,5}, x}
      , {<<"^:a b">>,       {1,5}, b}
      , {<<"^{} (f)">>,     {1,5}, [f]}
      , {<<"^:a :b c">>, {1,5}, ':b', <<" c">>}
      ]).

%% The metadata lands in the wrapper's Meta slot and the *form's* own
%% position is preserved.
meta_slot_test() ->
    {ok, F1, _, <<>>} = clj2_reader:read(<<"^:priv x">>, #{}),
    ?assertEqual(?CLJ2_LOC_M(1, 8, x, #{':priv' => true}), F1),
    {ok, F2, _, <<>>} = clj2_reader:read(<<"^sym x">>, #{}),
    ?assertEqual(?CLJ2_LOC_M(1, 6, x, #{tag => sym}), F2),
    {ok, F3, _, <<>>} = clj2_reader:read(<<"^\\a x">>, #{}),
    ?assertEqual(?CLJ2_LOC_M(1, 5, x, #{tag => 97}), F3),
    {ok, F4, _, <<>>} = clj2_reader:read(<<"^\"str\" x">>, #{}),
    ?assertEqual(?CLJ2_LOC_M(1, 8, x, #{tag => <<"str">>}), F4),
    {ok, F5, _, <<>>} = clj2_reader:read(<<"^{:a 1 :b \"c\"} (f)">>, #{}),
    ?assertEqual(?CLJ2_LOC_M(1, 16, [?CLJ2_LOC_M(1, 17, f, nil)],
                             #{':a' => 1, ':b' => <<"c">>}), F5),
    {ok, F6, _, <<>>} = clj2_reader:read(<<"^:a ^:b x">>, #{}),
    ?assertEqual(?CLJ2_LOC_M(1, 9, x, #{':a' => true, ':b' => true}), F6),
    ok.

%% A metadata form keeps its own position; the payload's wrapper is the
%% one that survives, and read/2 reports the payload's position.
meta_positions_test() ->
    {ok, Form, {2, 3}, <<>>} = clj2_reader:read(<<"^:a\n  (f)">>, #{}),
    ?assertEqual({2, 3}, clj2_reader:loc(Form)),
    ?assertEqual([f], clj2_reader:strip(Form)),
    ?assertEqual(#{':a' => true}, ?CLJ2_LOC_META(Form)).

%%%====================================================================
%% Anonymous functions
%%%====================================================================

fn_test_() ->
    F = fun fnterm/2,
    all_forms(
      [ {<<"#()">>,           {1,1}, F([], [])}
      , {<<"#(a)">>,          {1,1}, F([], [a])}
      , {<<"#(do %1 %2)">>,   {1,1}, F(['%1', '%2'], [do, '%1', '%2'])}
      , {<<"#(do %2)">>,      {1,1}, F(['%1', '%2'], [do, '%2'])}
      , {<<"#(do %2 %1)">>,   {1,1}, F(['%1', '%2'], [do, '%2', '%1'])}
      , {<<"#(do %1 %&)">>,   {1,1}, F(['%1', '%&'], [do, '%1', '%&'])}
      , {<<"#(do %& %&)">>,   {1,1}, F(['%&'], [do, '%&', '%&'])}
      , {<<"#(do % %& %3)">>, {1,1}, F(['%1', '%2', '%3', '%&'], [do, '%1', '%&', '%3'])}
      %% bare `%' is always %1 (Clojure / clojerl 1.0 semantics)
      , {<<"#(do % % %)">>,   {1,1}, F(['%1'], [do, '%1', '%1', '%1'])}
      %% `%1' inside a nested fn* still registers at the #() frame
      , {<<"#(fn* [%1] %1)">>, {1,1}, F(['%1'], ['fn*', {vector, [], ['%1']}, '%1'])}
      , {<<"#([%1])">>,       {1,1}, F(['%1'], [{vector, [], ['%1']}])}
      , {<<"#(\"s\")">>,      {1,1}, F([], [<<"s">>])}
      , {<<"#(do #{%1})">>,   {1,1}, F(['%1'], [do, {set, [], ['%1']}])}
      , {<<"#({:a %1})">>,    {1,1}, F(['%1'], [{map, [], [{':a', '%1'}]}])}
      ]).

%% Nested anonymous functions: the inner frame shadows the outer one.
nested_fn_test() ->
    {ok, Form, _, <<>>} = clj2_reader:read(<<"#(#(inc %1))">>, #{}),
    ?assertEqual(fnterm([], [fnterm(['%1'], [inc, '%1'])]), clj2_reader:strip(Form)).

%% An anonymous fn nested in a collection keeps its own position.
fn_in_collection_test() ->
    %% FnCol = column of the `#'; the body list sits one col later, its
    %% element one col further.
    MkFn = fun(L, FnCol) ->
               fnterm([], ?CLJ2_LOC_M(L, FnCol + 1,
                                      [?CLJ2_LOC_M(L, FnCol + 2, do, nil)], nil))
           end,
    ?assertEqual({ok, ?CLJ2_LOC_M(1, 1, {vector, [], [?CLJ2_LOC_M(1, 2, MkFn(1, 2), nil)]}, nil),
                  {1, 1}, <<>>},
                 clj2_reader:read(<<"[#(do)]">>, #{})),
    ?assertEqual({ok, ?CLJ2_LOC_M(1, 1, [?CLJ2_LOC_M(1, 2, {vector, [], [?CLJ2_LOC_M(1, 3, MkFn(1, 3), nil)]}, nil)], nil), {1, 1}, <<>>},
                 clj2_reader:read(<<"([#(do)])">>, #{})),
    ?assertEqual({ok, ?CLJ2_LOC_M(1, 1, [?CLJ2_LOC_M(1, 2, [?CLJ2_LOC_M(1, 3, MkFn(1, 3), nil)], nil)], nil), {1, 1}, <<>>},
                 clj2_reader:read(<<"((#(do)))">>, #{})),
    ?assertEqual({ok, ?CLJ2_LOC_M(2, 1, MkFn(2, 1), nil), {2, 1}, <<>>},
                 clj2_reader:read(<<"; c\n#(do)">>, #{})),
    {ok, PctForm, _, <<>>} = clj2_reader:read(<<"#([%1])">>, #{}),
    ?assertEqual(fnterm(['%1'], [{vector, [], ['%1']}]),
                 clj2_reader:strip(PctForm)).

%%%====================================================================
%% Dispatch macros
%%%====================================================================

dispatch_test_() ->
    all_forms(
      [ {<<"#\"a\"">>,        {1,1}, {regex, [], <<"a">>}}
      , {<<"#\"\\d+\"">>,   {1,1}, {regex, [], <<"\\d+">>}}
      , {<<"#\"\\\"\"">>,   {1,1}, {regex, [], <<"\\\"">>}}
      , {<<"#\"[a-z]\"">>,  {1,1}, {regex, [], <<"[a-z]">>}}
      , {<<"#inst \"x\"">>,  {1,1}, {tagged, [], inst, <<"x">>}}
      , {<<"#uuid \"x\"">>,  {1,1}, {tagged, [], uuid, <<"x">>}}
      , {<<"#my/tag 1">>,   {1,1}, {tagged, [], 'my/tag', 1}}
      , {<<"#_1 2">>,       {1,5}, 2}
      ]).

discard_test_() ->
    [ ?_assertEqual({eof, {1, 4}}, clj2_reader:read(<<"#_1">>, #{}))
    , ?_assertEqual({eof, {1, 5}}, clj2_reader:read(<<"#_ 1">>, #{}))
    , ?_assertEqual({ok, {vector, [], [1, 3]}, {1, 1}, <<>>},
                    begin
                        {ok, F, L, R} = clj2_reader:read(<<"[1 #_2 3]">>, #{}),
                        {ok, clj2_reader:strip(F), L, R}
                    end)
    , ?_assertMatch({ok, _, {1, 1}, <<>>}, clj2_reader:read(<<"[#_1 2]">>, #{}))
    , ?_assertEqual({map, [], [{':a', 1}]},
                    begin
                        {ok, F2, _, _} = clj2_reader:read(<<"{#_:x :a 1}">>, #{}),
                        clj2_reader:strip(F2)
                    end)
    ].

shebang_test() ->
    ?assertEqual({ok, ?CLJ2_LOC_M(2, 1, 1, nil), {2, 1}, <<>>},
                 clj2_reader:read(<<"#!/usr/bin/env clojerl\n1">>, #{})).

%% `#!` is only a shebang at offset 0; elsewhere it is a tagged literal.
tagged_shebang_test() ->
    {ok, F, _, <<>>} = clj2_reader:read(<<" #!/usr/bin env">>, #{}),
    ?assertEqual({tagged, [], '!/usr/bin', env}, clj2_reader:strip(F)).

symbolic_values_test_() ->
    all_forms(
      [ {<<"##Inf">>,  {1,1}, {tagged, [], 'Inf', nil}}
      , {<<"##-Inf">>, {1,1}, {tagged, [], '-Inf', nil}}
      , {<<"##NaN">>,  {1,1}, {tagged, [], 'NaN', nil}}
      ]).

%% `#:ns{...}` qualifies its keys in the reader.
namespaced_map_test_() ->
    all_forms(
      [ {<<"#:person{:a 1}">>,  {1,1}, {map, [], [{':person/a', 1}]}}
      , {<<"#:person{}">>,     {1,1}, {map, [], []}}
      , {<<"#:a.b/c{:d 1}">>,  {1,1}, {map, [], [{':a.b/c/d', 1}]}}
      , {<<"#::{:a 1}">>,     {1,1}, {map, [], [{'::a', 1}]}}
      , {<<"#:p{:a {:b 1}}">>, {1,1}, {map, [], [{':p/a', {map, [], [{':b', 1}]}}]}}
      ]).

%%%====================================================================
%% Comments
%%%====================================================================

comments_test() ->
    ?assertEqual({ok, ?CLJ2_LOC_M(2, 2, a, nil), {2, 2}, <<>>},
                 clj2_reader:read(<<"; comment\n a">>, #{})),
    ?assertEqual({ok, [a, b], {3, 3}}, stripped_all(<<"; one\n a ;; two\n b">>)),
    ?assertEqual({ok, [1, 2, {vector, [], [3]}], {4, 4}},
                 stripped_all(<<"1 ; one\n2\n;; three\n[3]">>)),
    ?assertEqual({ok, [], {2, 18}}, clj2_reader:read_all(<<"\n ; only a comment">>, #{})),
    ?assertEqual({ok, [], {1, 1}}, clj2_reader:read_all(<<>>, #{})),
    ?assertEqual({ok, [], {2, 3}}, clj2_reader:read_all(<<"  \t\n  ">>, #{})),
    ?assertEqual({ok, [1], {1, 4}}, stripped_all(<<"  1">>)),
    ?assertEqual({ok, [a, b], {2, 2}},
                 stripped_all(<<"a ;; trailing\nb">>)),
    ?assertEqual(1, length(element(2, stripped_all(<<"; one\n a">>)))),
    ok.

stripped_all(Src) ->
    {ok, Forms, Loc} = clj2_reader:read_all(Src, #{}),
    {ok, [clj2_reader:strip(F) || F <- Forms], Loc}.

%%%====================================================================
%% Source positions
%%%====================================================================

payload({clj2_loc, _Line, _Col, Form, _Meta}) -> Form.


%% A deeply nested form: every level carries its own position.
deep_form_test() ->
    Src = <<"(defn f [x]\n"
            "  (let [y (inc x)]\n"
            "    (if (> y 0)\n"
            "      {:ok [y #(+ y 1) \"s\"]}\n"
            "      nil)))">>,
    {ok, Form, {1, 1}, <<>>} = clj2_reader:read(Src, #{}),
    ?assertEqual({1, 1}, clj2_reader:loc(Form)),

    [Defn, Name, Params, DefnBody] = payload(Form),
    ?assertEqual({1, 2}, clj2_reader:loc(Defn)),
    ?assertEqual('defn', clj2_reader:strip(Defn)),
    ?assertEqual({1, 7}, clj2_reader:loc(Name)),
    ?assertEqual(f, clj2_reader:strip(Name)),
    {vector, [], [X]} = payload(Params),
    ?assertEqual({1, 10}, clj2_reader:loc(X)),
    ?assertEqual(x, clj2_reader:strip(X)),

    LetForm = DefnBody,
    ?assertEqual({2, 3}, clj2_reader:loc(LetForm)),
    [Let, LetBindings | LetRest] = payload(LetForm),
    ?assertEqual('let', clj2_reader:strip(Let)),
    {vector, [], [Y, IncCall]} = payload(LetBindings),
    ?assertEqual({2, 9}, clj2_reader:loc(Y)),
    Body = LetRest,
    [Inc, _XArg] = payload(IncCall),
    ?assertEqual({2, 12}, clj2_reader:loc(Inc)),
    ?assertEqual(inc, clj2_reader:strip(Inc)),

    [If, _Cond, Then, Else] = payload(hd(Body)),
    ?assertEqual({3, 6}, clj2_reader:loc(If)),
    ?assertEqual('if', clj2_reader:strip(If)),
    ?assertEqual({4, 7}, clj2_reader:loc(Then)),
    ?assertEqual({5, 7}, clj2_reader:loc(Else)),
    ?assertEqual(nil, clj2_reader:strip(Else)),

    {map, [], [{OkKey, Vec}]} = payload(Then),
    ?assertEqual({4, 8}, clj2_reader:loc(OkKey)),
    ?assertEqual(':ok', clj2_reader:strip(OkKey)),
    {vector, [], [Y2, FnForm, S]} = payload(Vec),
    ?assertEqual({4, 12}, clj2_reader:loc(Vec)),
    ?assertEqual({4, 13}, clj2_reader:loc(Y2)),
    ?assertEqual({4, 15}, clj2_reader:loc(FnForm)),
    ?assertEqual({4, 24}, clj2_reader:loc(S)),
    ?assertEqual(<<"s">>, clj2_reader:strip(S)),
    ?assertEqual(fnterm([], ['+', y, 1]), clj2_reader:strip(FnForm)),
    ok.

positions_test_() ->
    all_forms(
      [ {<<"(a\n  b)">>,   {1, 1}, [a, b]}
      , {<<"[1\n 2\n 3]">>, {1, 1}, {vector, [], [1, 2, 3]}}
      , {<<"{\n :a\n 1}">>, {1, 1}, {map, [], [{':a', 1}]}}
      , {<<"\n\n\n   x">>,  {4, 4}, x}
      , {<<"a\r\nb">>,      {1, 1}, a, <<"\r\nb">>}
      , {<<"\"a\nb\"">>,    {1, 1}, <<"a\nb">>, <<>>}
      ]).

%% Columns are counted in code points, not bytes.
unicode_columns_test() ->
    Src = <<"[\"日本語\" :x \\a]"/utf8>>,
    {ok, Form, {1, 1}, <<>>} = clj2_reader:read(Src, #{}),
    {vector, [], [S, K, C]} = payload(Form),
    ?assertEqual({1, 2}, clj2_reader:loc(S)),
    ?assertEqual(<<"日本語"/utf8>>, clj2_reader:strip(S)),
    ?assertEqual({1, 8}, clj2_reader:loc(K)),
    ?assertEqual({1, 11}, clj2_reader:loc(C)),
    ?assertEqual(':x', clj2_reader:strip(K)),
    ?assertEqual(97, clj2_reader:strip(C)).

%% A multi-byte character is a single column.
unicode_string_test() ->
    {ok, Form, {1, 1}, <<>>} = clj2_reader:read(<<"\"héllo wörld 😀\""/utf8>>, #{}),
    ?assertEqual(<<"héllo wörld 😀"/utf8>>, clj2_reader:strip(Form)),
    ?assertEqual({1, 1}, clj2_reader:loc(Form)),
    {ok, Form2, _, <<>>} = clj2_reader:read(<<"\"h", 195, 169, "llo\"">>, #{}),
    ?assertEqual(<<104, 195, 169, 108, 108, 111>>, clj2_reader:strip(Form2)).

%%%====================================================================
%% API surface
%%%====================================================================

read_rest_test() ->
    {ok, Form, {1, 1}, Rest} = clj2_reader:read(<<"(1) (2)">>, #{}),
    ?assertEqual([1], clj2_reader:strip(Form)),
    ?assertEqual(<<" (2)">>, Rest),
    %% Rest is a fresh input: positions restart at column 1.
    {ok, Form2, {1, 2}, <<>>} = clj2_reader:read(Rest, #{}),
    ?assertEqual([2], clj2_reader:strip(Form2)).

read_eof_test() ->
    ?assertEqual({eof, {1, 1}}, clj2_reader:read(<<>>, #{})),
    %% eof position = where the next read would start (end of input).
    ?assertEqual({eof, {1, 4}}, clj2_reader:read(<<"   ">>, #{})),
    ?assertEqual({ok, [a, b], {3, 1}}, begin
                     {ok, Fs, L} = clj2_reader:read_all(<<"a\nb\n">>, #{}),
                     {ok, [clj2_reader:strip(F) || F <- Fs], L}
                 end),
    ?assertEqual({eof, {3, 1}}, clj2_reader:read(<<"; x\n\n">>, #{})),
    %% the first read consumed everything
    ?assertEqual({ok, ?CLJ2_LOC_M(1, 1, 1, nil), {1, 1}, <<>>},
                 clj2_reader:read(<<"1">>, #{})),
    ?assertEqual({eof, {1, 1}}, clj2_reader:read(<<>>, #{})),
    {ok, DiscardForms, DiscardLoc} = clj2_reader:read_all(<<"#_1 2 3">>, #{}),
    ?assertEqual([2, 3], [clj2_reader:strip(F) || F <- DiscardForms]),
    ?assertEqual({1, 8}, DiscardLoc).

read_file_opt_test() ->
    ?assertEqual({error, {1, 5}, <<"f.clj: EOF while reading string">>},
                 clj2_reader:read(<<"\"abc">>, #{file => "f.clj"})),
    ?assertEqual({error, {1, 5}, <<"EOF while reading string">>},
                 clj2_reader:read(<<"\"abc">>, #{file => undefined})),
    ?assertMatch({error, {1, 5}, _}, clj2_reader:read(<<"\"abc">>, [{file, <<"g.clj">>}])).

loc_test() ->
    ?assertEqual({1, 1}, clj2_reader:loc(?CLJ2_LOC_M(1, 1, x, nil))),
    ?assertEqual({7, 3}, clj2_reader:loc(?CLJ2_LOC_M(7, 3, x, m))),
    ?assertEqual(nil, clj2_reader:loc(x)),
    ?assertEqual(nil, clj2_reader:loc([1, 2])),
    ?assertEqual(nil, clj2_reader:loc({vector, [], []})),
    ?assertEqual(nil, clj2_reader:loc(undefined)).

strip_test_() ->
    [ ?_assertEqual([1, 2], clj2_reader:strip([?CLJ2_LOC_M(1, 2, 1, nil),
                                               ?CLJ2_LOC_M(1, 4, 2, nil)]))
    , ?_assertEqual({vector, [], [1]}, clj2_reader:strip(?CLJ2_LOC_M(1, 1, {vector, [],
                                     [?CLJ2_LOC_M(1, 2, 1, nil)]}, nil)))
    , ?_assertEqual({map, [], [{a, 1}]},
                    clj2_reader:strip(?CLJ2_LOC_M(1, 1, {map, [],
                                     [{{clj2_loc, 1, 2, a, nil},
                                       {clj2_loc, 1, 4, 1, nil}}]}, nil)))
      %% idempotent
    , ?_assertEqual([1], clj2_reader:strip(clj2_reader:strip(
                                      ?CLJ2_LOC_M(1, 1, [?CLJ2_LOC_M(1, 2, 1, nil)], nil))))
      %% tolerant of bare (macro generated) forms
    , ?_assertEqual([1, {vector, [], [2]}], clj2_reader:strip([1, {vector, [], [2]}]))
    , ?_assertEqual('x', clj2_reader:strip('x'))
    , ?_assertEqual(1, clj2_reader:strip(1))
    , ?_assertEqual(<<1, 2>>, clj2_reader:strip(<<1, 2>>))
    , ?_assertEqual({ratio, 1, 2}, clj2_reader:strip({ratio, 1, 2}))
    , ?_assertEqual(fnterm([], []),
                    begin
                        {ok, F1, _, _} = clj2_reader:read(<<"#()">>, #{}),
                        clj2_reader:strip(F1)
                    end)
    , ?_assertEqual({regex, [], <<"\\d">>},
                    begin
                        {ok, F2, _, _} = clj2_reader:read(<<"#\"\\d\"">>, #{}),
                        clj2_reader:strip(F2)
                    end)
    , ?_assertEqual({set, [], [{set, [], [1]}]},
                    begin
                        {ok, F3, _, _} = clj2_reader:read(<<"#{#{1}}">>, #{}),
                        clj2_reader:strip(F3)
                    end)
    , ?_assertEqual([1, 2, 3],
                    begin
                        {ok, Forms, _} = clj2_reader:read_all(<<"1 2 3">>, #{}),
                        clj2_reader:strip(Forms)
                    end)
    ].

%%%====================================================================
%% Errors
%%%====================================================================

errors_test_() ->
    [ ?_test(err({<<"\"abc">>,           {1, 5}}))    %% unterminated string
    , ?_test(err({<<"\"a\\">>,           {1, 3}}))    %% dangling escape
    , ?_test(err({<<"\"a\\q\"">>,       {1, 3}}))    %% unknown string escape
    , ?_test(err({<<"\"a\\u00e">>,       {1, 3}}))    %% short \u escape
    , ?_test(err({<<"(1 2">>,           {1, 5}}))    %% EOF in a list
    , ?_test(err({<<"[1 2">>,           {1, 5}}))
    , ?_test(err({<<"{:a 1">>,          {1, 6}}))
    , ?_test(err({<<"#{1 2">>,          {1, 6}}))
    , ?_test(err({<<"#(do %1">>,        {1, 8}}))    %% EOF inside #()
    , ?_test(err({<<"#_">>,              {1, 3}}))    %% EOF after the discard
    , ?_test(err({<<"#\"abc">>,         {1, 6}}))    %% unterminated regex
    , ?_test(err({<<"1abc">>,           {1, 1}}))    %% invalid number
    , ?_test(err({<<"1.2.3">>,          {1, 1}}))
    , ?_test(err({<<"37r10">>,          {1, 1}}))    %% radix out of range
    , ?_test(err({<<"2r112">>,          {1, 1}}))    %% digit outside radix
    , ?_test(err({<<"0xZZ">>,           {1, 1}}))
    , ?_test(err({<<"0o8">>,            {1, 1}}))
    , ?_test(err({<<"0b12">>,           {1, 1}}))
    , ?_test(err({<<"1/0">>,            {1, 1}}))    %% divide by zero
    , ?_test(err({<<"\\nope">>,         {1, 1}}))    %% unknown char escape
    , ?_test(err({<<"\\">>,              {1, 1}}))    %% EOF in a character
    , ?_test(err({<<"\\uZZZZ">>,        {1, 1}}))
    , ?_test(err({<<"\\u{110000}">>,    {1, 1}}))    %% out of Unicode range
    , ?_test(err({<<"\\u{41">>,         {1, 3}}))    %% missing }
    , ?_test(err({<<"\\xZZ">>,          {1, 1}}))
    , ?_test(err({<<"\\o1234">>,        {1, 1}}))
    , ?_test(err({<<"(1 2]">>,          {1, 5}}))    %% unmatched ]
    , ?_test(err({<<"[1 2)">>,          {1, 5}}))    %% unmatched )
    , ?_test(err({<<"{:a 1 2">>,        {1, 8}}))    %% odd map
    , ?_test(err({<<"{:a}">>,           {1, 4}}))
    , ?_test(err({<<"{[1] 1}">>,        {1, 2}}))    %% non literal key
    , ?_test(err({<<"{#{1} 1}">>,       {1, 2}}))
    , ?_test(err({<<"#?(:clj 1)">>,     {1, 2}}))    %% reader conditional
    , ?_test(err({<<"#?(1)">>,          {1, 2}}))
    , ?_test(err({<<"^:a">>,            {1, 4}}))    %% dangling metadata
    , ?_test(err({<<"^">>,              {1, 2}}))
    , ?_test(err({<<"'">>,              {1, 2}}))
    , ?_test(err({<<"~">>,              {1, 2}}))
    , ?_test(err({<<"@">>,              {1, 2}}))
    , ?_test(err({<<")">>,              {1, 1}}))    %% stray delimiter
    , ?_test(err({<<"]">>,              {1, 1}}))
    , ?_test(err({<<"}">>,              {1, 1}}))
    , ?_test(err({<<"%">>,              {1, 2}}))    %% % outside #()
    , ?_test(err({<<"%0">>,             {1, 2}}))
    , ?_test(err({<<"#(%+)">>,          {1, 4}}))    %% %foo rejected
    , ?_test(err({<<"(#">>,             {1, 3}}))    %% EOF in a dispatch
    , ?_test(err({<<"#tag">>,           {1, 5}}))    %% EOF after a tag
    , ?_test(err({<<"#=">>,             {1, 2}}))    %% #= is not supported
    , ?_test(err({<<"##Bogus">>,        {1, 3}}))
    , ?_test(err({<<":">>,              {1, 2}}))    %% keyword without a name
    , ?_test(err({<<"::">>,             {1, 3}}))
    , ?_test(err({<<"#:">>,             {1, 3}}))
    , ?_test(err({<<"#:p">>,            {1, 4}}))    %% namespaced map without {
    , ?_test(err({<<255, 254>>,        {1, 1}}))    %% invalid UTF-8
    , ?_test(err({atom,               {1, 1}}))    %% not a string
    ].

%% Trailing garbage after a closed collection.
trailing_garbage_test_() ->
    [ ?_assertMatch({error, {1, 6}, _}, clj2_reader:read_all(<<"[1 2]]">>, #{}))
    , ?_assertMatch({error, {1, 6}, _}, clj2_reader:read_all(<<"(a b))">>, #{}))
    , ?_assertMatch({error, {1, 7}, _}, clj2_reader:read_all(<<"{:a 1}}}">>, #{}))
    , ?_assertMatch({error, {2, 3}, _},
                    clj2_reader:read_all(<<"1\n2 )">>, #{}))
    , ?_assertMatch({error, {1, 3}, _}, clj2_reader:read_all(<<"1 ]">>, #{}))
    ].

%% Malformed input is rejected, never silently mis-parsed.
unreadable_input_test() ->
    ?assertMatch({error, {1, 1}, _}, clj2_reader:read(<<"\xC3\x28">>, #{})),
    ?assertMatch({error, {1, 1}, _}, clj2_reader:read(12345, #{})),
    ?assertMatch({eof, {1, 1}}, clj2_reader:read([], #{})),
    ?assertEqual({ok, ?CLJ2_LOC_M(1, 1, a, nil), {1, 1}, <<>>},
                 clj2_reader:read("a", #{})).

%%%====================================================================
%% Pure boundary
%%%====================================================================

%% The reader depends on no other clojerl2 module: it is a pure boundary
%% that can be compiled and tested on its own (designs/00 §5).
pure_boundary_test() ->
    {module, clj2_reader} = code:ensure_loaded(clj2_reader),
    Exports = clj2_reader:module_info(exports),
    ?assertEqual([{loc, 1}, {read, 1}, {read, 2}, {read_all, 1}, {read_all, 2},
                  {strip, 1}],
                 lists:sort(Exports) -- [{module_info, 0}, {module_info, 1}]),
    {ok, {clj2_reader, [{imports, Imports}]}} =
        beam_lib:chunks(code:which(clj2_reader), [imports]),
    Clojerl2Deps = [M || {M, _, _} <- Imports,
                        lists:prefix("clj2_", atom_to_list(M))],
    ?assertEqual([], Clojerl2Deps).

%% Nothing but the shared header is included.
includes_test() ->
    {ok, {clj2_reader, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(code:which(clj2_reader), [abstract_code]),
    ?assert(is_list(Forms)).
