%%%-------------------------------------------------------------------
%%% @doc Strings, regexes, chars, UUIDs and IO (clojerl2-020).
%%%-------------------------------------------------------------------
-module(clj2_string_io_tests).

-include_lib("eunit/include/eunit.hrl").

ev(Src) ->
    {ok, _} = clj2_core:ensure(),
    clj2_compiler:eval(unicode:characters_to_binary(Src), #{ns => 't.sio'}).

setup() -> {ok, _} = clj2_core:ensure(), clj2_ns:ensure('t.sio').

plain(X) ->
    case clj2_coll:is_vector(X) orelse is_list(X) orelse (is_tuple(X) andalso element(1, X) =:= lazy_seq) of
        true -> [plain(Y) || Y <- clj2_coll:to_list(X)];
        false -> X
    end.

read1(Src) ->
    {ok, [F], _} = clj2_reader:read_all(unicode:characters_to_binary(Src)),
    clj2_form:to_data(F).

%% acceptance: read → print → read gives the same string, multi-byte
%% UTF-8 and escapes included
round_trip_test() ->
    setup(),
    Strings = [<<>>, <<"plain">>, <<"中文"/utf8>>, <<"emoji 😀 and é"/utf8>>,
               <<"tab\there\nnewline \"quoted\" back\\slash">>, <<"\r\n">>,
               <<"混合 mixed \"中\"\n"/utf8>>],
    [begin
         Printed = clj2_print:pr_str(S),
         ?assertEqual(S, read1(Printed)),
         ?assertEqual(Printed, clj2_print:pr_str(read1(Printed)))
     end || S <- Strings],
    %% through the compiler too: a literal evaluates to itself
    ?assertEqual(<<"emoji 😀 and é"/utf8>>, ev("\"emoji 😀 and é\"")),
    %% \uXXXX escapes and char literals are code points
    ?assertEqual(<<"中"/utf8>>, ev("\"\\u4e2d\"")),
    ?assertEqual(16#4E2D, ev("\\u4e2d")),
    ?assertEqual(16#1F600, ev("(first \"😀\")")).

%% acceptance: (binding [*out* w] ...) captures println
out_redirect_test() ->
    setup(),
    ?assertEqual(<<"captured 中\n"/utf8>>,
                 ev("(let [w (clj2_io/string_writer)] (binding [*out* w] (println \"captured\" \"中\")) (clj2_io/contents w))")),
    ?assertEqual(<<"a [1 x]\"q\"\n">>, ev("(with-out-str (print \"a\" [1 \"x\"]) (prn \"q\"))")),
    %% bindings travel: a future's output is captured too
    ?assertEqual(<<"from future">>, ev("(with-out-str @(future (print \"from future\")))")),
    %% *err* is a device like any other
    ?assertEqual(<<"to err">>, ev("(with-out-str (binding [*err* *out*] (binding [*out* *err*] (print \"to err\"))))")),
    ?assertEqual(<<"x=3, y=ok">>, ev("(with-out-str (printf \"x=%d, y=%s\" 3 \"ok\"))")).

in_redirect_test() ->
    setup(),
    ?assertEqual([<<"line1">>, <<"第二行"/utf8>>, <<"last">>, nil],
                 plain(ev("(with-in-str \"line1\\n第二行\\r\\nlast\" [(read-line) (read-line) (read-line) (read-line)])"))).

regex_test() ->
    setup(),
    ?assertEqual([<<"12-34">>, <<"12">>, <<"34">>], plain(ev("(re-find #\"(\\d+)-(\\d+)\" \"ab 12-34 cd\")"))),
    ?assertEqual(<<"ab">>, ev("(re-matches #\"a|ab\" \"ab\")")),        % the whole input, not the first alternative
    ?assertEqual(nil, ev("(re-matches #\"a\" \"ab\")")),
    %% \w is ASCII, as in java.util.regex; \p{L} is every letter
    ?assertEqual([<<"abc">>], plain(ev("(re-seq #\"\\w+\" \"中文 abc\")"))),
    ?assertEqual([<<"中文"/utf8>>, <<"abc">>], plain(ev("(re-seq #\"\\p{L}+\" \"中文 abc\")"))),
    ?assertEqual([<<"x">>, <<"x">>, nil], plain(ev("(re-find #\"(x)|(y)\" \"x\")"))),   % unmatched group: nil
    ?assertEqual([<<"1">>, <<"2">>, nil], plain(ev("(let [m (re-matcher #\"\\d\" \"a1b2\")] [(re-find m) (re-find m) (re-find m)])"))),
    ?assertEqual(<<"#\"a\\d\"">>, clj2_print:pr_str(ev("#\"a\\d\""))),
    ?assertError({clj2_compile, _, {syntax, {bad_regex, <<"(">>, _}}}, ev("#\"(\"")),
    ?assertError({'clojure.lang.ExceptionInfo', _, _}, ev("(re-pattern \"(\")")).

clojure_string_test() ->
    setup(),
    ?assertEqual(<<"ABC 中"/utf8>>, ev("(clojure.string/upper-case \"abc 中\")")),
    ?assertEqual([<<"a">>, <<"b">>, <<>>, <<"c">>], plain(ev("(clojure.string/split \"a,b,,c,,\" #\",\")"))),
    ?assertEqual([<<"a">>, <<"b,c">>], plain(ev("(clojure.string/split \"a,b,c\" #\",\" 2)"))),
    ?assertEqual(<<"02/01/2024">>, ev("(clojure.string/replace \"2024-01-02\" #\"(\\d+)-(\\d+)-(\\d+)\" \"$3/$2/$1\")")),
    ?assertEqual(<<"[a]-[b]">>, ev("(clojure.string/replace \"a-b\" #\"(?<x>\\w)\" \"[${x}]\")")),
    ?assertEqual(<<"he2o">>, ev("(clojure.string/replace \"hello\" #\"l+\" (fn [m] (str (count m))))")),
    ?assertEqual(<<"x-b">>, ev("(clojure.string/replace-first \"a-b\" #\"\\w\" \"x\")")),
    ?assertEqual(<<"$1">>, ev("(clojure.string/replace \"a\" #\"a\" (clojure.string/re-quote-replacement \"$1\"))")),
    ?assertEqual(2, ev("(clojure.string/index-of \"中文abc\" \"a\")")),
    ?assertEqual(<<"1, , :a">>, ev("(clojure.string/join \", \" [1 nil :a])")),
    ?assertEqual(<<"Hello">>, ev("(clojure.string/capitalize \"hELLO\")")),
    ?assertEqual(true, ev("(clojure.string/blank? \" \\t\\n\")")),
    ?assertEqual(<<"文中"/utf8>>, ev("(clojure.string/reverse \"中文\")")).

chars_uuids_files_test() ->
    setup(),
    ?assertEqual(true, ev("(char? \\a)")),
    ?assertEqual(<<"newline">>, ev("(char-name-string \\newline)")),
    ?assertEqual(<<"\\n">>, ev("(char-escape-string \\newline)")),
    ?assertEqual(true, ev("(uuid? (random-uuid))")),
    ?assertEqual(<<"#uuid \"550e8400-e29b-41d4-a716-446655440000\"">>,
                 clj2_print:pr_str(ev("#uuid \"550E8400-e29b-41d4-a716-446655440000\""))),
    ?assertEqual(true, ev("(= (parse-uuid \"550e8400-e29b-41d4-a716-446655440000\") #uuid \"550e8400-e29b-41d4-a716-446655440000\")")),
    ?assertEqual(nil, ev("(parse-uuid \"nope\")")),
    F = filename:join(os:getenv("TMPDIR", "/tmp"), "clj2_sio_" ++ os:getpid() ++ ".txt"),
    try
        ?assertEqual(<<"中文!"/utf8>>,
                     ev("(do (spit \"" ++ F ++ "\" \"中文\") (spit \"" ++ F ++ "\" \"!\" :append true) (slurp \"" ++ F ++ "\"))"))
    after file:delete(F)
    end.
