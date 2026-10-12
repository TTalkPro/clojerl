%%%-------------------------------------------------------------------
%%% @doc Clojure reader for clojerl2 — the Lcore boundary.
%%%
%%% The reader turns Clojure source text into Clojure data. It is a
%%% *pure* boundary: it depends on no other clojerl2 module, so it can
%%% be compiled and tested in isolation (designs/01 §1.1, designs/00 §5).
%%% Everything downstream -- the parse pass in particular -- consumes
%%% the forms produced here and never the raw text.
%%%
%%% == Value representations (designs/03 §1, D8) ==
%%%
%%% ```
%%%   nil / true / false      atom
%%%   integer / bigint        Erlang integer (arbitrary precision)
%%%   float                    Erlang float
%%%   ratio                    {ratio, Num, Den}
%%%   BigDecimal               {bigdec, [], Bin}          (divergence)
%%%   symbol / keyword         atom
%%%   string                   UTF-8 binary
%%%   character                integer code point
%%%   list                     Erlang list
%%%   vector                   {vector, [], Items}
%%%   map                      {map, [], [{K, V}, ...]}
%%%   set                      {set, [], Items}
%%%   regex                    {regex, [], Bin}
%%%   quote 'x                 [quote, Form]  (the list (quote x))
%%%   var quote #'x            {var, [], Form}
%%%   deref                    {deref, [], Form}
%%%   syntax quote             {syntax_quote, [], Form}
%%%   unquote / unquote-spl.   {unquote, [], Form} / {unquote_splicing, [], Form}
%%%   anonymous fn             {fnstar, [], [{arity, [], [Args, Body]}]}
%%%   record                   {record, [], Name, [{Field, Form}]}
%%%   dispatch literal         {tagged, [], Tag, Form}
%%% '''
%%%
%%% == Source positions ==
%%%
%%% Every form the reader produces is wrapped in
%%% `{@link clojerl2.hrl CLJ2_LOC}' == `{clj2_loc, Line, Col, Form, Meta}'.
%%% Sugar forms (`quote, `deref, `^meta, `~ ...) embed their payload
%%% *unwrapped*; the wrapper of the sugar character is authoritative.
%%% Forms produced by macros are *not* wrapped; consumers must tolerate
%%% bare forms (see notes/reader-format.md, "known limitations").
%%%
%%% == Accepted divergences from JVM Clojure ==
%%%
%%%   * `\e' (27), `\f' (12), `\v' (11), `\0' (0) are escape aliases;
%%%     `\b' is the letter `b' (use `\backspace').
%%%   * `N' suffixed integers are plain Erlang integers.
%%%   * `M' suffixed decimals are `{bigdec, [], Bin}'; BEAM has no
%%%     BigDecimal.
%%%   * `\xHH' is accepted in addition to `\uHHHH'.
%%%   * `#?(...)' / `#?@(...)' reader conditionals select on the
%%%     features `:clje' (clojerl's platform keyword, so a .cljc file
%%%     written for clojerl 1.0 reads the same) and `:default'; the
%%%     `features' option overrides the set.
%%%   * `#:ns{...}' qualifies its keys with `ns' in the reader.
%%%-------------------------------------------------------------------
-module(clj2_reader).

-include("clojerl2.hrl").

%% API
-export([ read/1
        , read/2
        , read_all/1
        , read_all/2
        , strip/1
        , loc/1
        ]).

-export_type([ result/0
             , opt/0
             , pos/0
             ]).

%%====================================================================
%% Types
%%====================================================================

-type pos() :: {pos_integer(), pos_integer()}.
%% @doc 1-based `{Line, Col}'.

-type opt() :: #{file => file:filename_all() | undefined,
                 features => [atom()]} | list().
%% @doc Options: `file' (a name used in error messages) and `features'
%% (the keywords `#?(...)' selects on, as atoms; default `[':clje']').

-type result() :: {ok, term(), pos(), binary()}
                | {eof, pos()}
                | {error, pos(), binary()}.
%% @doc One form, the position it started at, and the unread rest.

%% One argument frame of an enclosing `#()': {Auto, ByIndex, Variadic, Count}.
-type frame() :: {non_neg_integer(),
                  #{pos_integer() => atom()},
                  atom() | undefined,
                  non_neg_integer()}.

-record(st, { src           :: binary()
            , line = 1      :: pos_integer()
            , col  = 1      :: pos_integer()
            , file          :: file:filename_all() | undefined
            , args = []     :: [frame()]
            , features = [':clje'] :: [atom()]
            , edn = false   :: boolean()     % EDN's reader (clojure.edn)
            }).

%%====================================================================
%% Character classes (macros: they are used in guards)
%%====================================================================

-define(IS_WS(C),
        ((C) =:= $, orelse (C) =:= $\s orelse (C) =:= $\t
         orelse (C) =:= $\n orelse (C) =:= $\r orelse (C) =:= $\f)).

%% Terminating characters end a token. This is JVM Clojure's macro set:
%% note that `'`, `#', `~`, `&` and `%' are *not* terminating, so `x'`,
%% `foo#bar` and `:%percent` read as single tokens (`%' only starts an
%% argument at the beginning of a token, read_arg).
-define(IS_MACRO(C),
        ((C) =:= $" orelse (C) =:= $; orelse (C) =:= $@ orelse (C) =:= $^
         orelse (C) =:= $` orelse (C) =:= $~ orelse (C) =:= $( orelse (C) =:= $)
         orelse (C) =:= $[ orelse (C) =:= $] orelse (C) =:= ${ orelse (C) =:= $}
         orelse (C) =:= $\\)).

-define(IS_TERMINATING(C), (?IS_WS(C) orelse ?IS_MACRO(C))).

-define(IS_DIGIT(C), ((C) >= $0 andalso (C) =< $9)).

%%====================================================================
%% API
%%====================================================================

%% @doc Read a single form. See {@link read/2}.
-spec read(binary() | string() | unicode:chardata()) -> result().
read(Src) ->
    read(Src, #{}).

%% @doc Read one form from `Src'.
%%
%% Returns `{ok, Form, {Line, Col}, Rest}' where `Form' carries its own
%% `{@link clojerl2.hrl CLJ2_LOC}' wrapper, `{Line, Col}' is the
%% position the form started at, and `Rest' is the unread remainder
%% (trailing whitespace is *not* consumed). `{eof, Loc}' is returned
%% when only whitespace and comments remain. Malformed input yields
%% `{error, Loc, Msg}' with `Msg' a human readable binary.
-spec read(binary() | string() | unicode:chardata(), opt()) -> result().
read(Src, Opts) ->
    case new_state(Src, Opts) of
        {error, _, _} = Error -> Error;
        {ok, St} -> next_form(St)
    end.

%% @doc Read every form of `Src'. See {@link read_all/2}.
-spec read_all(binary() | string() | unicode:chardata())
              -> {ok, [term()], pos()} | {error, pos(), binary()}.
read_all(Src) ->
    read_all(Src, #{}).

%% @doc Read all forms of `Src', stopping at the first error.
-spec read_all(binary() | string() | unicode:chardata(), opt())
              -> {ok, [term()], pos()} | {error, pos(), binary()}.
read_all(Src, Opts) ->
    case new_state(Src, Opts) of
        {error, _, _} = Error -> Error;
        {ok, St} -> read_all_forms(St, [])
    end.

%% @doc Recursively drop `{@link clojerl2.hrl CLJ2_LOC}' wrappers.
%%
%% Turns a reader tree into the plain data a macro expander expects.
%% Idempotent and tolerant of bare (macro generated) forms. Metadata
%% attached through `^m' does not survive stripping; consumers that
%% need it must read the un-stripped tree.
-spec strip(term()) -> term().
strip({clj2_loc, _Line, _Col, Form, _Meta}) ->
    strip(Form);
strip(L) when is_list(L) ->
    [strip(E) || E <- L];
strip(T) when is_tuple(T) ->
    list_to_tuple([strip(E) || E <- tuple_to_list(T)]);
strip(Other) ->
    Other.

%% strip/1, but a collection that carries metadata keeps its wrapper (the
%% metadata is part of the quoted value: '^:k {:x 1})
strip_keep_meta({clj2_loc, L, C, Form, Meta}) when is_map(Meta), map_size(Meta) > 0, is_tuple(Form),
                                                  (element(1, Form) =:= vector orelse element(1, Form) =:= map
                                                   orelse element(1, Form) =:= set) ->
    {clj2_loc, L, C, strip_keep_meta(Form), Meta};
strip_keep_meta({clj2_loc, _, _, Form, _}) -> strip_keep_meta(Form);
strip_keep_meta(L) when is_list(L) -> [strip_keep_meta(E) || E <- L];
strip_keep_meta(T) when is_tuple(T) -> list_to_tuple([strip_keep_meta(E) || E <- tuple_to_list(T)]);
strip_keep_meta(Other) -> Other.

%% @doc `{Line, Col}' of a possibly wrapped form, or `nil' for a bare
%% form (e.g. one produced by a macro).
-spec loc(term()) -> pos() | nil.
loc({clj2_loc, Line, Col, _Form, _Meta}) -> {Line, Col};
loc(_) -> nil.

%%====================================================================
%% Public API -- internals
%%====================================================================

new_state(Src, Opts) ->
    case to_bin(Src) of
        {error, Msg} -> {error, {1, 1}, Msg};
        {ok, Bin} ->
            {Bin1, Line} = case opt_edn(Opts) of
                               true -> {Bin, 1};               % EDN has no #!
                               false -> skip_shebang(Bin)
                           end,
            {ok, #st{src = Bin1, line = Line, file = opt_file(Opts),
                     features = opt_features(Opts), edn = opt_edn(Opts)}}
    end.

to_bin(Src) when is_binary(Src) ->
    case unicode:characters_to_binary(Src) of
        Bin when is_binary(Bin) -> {ok, Bin};
        _ -> {error, <<"input is not valid UTF-8">>}
    end;
to_bin([]) ->
    {ok, <<>>};
to_bin(Src) when is_list(Src), is_integer(hd(Src)) ->
    to_bin(unicode:characters_to_binary(Src));
to_bin(Src) when is_list(Src) ->
    to_bin(unicode:characters_to_binary(io_lib:printable_unicode_list(Src)));
to_bin(Other) ->
    {error, <<"read/2: expected a binary or a string, got: ",
              (iolist_to_binary(io_lib:format("~p", [Other])))/binary>>}.

opt_file(Opts) when is_map(Opts) ->
    maps:get(file, Opts, undefined);
opt_file(Opts) when is_list(Opts) ->
    case lists:keyfind(file, 1, Opts) of
        {file, File} -> File;
        false -> undefined
    end;
opt_file(_) ->
    undefined.

opt_edn(#{edn := true}) -> true;
opt_edn(_) -> false.

opt_features(#{features := Fs}) when is_list(Fs) -> Fs;
opt_features(Opts) when is_list(Opts) ->
    case lists:keyfind(features, 1, Opts) of
        {features, Fs} when is_list(Fs) -> Fs;
        _ -> [':clje']
    end;
opt_features(_) -> [':clje'].

%% Only a `#!' at offset 0 is a shebang; elsewhere `#!x' is a tagged
%% literal, exactly like JVM Clojure.
skip_shebang(<<"#!", _/binary>> = Bin) ->
    case binary:match(Bin, <<"\n">>) of
        {Pos, 1} -> {binary:part(Bin, Pos + 1, byte_size(Bin) - Pos - 1), 2};
        nomatch -> {<<>>, 2}
    end;
skip_shebang(Bin) ->
    {Bin, 1}.

next_form(St) ->
    case read_form(St) of
        {ok, Form, Loc, St1} -> {ok, Form, Loc, St1#st.src};
        {many, _, Loc, St1} -> splice_err(Loc, St1);
        {eof, St1} -> {eof, pos(St1)};
        {error, _, _} = Error -> Error
    end.

%% `#?@(...)' outside a collection, as JVM Clojure refuses it
splice_err(Loc, St) ->
    {error, Loc, prefix(St, <<"reader conditional splicing not allowed at the top level">>)}.

read_all_forms(St0, Acc) ->
    %% NOTE: must not go through next_form/1 -- that returns the *rest
    %% binary*, while we need to keep the full state (position, fn
    %% frames) across forms.
    case read_form(St0) of
        {ok, Form, _Loc, St1} -> read_all_forms(St1, [Form | Acc]);
        {many, _, Loc, St1} -> splice_err(Loc, St1);
        {eof, St1} -> {ok, lists:reverse(Acc), pos(St1)};
        {error, _, _} = Error -> Error
    end.

%%====================================================================
%% Source position bookkeeping
%%====================================================================

peek(#st{src = <<C/utf8, _/binary>>}) -> {ok, C};
peek(#st{src = <<>>}) -> eof.

pos(#st{line = Line, col = Col}) -> {Line, Col}.

advance(#st{src = <<$\n, Rest/binary>>} = St) ->
    St#st{src = Rest, line = St#st.line + 1, col = 1};
advance(#st{src = <<_/utf8, Rest/binary>>} = St) ->
    St#st{src = Rest, col = St#st.col + 1};
advance(St) ->
    St.

mk_err(St, Msg) ->
    {error, pos(St), prefix(St, Msg)}.

prefix(#st{file = undefined}, Msg) -> Msg;
prefix(#st{file = File}, Msg) ->
    FileBin = case is_binary(File) of
                  true -> File;
                  false -> unicode:characters_to_binary(File)
              end,
    <<FileBin/binary, ": ", Msg/binary>>.

%%====================================================================
%% Whitespace & comments
%%====================================================================

skip_ws(St0) ->
    case peek(St0) of
        {ok, C} when ?IS_WS(C) ->
            skip_ws(advance(St0));
        {ok, $;} ->
            skip_ws(skip_to_eol(advance(St0)));
        _ ->
            St0
    end.

skip_to_eol(St0) ->
    case peek(St0) of
        eof -> St0;
        {ok, $\n} -> St0;
        {ok, $\r} -> St0;                       % \r ends a comment too (JVM)
        {ok, _} -> skip_to_eol(advance(St0))
    end.

%%====================================================================
%% Forms
%%====================================================================
%%
%% read_form/1 returns
%%     {ok, WrappedForm, Loc, St} | {many, [WrappedForm], Loc, St}
%%     | {eof, St} | {error, Loc, Msg}
%% `many' is a `#?@(...)' splice: its forms belong to the enclosing
%% collection (collect/3); anywhere else it is an error.

read_form(St0) ->
    case read_form1(St0) of
        {skip, St1} -> read_form(St1);
        Other -> Other
    end.

%% read_form/1 without the loop: a skipped form (`#_x', a `#?' with no
%% matching feature) comes back as `{skip, St}', so a collection can
%% see its closing delimiter right after one.
read_form1(St0) ->
    St = skip_ws(St0),
    case peek(St) of
        eof ->
            {eof, St};
        {ok, Ch} ->
            Loc = pos(St),
            case read_form0(Ch, St) of
                {skip, St1} -> {skip, St1};
                {many, Forms, St1} -> {many, Forms, Loc, St1};
                {ok, Form, St1} ->
                    %% The returned position always equals loc(Form) --
                    %% for `^m f' that is f's own position, not the `^'.
                    Wrapped = wrap(Loc, Form),
                    {ok, Wrapped, loc(Wrapped), St1};
                {error, _, _} = Error -> Error
            end
    end.

%% `^m f' hands back f's own (meta-carrying) wrapper, so it must not be
%% wrapped again -- otherwise the `^' would shadow f's position.
wrap(_Loc, {clj2_loc, _Line, _Col, _Form, _Meta} = Wrapper) ->
    Wrapper;
wrap({Line, Col}, Form) ->
    ?CLJ2_LOC(Line, Col, Form).

%% EDN (clojure.edn): ' is a symbol constituent; ` ~ @ start nothing
read_form0(Ch, #st{edn = true} = St) when Ch =:= $'; Ch =:= $% -> read_token_form(St);
read_form0(Ch, #st{edn = true} = St) when Ch =:= $`; Ch =:= $~; Ch =:= $@ ->
    mk_err(St, <<"Invalid leading character: ", Ch/utf8>>);
read_form0(Ch, St) ->
    case Ch of
        $'  -> read_quote(St);
        $`  -> read_syntax_quote(St);
        $~  -> read_unquote(St);
        $@  -> read_deref(St);
        $^  -> read_meta(St);
        $%  -> read_arg(St);
        $(  -> read_list(St);
        $[  -> read_vector(St);
        ${  -> read_map(St);
        $"  -> read_string_form(St);
        $\\ -> read_char(St);
        $:  -> read_keyword(St);
        $#  -> read_dispatch(St);
        $)  -> mk_err(St, <<"unexpected delimiter: )">>);
        $]  -> mk_err(St, <<"unexpected delimiter: ]">>);
        $}  -> mk_err(St, <<"unexpected delimiter: }">>);
        _   -> read_token_form(St)
    end.

%%--------------------------------------------------------------------
%% Dispatching read_form0's result
%%--------------------------------------------------------------------

%% Read one already whitespace-skipped form, unpacking errors.
one_form(St) ->
    case read_form(St) of
        {ok, Form, _Loc, St1} -> {ok, Form, St1};
        {many, _, Loc, St1} ->
            {error, Loc, prefix(St1, <<"reader conditional splicing not allowed here">>)};
        {eof, _} -> eof;
        {error, _, _} = Error -> Error
    end.

%%--------------------------------------------------------------------
%% ', `, ~, ~
%%--------------------------------------------------------------------

%% 'x → (quote x), as in Clojure; #'x → {var, [], x} (read_var_quote).
read_quote(St0) ->
    St1 = advance(St0),
    case one_form(St1) of
        eof -> mk_err(St1, <<"EOF while reading form after '">>);
        {error, _, _} = Error -> Error;
        {ok, Form, St2} -> {ok, [quote, strip_keep_meta(Form)], St2}
    end.

read_var_quote(St0) ->
    St1 = advance(St0),
    case one_form(St1) of
        eof -> mk_err(St1, <<"EOF while reading form after #'">>);
        {error, _, _} = Error -> Error;
        {ok, Form, St2} -> {ok, {var, [], strip(Form)}, St2}
    end.

read_syntax_quote(St0) ->
    St1 = advance(St0),
    case one_form(St1) of
        eof -> mk_err(St1, <<"EOF while reading form after `">>);
        {error, _, _} = Error -> Error;
        {ok, Form, St2} -> {ok, {syntax_quote, [], strip(Form)}, St2}
    end.

read_unquote(St0) ->
    St1 = advance(St0),
    case peek(St1) of
        {ok, $@} ->
            St2 = advance(St1),
            case one_form(St2) of
                eof -> mk_err(St2, <<"EOF while reading form after ~@">>);
                {error, _, _} = Error -> Error;
                {ok, Form, St3} -> {ok, {unquote_splicing, [], strip(Form)}, St3}
            end;
        _ ->
            case one_form(St1) of
                eof -> mk_err(St1, <<"EOF while reading form after ~">>);
                {error, _, _} = Error -> Error;
                {ok, Form, St2} -> {ok, {unquote, [], strip(Form)}, St2}
            end
    end.

read_deref(St0) ->
    St1 = advance(St0),
    case one_form(St1) of
        eof -> mk_err(St1, <<"EOF while reading form after @">>);
        {error, _, _} = Error -> Error;
        {ok, Form, St2} -> {ok, {deref, [], strip(Form)}, St2}
    end.

%%--------------------------------------------------------------------
%% ^meta
%%--------------------------------------------------------------------

read_meta(St0) ->
    St1 = advance(St0),
    case one_form(St1) of
        eof -> mk_err(St1, <<"EOF while reading form after ^">>);
        {error, _, _} = Error -> Error;
        {ok, MetaForm, St2} ->
            case one_form(St2) of
                eof -> mk_err(St2, <<"EOF while reading form after metadata">>);
                {error, _, _} = Error -> Error;
                {ok, Form, St3} ->
                    {ok, attach_meta(Form, MetaForm), St3}
            end
    end.

%% The payload's own wrapper is *replaced*: the metadata lands in the
%% wrapper's Meta slot and the form's own position is kept.
attach_meta({clj2_loc, _L, _C, _Form, Meta} = Wrapper, MetaForm) ->
    ?CLJ2_LOC_WITH_META(Wrapper, merge_meta(Meta, meta_value(MetaForm)));
attach_meta(Form, MetaForm) ->
    %% A bare (macro generated) form: keep it usable by wrapping it at
    %% the metadata's position.
    {Line, Col} = loc_or_origin(MetaForm),
    ?CLJ2_LOC_M(Line, Col, Form, meta_value(MetaForm)).

loc_or_origin(Form) ->
    case loc(Form) of
        nil -> {0, 0};
        Pos -> Pos
    end.

merge_meta(nil, New) -> New;
merge_meta(Old, New) when is_map(Old), is_map(New) ->
    maps:merge(Old, New);
merge_meta(_Old, New) -> New.

%% Canonical form: a map literal becomes a real Erlang map with binary
%% keys; any other metadata value is stored verbatim.
%% The metadata value contract (JVM Clojure's): `^:a' -> `#{':a' =>
%% true}', `^sym' -> `#{tag => sym}', `^"s"' -> `#{tag => <<"s">>}',
%% `^{:a 1}' -> the map itself (keys stripped, keywords stay ':a').
%% All values are stripped of location wrappers.
meta_value(MetaForm) ->
    case strip(MetaForm) of
        {map, _M, Pairs} ->
            maps:from_list([{strip(K), strip(V)} || {K, V} <- Pairs]);
        K when is_atom(K) ->
            case atom_to_binary(K, utf8) of
                <<":", _/binary>> -> #{K => true};
                _ -> #{tag => K}
            end;
        Other ->
            #{tag => Other}
    end.

%%--------------------------------------------------------------------
%% % and %1..%9 / %&
%%--------------------------------------------------------------------

%% outside #() a % token is an ordinary symbol (as on the JVM)
read_arg(#st{args = []} = St0) ->
    {Token, St1} = scan_token(advance(St0), [$%]),
    {ok, binary_to_atom(unicode:characters_to_binary(Token)), St1};
read_arg(St0) ->
    St1 = advance(St0),
    case peek(St1) of
        eof ->
            %% Bare `%' is always %1 (JVM Clojure / clojerl 1.0
            %% semantics: `% %' refers to the same argument twice).
            arg_sym(1, St1);
        {ok, $&} ->
            arg_sym(-1, advance(St1));
        {ok, D} when ?IS_DIGIT(D) ->
            {N, St2} = scan_int_digits(St1, 0),
            case N < 1 of
                true -> mk_err(St1, bad_arg_literal(N));
                false -> arg_sym(N, St2)
            end;
        {ok, C} when ?IS_TERMINATING(C) ->
            arg_sym(1, St1);
        {ok, _} ->
            %% `%foo', `%+' ... rejected, exactly like JVM Clojure and
            %% clojerl 1.0 (which fail to parse the digits).
            {Token, _St2} = scan_token(St1, []),
            mk_err(St1, <<"invalid % literal: %", (to_bin_safe(Token))/binary,
                          " (expected %, %& or %1..%N)">>)
    end.

bad_arg_literal(N) ->
    <<"invalid % literal: %", (integer_to_binary(N))/binary,
      " (expected %, %& or %1..%9)">>.

arg_sym(N, #st{args = [Frame | Rest]} = St) ->
    {Frame1, Sym} = frame_arg(Frame, N),
    {ok, Sym, St#st{args = [Frame1 | Rest]}}.

scan_int_digits(St0, Acc) ->
    case peek(St0) of
        {ok, C} when ?IS_DIGIT(C) ->
            scan_int_digits(advance(St0), Acc * 10 + (C - $0));
        _ -> {Acc, St0}
    end.

%% N is -1 (the rest argument), auto (`%') or a 1-based argument index.
frame_arg({Auto, ByIndex, Variadic, Count}, -1) ->
    case Variadic of
        undefined -> {{Auto, ByIndex, '%&', Count}, '%&'};
        Sym -> {{Auto, ByIndex, Variadic, Count}, Sym}
    end;
frame_arg({Auto, ByIndex, Variadic, Count}, auto) ->
    N = Auto + 1,
    case ByIndex of
        #{N := Sym} -> {{N, ByIndex, Variadic, Count}, Sym};
        _ -> fill_args(N, Auto, ByIndex, Variadic, Count)
    end;
frame_arg({Auto, ByIndex, Variadic, Count}, N) ->
    case ByIndex of
        #{N := Sym} -> {{Auto, ByIndex, Variadic, Count}, Sym};
        _ -> fill_args(N, Auto, ByIndex, Variadic, Count)
    end.

%% `%5' registers every argument up to 5, exactly like JVM Clojure.
fill_args(N, Auto, ByIndex, Variadic, Count) when N > Count ->
    ByIndex1 = lists:foldl(
                 fun(K, Acc) -> maps:put(K, arg_name(K), Acc) end,
                 ByIndex,
                 lists:seq(Count + 1, N)),
    {{erlang:max(Auto, N), ByIndex1, Variadic, N}, arg_name(N)};
fill_args(N, _Auto, ByIndex, Variadic, Count) ->
    {{N, ByIndex, Variadic, Count}, maps:get(N, ByIndex, arg_name(N))}.

arg_name(N) -> list_to_atom("%" ++ integer_to_list(N)).

frame_args({_Auto, _ByIndex, undefined, 0}) -> [];
frame_args({_Auto, ByIndex, Variadic, Count}) ->
    lists:append([[maps:get(K, ByIndex) || K <- lists:seq(1, Count)],
                  case Variadic of undefined -> []; _ -> ['&', Variadic] end]).

%%--------------------------------------------------------------------
%% Collections
%%--------------------------------------------------------------------

read_list(St0) ->
    St1 = advance(St0),
    case collect(St1, $), fun read_item/1) of
        {error, _, _} = Error -> Error;
        {ok, Items, St2} -> {ok, Items, St2}
    end.

read_vector(St0) ->
    St1 = advance(St0),
    case collect(St1, $], fun read_item/1) of
        {error, _, _} = Error -> Error;
        {ok, Items, St2} -> {ok, {vector, [], Items}, St2}
    end.

read_map(St0) ->
    St1 = advance(St0),
    case collect(St1, $}, fun read_map_item/1) of
        {error, _, _} = Error -> Error;
        {ok, Pairs, St2} -> {ok, {map, [], Pairs}, St2}
    end.

%% An item of a collection: one form, or the forms a `#?@' splices in.
read_item(St) ->
    case read_form1(St) of
        {eof, _} -> mk_err(St, <<"EOF while reading a collection">>);
        {error, _, _} = Error -> Error;
        {ok, Form, _Loc, St1} -> {ok, Form, St1};
        {many, Forms, _Loc, St1} -> {many, Forms, St1};
        {skip, St1} -> {many, [], St1}
    end.

read_map_item(St) ->
    case read_form1(St) of
        {eof, _} ->
            mk_err(St, <<"EOF while reading collection, expected }">>);
        {error, _, _} = Error -> Error;
        {ok, Key, _Loc, St1} -> read_map_value(Key, St1);
        %% a splice of keys and values
        {many, Forms, _Loc, St1} -> pair_forms(Forms, St1);
        {skip, St1} -> {many, [], St1}
    end.

read_map_value(Key, St) ->
    case skip_ws(St) of
        St1 = #st{src = <<$}/utf8, _/binary>>} ->
            mk_err(St1, <<"map literal must contain an even number of forms">>);
        _ ->
            case read_form1(St) of
                {eof, _} ->
                    mk_err(St, <<"EOF while reading collection, expected }">>);
                {error, _, _} = Error -> Error;
                {skip, St2} -> read_map_value(Key, St2);
                {ok, Val, _Loc, St2} ->
                    %% any form is a key, as in Clojure (`{[x y] :pt}' is how
                    %% map destructuring binds a nested pattern)
                    {ok, {Key, Val}, St2};
                {many, [], _Loc, St2} -> read_map_value(Key, St2);
                {many, [Val | More], _Loc, St2} ->
                    case pair_forms(More, St2) of
                        {many, Pairs, St3} -> {many, [{Key, Val} | Pairs], St3};
                        Error -> Error
                    end
            end
    end.

%% Spliced forms in a map pair up; a key left over takes the next form.
pair_forms([], St) -> {many, [], St};
pair_forms([K], St) ->
    case read_map_value(K, St) of
        {ok, Pair, St1} -> {many, [Pair], St1};
        Other -> Other
    end;
pair_forms([K, V | Rest], St) ->
    case pair_forms(Rest, St) of
        {many, Pairs, St1} -> {many, [{K, V} | Pairs], St1};
        Error -> Error
    end.

collect(St0, Close, ItemFun) ->
    St = skip_ws(St0),
    case peek(St) of
        eof ->
            mk_err(St, <<"EOF while reading collection, expected ", Close/utf8>>);
        {ok, Close} ->
            {ok, [], advance(St)};
        {ok, Other} when Other =:= $); Other =:= $]; Other =:= $} ->
            mk_err(St, <<"unmatched delimiter: ", Other/utf8,
                          " (expected ", Close/utf8, ")">>);
        _ ->
            case ItemFun(St) of
                {error, _, _} = Error -> Error;
                {ok, Item, St1} ->
                    case collect(St1, Close, ItemFun) of
                        {error, _, _} = Error -> Error;
                        {ok, Rest, St2} -> {ok, [Item | Rest], St2}
                    end;
                {many, Items, St1} ->
                    case collect(St1, Close, ItemFun) of
                        {error, _, _} = Error -> Error;
                        {ok, Rest, St2} -> {ok, Items ++ Rest, St2}
                    end
            end
    end.

%%--------------------------------------------------------------------
%% Strings
%%--------------------------------------------------------------------

read_string_form(St0) ->
    St1 = advance(St0),
    case read_string_body(St1, []) of
        {error, _, _} = Error -> Error;
        {ok, Rev, St2} ->
            {ok, to_bin_safe(pair_surrogates(lists:reverse(Rev))), St2}
    end.

%% "\uD83D\uDE00" is one code point, as the JVM's UTF-16 string has it
pair_surrogates([H, L | Rest]) when H >= 16#D800, H =< 16#DBFF, L >= 16#DC00, L =< 16#DFFF ->
    [16#10000 + ((H - 16#D800) bsl 10) + (L - 16#DC00) | pair_surrogates(Rest)];
pair_surrogates([C | Rest]) -> [C | pair_surrogates(Rest)];
pair_surrogates([]) -> [].

read_string_body(St0, Acc) ->
    case peek(St0) of
        eof ->
            mk_err(St0, <<"EOF while reading string">>);
        {ok, $"} ->
            {ok, Acc, advance(St0)};
        {ok, $\\} ->
            case read_escape(St0, advance(St0)) of
                {error, _, _} = Error -> Error;
                {ok, C, St1} -> read_string_body(St1, [C | Acc])
            end;
        {ok, C} ->
            read_string_body(advance(St0), [C | Acc])
    end.

read_escape(Backslash, St0) ->
    case peek(St0) of
        eof -> mk_err(Backslash, <<"EOF while reading string escape">>);
        {ok, C} ->
            St1 = advance(St0),
            case C of
                $\\ -> {ok, $\\, St1};
                $"  -> {ok, $", St1};
                $b  -> {ok, 8, St1};
                $f  -> {ok, 12, St1};
                $n  -> {ok, 10, St1};
                $r  -> {ok, 13, St1};
                $t  -> {ok, 9, St1};
                $u  -> read_unicode_escape(Backslash, St1);
                %% \0 .. \377: an octal escape, as the JVM reader takes
                _ when C >= $0, C =< $7 -> read_octal_escape(Backslash, St1, C - $0, 1);
                _   -> mk_err(Backslash, <<"unsupported escape character in string: \\",
                                              C/utf8>>)
            end
    end.

read_octal_escape(Backslash, St, V, N) when N < 3 ->
    case peek(St) of
        {ok, D} when D >= $0, D =< $7 -> read_octal_escape(Backslash, advance(St), V * 8 + D - $0, N + 1);
        _ -> octal_value(Backslash, V, St)
    end;
read_octal_escape(Backslash, St, V, _) -> octal_value(Backslash, V, St).

octal_value(Backslash, V, _St) when V > 8#377 ->
    mk_err(Backslash, <<"Octal escape sequence must be in range [0, 377].">>);
octal_value(_, V, St) -> {ok, V, St}.

read_unicode_escape(Backslash, St) ->
    {Digits, St1} = scan_hex(St, 4, []),
    case length(Digits) of
        4 ->
            {ok, list_to_integer(Digits, 16), St1};
        _ ->
            mk_err(Backslash, <<"unsupported unicode escape: need exactly 4 hex digits in \\uXXXX">>)
    end.

%%====================================================================
%% Characters
%%====================================================================

read_char(St0) ->
    St1 = advance(St0),
    case peek(St1) of
        eof ->
            mk_err(St0, <<"EOF while reading character">>);
        {ok, C} when ?IS_TERMINATING(C) ->
            %% `\a' where the letter is itself a macro character: `\('.
            {ok, C, advance(St1)};
        {ok, $u} ->
            St2 = advance(St1),
            case peek(St2) of
                {ok, ${} -> read_braced_char(advance(St2), St2, St0);
                _ -> read_char_token(St1, St0)
            end;
        {ok, _} ->
            read_char_token(St1, St0)
    end.

read_char_token(St1, Backslash) ->
    {Token, St2} = scan_token(St1, []),
    edn_constituents(St1, Token,
                     fun() ->
                             case char_value(to_bin_safe(Token), Backslash) of
                                 {error, _, _} = Error -> Error;
                                 {ok, Codepoint} -> {ok, Codepoint, St2}
                             end
                     end).

read_braced_char(St0, Brace, Backslash) ->
    case scan_braced_hex(St0, []) of
        eof ->
            mk_err(Brace, <<"unterminated unicode escape: \\u{ is missing }">>);
        {Digits, St1} ->
            case hex_digits(iolist_to_binary(Digits)) of
                {ok, List} when List =/= [] ->
                    case list_to_integer(List, 16) of
                        V when V =< 16#10FFFF -> {ok, V, St1};
                        _ -> mk_err(Backslash, <<"invalid unicode escape: ",
                                                 "codepoint out of range">>)
                    end;
                _ ->
                    mk_err(Brace, <<"invalid unicode escape: \\u{...} ",
                                   "needs 1..6 hex digits">>)
            end
    end.

scan_braced_hex(St0, Acc) ->
    case peek(St0) of
        eof -> eof;
        {ok, $}} -> {lists:reverse(Acc), advance(St0)};
        {ok, C} ->
            case hex_digits(<<C/utf8>>) of
                {ok, _} -> scan_braced_hex(advance(St0), [C | Acc]);
                error -> mk_err(St0, <<"invalid unicode escape: ",
                                         "expected hex digits inside \\u{...}">>)
            end
    end.

char_value(<<"u{", Rest/binary>>, St) ->
    case binary:split(Rest, <<"}">>) of
        [Digits, <<>>] ->
            case hex_digits(Digits) of
                {ok, List} when List =/= [] ->
                    case list_to_integer(List, 16) of
                        V when V =< 16#10FFFF -> {ok, V};
                        _ -> mk_err(St, <<"invalid unicode escape: codepoint out of range">>)
                    end;
                _ ->
                    mk_err(St, <<"invalid unicode escape: \\u{...} needs 1..6 hex digits">>)
            end;
        _ ->
            mk_err(St, <<"unterminated unicode escape: \\u{ is missing }">>)
    end;
%% `\o', `\x', `\u' alone are the letters (JVM Clojure: `\o' is o)
char_value(<<"o">>, _St) -> {ok, $o};
char_value(<<"x">>, _St) -> {ok, $x};
char_value(<<"u">>, _St) -> {ok, $u};
char_value(<<"u", Rest/binary>>, St) ->
    case hex_digits(Rest) of
        {ok, List} when length(List) =:= 4 -> {ok, list_to_integer(List, 16)};
        _ -> mk_err(St, <<"invalid unicode escape: \\u needs exactly 4 hex digits">>)
    end;
char_value(<<"o", Rest/binary>>, St) ->
    case octal_digits(Rest) of
        {ok, List} when length(List) >= 1, length(List) =< 3 ->
            case list_to_integer(List, 8) of
                V when V =< 8#377 -> {ok, V};
                _ -> mk_err(St, <<"octal escape must be in the range [0, 377]">>)
            end;
        _ ->
            mk_err(St, <<"invalid octal escape: \\o needs 1..3 octal digits">>)
    end;
char_value(<<"x", Rest/binary>>, St) ->
    case hex_digits(Rest) of
        {ok, List} when length(List) =:= 2 -> {ok, list_to_integer(List, 16)};
        _ -> mk_err(St, <<"invalid hex escape: \\x needs exactly 2 hex digits">>)
    end;
char_value(Token, St) ->
    case named_chars() of
        #{Token := Codepoint} -> {ok, Codepoint};
        _ ->
            case Token of
                <<C/utf8>> -> {ok, C};
                _ -> mk_err(St, <<"unsupported character escape: \\", Token/binary>>)
            end
    end.

named_chars() ->
    #{ <<"newline">>   => 10
     , <<"space">>     => 32
     , <<"tab">>       => 9
     , <<"return">>    => 13
     , <<"backspace">> => 8
     , <<"formfeed">>  => 12
     }.
%% (\e \f \v \0 are those characters themselves, as in Clojure)

hex_digits(Bin) ->
    case [C || C <- binary_to_list(Bin),
               (C >= $0 andalso C =< $9)
                   orelse (C >= $a andalso C =< $f)
                   orelse (C >= $A andalso C =< $F)] of
        [] -> error;
        List -> {ok, List}
    end.

octal_digits(Bin) ->
    List = binary_to_list(Bin),
    case List =/= [] andalso lists:all(fun(C) -> C >= $0 andalso C =< $7 end, List) of
        true -> {ok, List};
        false -> error
    end.

scan_hex(St0, 0, Acc) -> {lists:reverse(Acc), St0};
scan_hex(St0, N, Acc) ->
    case peek(St0) of
        {ok, C} when C >= $0, C =< $9 ->
            scan_hex(advance(St0), N - 1, [C | Acc]);
        {ok, C} when C >= $a, C =< $f ->
            scan_hex(advance(St0), N - 1, [C | Acc]);
        {ok, C} when C >= $A, C =< $F ->
            scan_hex(advance(St0), N - 1, [C | Acc]);
        _ -> {lists:reverse(Acc), St0}
    end.

%%====================================================================
%% Keywords
%%====================================================================

read_keyword(St0) ->
    St1 = advance(St0),
    %% Keywords carry their leading colon in the atom: `:foo' -> ':foo',
    %% `::foo' -> '::foo' (auto-resolve, resolved by the expander). A
    %% plain atom would collide with the symbol `foo', and the compiler
    %% must be able to tell self-evaluating keywords apart from symbols.
    {Marker, St2} = read_marker(St1, <<>>),
    case St0#st.edn andalso Marker =/= <<>> of
        true ->
            {Chars0, _} = scan_token(St2, []),
            mk_err(St0, <<"Invalid token: :", Marker/binary, (to_bin_safe(Chars0))/binary>>);
        false -> read_keyword1(St0, Marker, St2)
    end.

read_keyword1(St0, Marker, St2) ->
    case scan_token(St2, []) of
        {[], _} ->
            mk_err(St2, <<"invalid keyword: expected a name after ':'">>);
        {Chars, St3} ->
            %% :/foo and :a/b/c are not keywords
            Name0 = to_bin_safe(Chars),
            BadKw = binary:first(Name0) =:= $/ andalso Name0 =/= <<"/">>
                orelse (length(binary:matches(Name0, <<"/">>)) > 1 andalso not is_ns_slash(Name0)),
            case BadKw of
                true -> mk_err(St0, <<"Invalid token: :", Name0/binary>>);
                false -> edn_constituents(St0, Chars, fun() -> keyword_atom(St2, Marker, Chars, St3) end)
            end
    end.

keyword_atom(St2, Marker, Chars, St3) ->
    begin
            Name = unicode:characters_to_binary([":", Marker, Chars]),
            case atom_name(Name) of
                {ok, Atom} -> {ok, Atom, St3};
                error -> mk_err(St2, <<"invalid keyword: ", Name/binary>>)
            end
    end.

%% EDN: ` ~ @ are not constituents of a token (the source reader ends the
%% token there); a token holding one is an error
edn_constituents(#st{edn = true} = St, Chars, Then) ->
    case [C || C <- Chars, C =:= $@ orelse C =:= $` orelse C =:= $~] of
        [Bad | _] -> mk_err(St, <<"Invalid constituent character: ", Bad/utf8>>);
        [] -> Then()
    end;
edn_constituents(_St, _Chars, Then) -> Then().

read_marker(St, Acc) ->
    case peek(St) of
        {ok, $:} -> read_marker(advance(St), <<Acc/binary, ":">>);
        _ -> {Acc, St}
    end.

atom_name(Name) ->
    try {ok, binary_to_atom(Name, utf8)}
    catch error:badarg -> error
    end.

%%====================================================================
%% Tokens: symbols and numbers
%%====================================================================

read_token_form(St) ->
    case number_start(St) of
        true ->
            {Token, St1} = scan_token(St, []),
            case interpret_number(Token, St) of
                {error, _, _} when St#st.edn ->
                    Bin = to_bin_safe(Token),
                    case re:run(Bin, "^[+-]?[0-9]+/0+$") of
                        {match, _} -> mk_err(St, <<"Divide by zero">>);
                        nomatch -> mk_err(St, <<"Invalid number: ", Bin/binary>>)
                    end;
                {error, _, _} = Error -> Error;
                {ok, Value} -> {ok, Value, St1}
            end;
        false ->
            {Token, St1} = scan_token(St, []),
            edn_constituents(St, Token, fun() -> symbol_token(St, Token, St1) end)
    end.

symbol_token(St, Token, St1) ->
    Bin0 = to_bin_safe(Token),
    %% a name cannot end in / or begin with one, nor hold two (but / and
    %% ns// are names)
    Slashes = length(binary:matches(Bin0, <<"/">>)),
    Bad = byte_size(Bin0) > 1 andalso Bin0 =/= <<"//">> andalso
        (binary:last(Bin0) =:= $/ andalso not is_ns_slash(Bin0) orelse binary:first(Bin0) =:= $/
         orelse (Slashes > 1 andalso not is_ns_slash(Bin0))),
    case Bad of
        true -> mk_err(St, <<"Invalid token: ", Bin0/binary>>);
        false -> symbol_token1(St, Token, St1)
    end.

is_ns_slash(B) -> binary:part(B, byte_size(B) - 2, 2) =:= <<"//">>.

symbol_token1(St, Token, St1) ->
    begin
            case to_bin_safe(Token) of
                <<>> ->
                    mk_err(St, <<"invalid token at this position">>);
                Bin ->
                    case atom_name(Bin) of
                        {ok, Atom} -> {ok, Atom, St1};
                        error -> mk_err(St, <<"invalid token: ", Bin/binary>>)
                    end
            end
    end.

number_start(St) ->
    case peek(St) of
        {ok, C} when C >= $0, C =< $9 -> true;
        {ok, $.} -> next_is_digit(St);
        {ok, S} when S =:= $+; S =:= $- ->
            case peek(advance(St)) of
                {ok, C} when C >= $0, C =< $9 -> true;
                {ok, $.} -> next_is_digit(advance(St));
                _ -> false
            end;
        _ -> false
    end.

next_is_digit(St) ->
    case peek(advance(St)) of
        {ok, C} when C >= $0, C =< $9 -> true;
        _ -> false
    end.

scan_token(St0, Acc) ->
    case peek(St0) of
        %% EDN reads ` ~ @ into the token (and then rejects it)
        {ok, C} when St0#st.edn, (C =:= $@ orelse C =:= $` orelse C =:= $~) ->
            scan_token(advance(St0), [C | Acc]);
        {ok, C} ->
            case ?IS_TERMINATING(C) of
                true -> {lists:reverse(Acc), St0};
                false -> scan_token(advance(St0), [C | Acc])
            end;
        eof ->
            {lists:reverse(Acc), St0}
    end.

interpret_number(Token, St) ->
    Bin = unicode:characters_to_binary(Token),
    case match_number(Bin) of
        {error, Reason} -> mk_err(St, Reason);
        {ok, Value} -> {ok, Value}
    end.

match_number(Bin) ->
    case first_match(Bin, patterns()) of
        {Tag, Captures} -> build_number(Tag, Captures, Bin);
        nomatch -> {error, <<"invalid number: ", Bin/binary>>}
    end.

patterns() ->
    [{ratio,    "^([+-]?[0-9]+)/([0-9]+)$"}
    ,{bigradix, "^([+-]?)([0-9]+)[rR]([0-9A-Za-z]+)[Nn]$"}
    ,{octint,   "^([+-]?)0([0-7]+)[Nn]?$"}         % before bigint: 017N is 15N
    ,{badoct,   "^[+-]?0[0-9]+[Nn]?$"}
    ,{bigint,   "^([+-]?[0-9]+)[Nn]$"}
    ,{bigdec,   "^([+-]?(?:[0-9]+\\.[0-9]*|\\.[0-9]+|[0-9]+)(?:[eE][+-]?[0-9]+)?)[Mm]$"}
    ,{hex,      "^([+-]?)[0][xX]([0-9a-fA-F]+)$"}
    ,{oct,      "^([+-]?)[0][oO]([0-7]+)$"}
    ,{bin,      "^([+-]?)[0][bB]([01]+)$"}
    ,{radix,    "^([+-]?)([0-9]+)[rR]([0-9A-Za-z]+)$"}
    ,{float,    "^([+-]?(?:[0-9]+\\.[0-9]*|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?)$"}
    ,{exp,      "^([+-]?)([0-9]+)[eE]([+-]?[0-9]+)$"}
    ,{int,      "^([+-]?[0-9]+)$"}
    ].

first_match(Bin, [{Tag, Re} | Rest]) ->
    %% `list' captures are already character lists, which is what the
    %% number builders below expect.
    case re:run(Bin, Re, [{capture, all_but_first, list}]) of
        {match, Captures} -> {Tag, Captures};
        nomatch -> first_match(Bin, Rest)
    end;
first_match(_Bin, []) ->
    nomatch.

%% a leading 0 is octal, as in Clojure: 017 is 15
build_number(octint, [Sign, Digits], _Bin) ->
    {ok, apply_sign(Sign, list_to_integer(Digits, 8))};
build_number(badoct, [], Bin) ->
    {error, <<"Invalid number: ", Bin/binary>>};
build_number(int, [Digits], _Bin) ->
    {ok, signed_int(Digits)};
build_number(ratio, [Num, Den], _Bin) ->
    Den1 = list_to_integer(Den),
    case Den1 of
        0 -> {error, <<"divide by zero in ratio literal">>};
        %% in lowest terms; a whole number is an integer (4/2 is 2)
        _ ->
            N = signed_int(Num),
            G = gcd(abs(N), Den1),
            case Den1 div G of
                1 -> {ok, N div G};
                D -> {ok, {ratio, N div G, D}}
            end
    end;
build_number(bigint, [Digits], _Bin) ->
    %% BEAM integers are arbitrary precision already.
    {ok, signed_int(Digits)};
build_number(bigdec, [Mant], _Bin) ->
    {ok, {bigdec, [], to_bin_safe(Mant)}};
build_number(hex, [Sign, Digits], _Bin) ->
    {ok, apply_sign(Sign, list_to_integer(Digits, 16))};
build_number(oct, [Sign, Digits], _Bin) ->
    {ok, apply_sign(Sign, list_to_integer(Digits, 8))};
build_number(bin, [Sign, Digits], _Bin) ->
    {ok, apply_sign(Sign, list_to_integer(Digits, 2))};
build_number(radix, [Sign, RadixDigits, Digits], _Bin) ->
    build_radix(Sign, RadixDigits, Digits);
build_number(bigradix, [Sign, RadixDigits, Digits], _Bin) ->
    %% BEAM integers are arbitrary precision, so `2r1010N' == `2r1010'.
    build_radix(Sign, RadixDigits, Digits);
build_number(float, [Text], _Bin) ->
    {ok, to_float(Text)};
build_number(exp, [Sign, Mant, Exp], _Bin) ->
    Text = lists:flatten([Mant, ".0e", Exp]),
    {ok, apply_sign(Sign, to_float(Text))}.

build_radix(Sign, RadixDigits, Digits) ->
    case safe_radix(RadixDigits) of
        {error, Reason} -> {error, Reason};
        {ok, Radix} ->
            try list_to_integer(Digits, Radix) of
                V -> {ok, apply_sign(Sign, V)}
            catch
                error:badarg ->
                    {error, <<"invalid digit for radix ",
                              (to_bin_safe(RadixDigits))/binary,
                              " in: ", (to_bin_safe(Digits))/binary>>}
            end
    end.

signed_int([S | Rest]) when S =:= $+; S =:= $- ->    apply_sign([S], list_to_integer(Rest));
signed_int(Digits) ->
    list_to_integer(Digits).

apply_sign([$-], V) -> -V;
apply_sign(_, V) -> V.

safe_radix(Digits) ->
    case list_to_integer(Digits) of
        R when R >= 2, R =< 36 -> {ok, R};
        _ -> {error, <<"invalid radix: ", (to_bin_safe(Digits))/binary,
                       " (must be between 2 and 36)">>}
    end.

to_float(Text) ->
    Chars = add_leading_zero(unicode:characters_to_list(to_bin_safe(Text))),
    {Mant, Exp} = split_exp(Chars),
    list_to_float(mantissa(Mant) ++ Exp).

add_leading_zero([S, $. | Rest]) when S =:= $+; S =:= $- -> [S, $0, $. | Rest];
add_leading_zero([$. | _] = Chars) -> [$0 | Chars];
add_leading_zero(Chars) -> Chars.

mantissa(Mant) ->
    case lists:splitwith(fun(C) -> C =/= $. end, Mant) of
        {_, []} -> Mant ++ ".0";
        {_, [$.]} -> Mant ++ "0";
        {_, _} -> Mant
    end.

split_exp(Chars) ->
    lists:splitwith(fun(C) -> C =/= $e andalso C =/= $E end, Chars).

to_bin_safe(Chars) when is_binary(Chars) ->
    Chars;
to_bin_safe(Chars) when is_list(Chars) ->
    unicode:characters_to_binary(Chars).

%%====================================================================
%% Dispatch macros: #(...) #{} #"..." #' #_ #? #tag
%%====================================================================

read_dispatch(St0) ->
    St1 = advance(St0),
    case peek(St1) of
        eof -> mk_err(St1, <<"EOF while reading dispatch macro">>);
        %% #<...> is how the JVM prints what cannot be read back
        {ok, $<} -> mk_err(St1, <<"Unreadable form">>);
        %% #! comments to the end of the line (a shebang, anywhere; not EDN)
        {ok, $!} when not St0#st.edn -> {skip, skip_to_eol(St1)};
        {ok, $!} -> mk_err(St1, <<"No dispatch macro for: !">>);
        %% #^ is ^, the old spelling of metadata
        {ok, $^} -> read_meta(St1);
        %% EDN has only sets, discard, namespaced maps, ##, metadata and tags
        {ok, C} when St0#st.edn, (C =:= $" orelse C =:= $( orelse C =:= $' orelse
                                  C =:= $? orelse C =:= $= orelse C =:= $@) ->
            mk_err(St1, <<"No dispatch macro for: ", C/utf8>>);
        {ok, $" } -> read_regex(St1);
        {ok, ${} -> read_set(St1);
        {ok, $(} -> read_fn(St1);
        {ok, $'} -> read_var_quote(St1);
        {ok, $:} -> read_namespaced_map(St1);
        {ok, $#} -> read_symbolic_value(St1);
        {ok, $?} -> read_cond(St1);
        {ok, $_} ->
            St2 = advance(St1),
            case one_form(St2) of
                eof -> mk_err(St2, <<"EOF while reading form after #_">>);
                {error, _, _} = Error -> Error;
                {ok, Discarded, St3} ->
                    %% EDN still reads what #_ discards (its tags must
                    %% resolve): clj2_edn checks these after the read
                    St0#st.edn andalso put(clj2_edn_discards, [Discarded | discards()]),
                    {skip, St3}
            end;
        {ok, C} when C =:= $=; C =:= $^ ->
            mk_err(St1, <<"unsupported dispatch macro: #", C/utf8>>);
        {ok, C} when ?IS_TERMINATING(C) ->
            mk_err(St1, <<"invalid dispatch macro: #", C/utf8>>);
        {ok, _} ->
            {Token, St2} = scan_token(St1, []),
            case atom_name(to_bin_safe(Token)) of
                {ok, Tag} ->
                    case one_form(St2) of
                        eof -> mk_err(St2, <<"EOF while reading form after #",
                                             (to_bin_safe(Token))/binary>>);
                        {error, _, _} = Error -> Error;
                        {ok, Form, St3} -> {ok, {tagged, [], Tag, strip(Form)}, St3}
                    end;
                error ->
                    mk_err(St1, <<"invalid tag: ", (to_bin_safe(Token))/binary>>)
            end
    end.

%% `#?(:feat form ...)' and `#?@(:feat [forms] ...)': every branch is
%% read (as data; a tagged literal of another platform is fine), the
%% first whose feature is one of ours, or `:default', is the result.
%% No match reads as nothing (`skip'); a splice hands its forms to the
%% enclosing collection (`many').
read_cond(St0) ->
    St1 = advance(St0),
    {Splice, St2} = case peek(St1) of
                        {ok, $@} -> {true, advance(St1)};
                        _ -> {false, St1}
                    end,
    St3 = skip_ws(St2),
    case peek(St3) of
        {ok, $(} ->
            case collect(advance(St3), $), fun read_item/1) of
                {error, _, _} = Error -> Error;
                {ok, Items, St4} when length(Items) rem 2 =:= 1 ->
                    mk_err(St4, <<"read-cond requires an even number of forms">>);
                {ok, Items, St4} -> select_cond(Items, Splice, St4)
            end;
        _ -> mk_err(St3, <<"read-cond body must be a list">>)
    end.

select_cond([], false, St) -> {skip, St};
select_cond([], true, St) -> {many, [], St};
select_cond([K, Form | Rest], Splice, St = #st{features = Fs}) ->
    case strip(K) of
        Kw when is_atom(Kw) ->
            case is_keyword(Kw) of
                false -> mk_err(St, <<"feature should be a keyword">>);
                true ->
                    case Kw =:= ':default' orelse lists:member(Kw, Fs) of
                        false -> select_cond(Rest, Splice, St);
                        true when not Splice -> {ok, Form, St};
                        true -> splice_forms(Form, St)
                    end
            end;
        _ -> mk_err(St, <<"feature should be a keyword">>)
    end.

splice_forms({clj2_loc, _, _, Inner, _}, St) -> splice_forms(Inner, St);
splice_forms({vector, [], Items}, St) -> {many, Items, St};
splice_forms(Items, St) when is_list(Items) -> {many, Items, St};
splice_forms(_, St) ->
    mk_err(St, <<"spliced form list in read-cond-splicing must implement ISequential">>).

is_keyword(A) when is_atom(A) ->
    case atom_to_list(A) of
        [$: | _] -> true;
        _ -> false
    end.

read_set(St0) ->
    St1 = advance(St0),
    case collect(St1, $}, fun read_item/1) of
        {error, _, _} = Error -> Error;
        {ok, Items, St2} -> {ok, {set, [], Items}, St2}
    end.

read_regex(St0) ->
    St1 = advance(St0),
    case read_regex_body(St1, []) of
        {error, _, _} = Error -> Error;
        {ok, Rev, St2} -> {ok, {regex, [], to_bin_safe(lists:reverse(Rev))}, St2}
    end.

%% Escapes are kept verbatim: the regex engine interprets them.
read_regex_body(St0, Acc) ->
    case peek(St0) of
        eof -> mk_err(St0, <<"EOF while reading regex">>);
        {ok, $"} -> {ok, Acc, advance(St0)};
        {ok, $\\} ->
            St1 = advance(St0),
            case peek(St1) of
                eof -> mk_err(St1, <<"EOF while reading regex">>);
                {ok, C} -> read_regex_body(advance(St1), [C, $\\|Acc])
            end;
        {ok, C} -> read_regex_body(advance(St0), [C | Acc])
    end.

%% `#' is dispatched with `(' still in the stream -- exactly like JVM
%% Clojure, where `(' is a dispatch macro but not a *macro* character.
%% The body is therefore the single form that follows: `#(+ %1 %2)'
%% reads the list `(+ %1 %2)' as its body, and `#()' reads `()'.
read_fn(St1) ->
    St2 = push_frame(St1),
    case one_form(St2) of
        eof -> mk_err(St2, <<"EOF while reading #(): expected a body form">>);
        {error, _, _} = Error -> Error;
        {ok, Body, St3} ->
            [Frame | _] = St3#st.args,
            St4 = pop_frame(St3),
            {ok, {fnstar, [], [{arity, [], [{vector, [], frame_args(Frame)}, Body]}]},
             St4}
    end.

push_frame(St) -> St#st{args = [{0, #{}, undefined, 0} | St#st.args]}.
pop_frame(St) -> St#st{args = tl(St#st.args)}.

%% `##Inf', `##NaN', `##-Inf': deferred to data-readers.
read_symbolic_value(St0) ->
    St1 = advance(St0),
    {Token, St2} = scan_token(St1, []),
    case to_bin_safe(Token) of
        <<"Inf">> -> {ok, {tagged, [], 'Inf', nil}, St2};
        <<"-Inf">> -> {ok, {tagged, [], '-Inf', nil}, St2};
        <<"NaN">> -> {ok, {tagged, [], 'NaN', nil}, St2};
        Other ->
            mk_err(St1, <<"unknown symbolic value: ##", Other/binary>>)
    end.

%% `#:ns{...}`: the namespace becomes the prefix of every key, applied
%% here (not in the expander) so that the result is plain data.
read_namespaced_map(St1) ->
    {Marker, St2} = read_marker(St1, <<>>),
    {Token, St3} = scan_token(St2, []),
    case namespaced_name(to_bin_safe(Token), Marker) of
        {error, Msg} ->
            mk_err(St2, Msg);
        Ns ->
            case skip_ws(St3) of
                St4 = #st{src = <<${/utf8, _/binary>>} ->
                    St5 = advance(St4),
                    case collect(St5, $}, fun(Rest) -> read_ns_item(Rest, Ns, Marker) end) of
                        {error, _, _} = Error -> Error;
                        {ok, Pairs, St6} -> {ok, {map, [], Pairs}, St6}
                    end;
                _ ->
                    mk_err(St3, <<"expected { after the namespaced map prefix #:">>)
            end
    end.

namespaced_name(<<>>, <<"::">>) -> <<>>;
namespaced_name(<<>>, _) -> {error, <<"invalid namespaced map: expected a namespace">>};
namespaced_name(Name, _) -> Name.

read_ns_item(St, Ns, Marker) ->
    case read_map_item(St) of
        {error, _, _} = Error -> Error;
        {ok, {Key, Val}, St1} -> {ok, {qualify(Key, Ns, Marker), Val}, St1};
        {many, Pairs, St1} -> {many, [{qualify(K, Ns, Marker), V} || {K, V} <- Pairs], St1}
    end.

qualify(Key, <<>>, _Marker) ->
    %% `#::{...}': auto-resolve against the current namespace, deferred
    %% to the expander. Keyword and symbol keys both get the `::' marker.
    case strip(Key) of
        Form when is_atom(Form) ->
            Name = strip_colons(atom_to_binary(Form, utf8)),
            binary_to_atom(<<"::", Name/binary>>, utf8);
        _ ->
            Key
    end;
qualify(Key, Ns, _Marker) ->
    %% `#:ns{...}': qualify now -- the result is plain data. Keyword keys
    %% stay keywords (`:a' -> ':ns/a'), symbol keys stay symbols.
    case strip(Key) of
        Form when is_atom(Form) ->
            Bin = atom_to_binary(Form, utf8),
            {Prefix, Name} = case Bin of
                                 <<":", _/binary>> -> {<<":">>, strip_colons(Bin)};
                                 _ -> {<<>>, Bin}
                             end,
            binary_to_atom(<<Prefix/binary, Ns/binary, "/", Name/binary>>, utf8);
        _ ->
            Key
    end.

strip_colons(Bin) ->
    case Bin of
        <<":", Rest/binary>> -> strip_colons(Rest);
        _ -> Bin
    end.

gcd(A, 0) -> A;
gcd(A, B) -> gcd(B, A rem B).

discards() ->
    case get(clj2_edn_discards) of
        undefined -> [];
        L -> L
    end.
