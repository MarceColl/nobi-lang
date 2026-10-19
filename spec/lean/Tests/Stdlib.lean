import Nobi

/-!
Every example in `test/fixtures/nobi/eval/stdlib.json`, translated to core:
each `lhs == rhs` must type-check to `Bool` and evaluate to `true`.
-/

open Nobi

namespace Tests.Stdlib

def i (n : Int) : Expr := .int n
def s (x : String) : Expr := .str x
def ints (ns : List Int) : Expr := .list .int (ns.map .int)
def strs (xs : List String) : Expr := .list .str (xs.map .str)
def v (x : String) : Expr := .var x
def p (op : String) (targs : List Ty) (args : List Expr) : Expr := .prim op targs args
def fn (ps : List (String × Ty)) (body : Expr) : Expr := .lam ps body
def some (t : Ty) (e : Expr) : Expr := .ctor "Option" "Some" [t] [e]
def none (t : Ty) : Expr := .ctor "Option" "None" [t] []
def opt (t : Ty) : Ty := .named "Option" [t]
def neg (n : Int) : Expr := p "-" [] [i 0, i n]

/-- `lhs == rhs` at type `t` checks to `Bool` and evaluates to `true`. -/
def holds (t : Ty) (lhs rhs : Expr) : Bool :=
  let e := p "==" [t] [lhs, rhs]
  Typing.typeOf {} [] e == .ok .bool && Eval.eval {} 1000 [] e == .ok (.bool true)

-- List
#guard holds (.list .int) (p "List.map" [.int, .int] [ints [1, 2, 3], fn [("x", .int)] (p "*" [] [v "x", i 2])]) (ints [2, 4, 6])
#guard holds (.list .int) (p "List.map" [.str, .int] [strs ["a"], fn [("s", .str)] (p "String.length" [] [v "s"])]) (ints [1])
#guard holds (.list .int) (p "List.filter" [.int] [ints [1, 2, 3, 4], fn [("x", .int)] (p ">" [] [v "x", i 2])]) (ints [3, 4])
#guard holds (.list .int) (p "List.filter" [.int] [ints [1], fn [("x", .int)] (.bool false)]) (ints [])
#guard holds (.list .int) (p "List.append" [.int] [ints [1, 2], i 3]) (ints [1, 2, 3])
#guard holds (.list .int) (p "List.append" [.int] [ints [], i 1]) (ints [1])
#guard holds (.list .int) (p "List.concat" [.int] [ints [1], ints [2, 3]]) (ints [1, 2, 3])
#guard holds (.list .int) (p "List.concat" [.int] [ints [], ints [1]]) (ints [1])
#guard holds .int (p "List.length" [.int] [ints [1, 2, 3]]) (i 3)
#guard holds .int (p "List.length" [.str] [strs ["a"]]) (i 1)
#guard holds .bool (p "List.is_empty" [.int] [p "List.filter" [.int] [ints [1], fn [("x", .int)] (.bool false)]]) (.bool true)
#guard holds .bool (p "List.is_empty" [.int] [ints [1]]) (.bool false)
#guard holds .int (p "List.foldl" [.int, .int] [ints [1, 2, 3], i 0, fn [("x", .int), ("acc", .int)] (p "+" [] [v "acc", v "x"])]) (i 6)
#guard holds .int (p "List.foldl" [.int, .int] [ints [], i 7, fn [("x", .int), ("acc", .int)] (p "+" [] [v "acc", v "x"])]) (i 7)
#guard holds .str (p "List.foldl" [.str, .str] [strs ["a", "b", "c"], s "", fn [("x", .str), ("acc", .str)] (p "++" [] [v "acc", v "x"])]) (s "abc")
#guard holds .int (p "List.sum" [] [ints [1, 2, 3]]) (i 6)
#guard holds .int (p "List.sum" [] [ints []]) (i 0)
#guard holds .int (p "List.sum" [] [.list .int [neg 2, i 2]]) (i 0)
#guard holds (opt .int) (p "List.maximum" [] [ints [1, 3, 2]]) (some .int (i 3))
#guard holds (opt .int) (p "List.maximum" [] [.list .int [neg 5]]) (some .int (neg 5))
#guard holds (opt .int) (p "List.maximum" [] [ints []]) (none .int)
#guard holds (opt .int) (p "List.minimum" [] [ints [3, 1, 2]]) (some .int (i 1))
#guard holds (opt .int) (p "List.minimum" [] [ints []]) (none .int)
#guard holds (.list .int) (p "List.reverse" [.int] [ints [1, 2, 3]]) (ints [3, 2, 1])
#guard holds (.list .str) (p "List.reverse" [.str] [strs ["a", "b"]]) (strs ["b", "a"])
#guard holds .bool (p "List.member" [.int] [ints [1, 2], i 2]) (.bool true)
#guard holds .bool (p "List.member" [.int] [ints [1, 2], i 3]) (.bool false)
#guard holds .bool (p "List.member" [.list .int] [.list (.list .int) [ints [1]], ints [1]]) (.bool true)
#guard holds .bool (p "List.all" [.int] [ints [2, 4], fn [("x", .int)] (p ">" [] [v "x", i 1])]) (.bool true)
#guard holds .bool (p "List.all" [.int] [ints [2, 0], fn [("x", .int)] (p ">" [] [v "x", i 1])]) (.bool false)
#guard holds .bool (p "List.all" [.int] [ints [], fn [("x", .int)] (.bool false)]) (.bool true)
#guard holds .bool (p "List.any" [.int] [ints [1, 5], fn [("x", .int)] (p ">" [] [v "x", i 4])]) (.bool true)
#guard holds .bool (p "List.any" [.int] [ints [], fn [("x", .int)] (.bool true)]) (.bool false)
#guard holds (opt .int) (p "List.head" [.int] [ints [1, 2]]) (some .int (i 1))
#guard holds (opt .int) (p "List.head" [.int] [ints [1]]) (some .int (i 1))
#guard holds (.list .int) (p "List.take" [.int] [ints [1, 2, 3], i 2]) (ints [1, 2])
#guard holds (.list .int) (p "List.take" [.int] [ints [1], i 9]) (ints [1])
#guard holds (.list .int) (p "List.take" [.int] [ints [1], neg 1]) (ints [])
#guard holds (.list .int) (p "List.drop" [.int] [ints [1, 2, 3], i 2]) (ints [3])
#guard holds (.list .int) (p "List.drop" [.int] [ints [1], i 9]) (ints [])
#guard holds (.list .int) (p "List.drop" [.int] [ints [1], neg 1]) (ints [1])
#guard holds (.list .int) (p "List.filter_map" [.str, .int] [strs ["1", "x", "2"], fn [("s", .str)] (p "String.to_int" [] [v "s"])]) (ints [1, 2])
#guard holds (.list .int) (p "List.filter_map" [.str, .int] [strs ["x"], fn [("s", .str)] (p "String.to_int" [] [v "s"])]) (ints [])
#guard holds (.list .int) (p "List.sort_by" [.int] [ints [3, 1, 2], fn [("x", .int)] (v "x")]) (ints [1, 2, 3])
#guard holds (.list .int) (p "List.sort_by" [.int] [ints [1, 2, 3], fn [("x", .int)] (p "-" [] [i 0, v "x"])]) (ints [3, 2, 1])
#guard holds (.list .str) (p "List.sort_by" [.str] [strs ["bb", "a"], fn [("s", .str)] (p "String.length" [] [v "s"])]) (strs ["a", "bb"])
#guard holds (.list .int) (p "List.sort_by" [.int] [ints [], fn [("x", .int)] (v "x")]) (ints [])

-- String
#guard holds .int (p "String.length" [] [s "abc"]) (i 3)
#guard holds .int (p "String.length" [] [s ""]) (i 0)
#guard holds .int (p "String.length" [] [s "👋"]) (i 1)
#guard holds .str (p "String.concat" [] [s "a", s "b"]) (s "ab")
#guard holds .str (p "String.concat" [] [s "", s "a"]) (s "a")
#guard holds .str (p "String.from_int" [] [i 7]) (s "7")
#guard holds .str (p "String.from_int" [] [neg 7]) (s "-7")
#guard holds .str (p "String.from_int" [] [i 0]) (s "0")
#guard holds (opt .int) (p "String.to_int" [] [s "12"]) (some .int (i 12))
#guard holds (opt .int) (p "String.to_int" [] [s "-12"]) (some .int (neg 12))
#guard holds (opt .int) (p "String.to_int" [] [s "0"]) (some .int (i 0))
#guard holds (opt .int) (p "String.to_int" [] [s "1.5"]) (none .int)
#guard holds (opt .int) (p "String.to_int" [] [s "1e3"]) (none .int)
#guard holds (opt .int) (p "String.to_int" [] [s " 1"]) (none .int)
#guard holds (opt .int) (p "String.to_int" [] [s ""]) (none .int)
#guard holds (opt .int) (p "String.to_int" [] [s "abc"]) (none .int)
-- stdlib.json says `None` here, TS's answer (JS numbers lose the last digit).
-- The value fits an i64, and Nobi on the BEAM answers `Some`
-- (`test/nobi/exec/stdlib_test.exs` `@divergent`); so does the spec.
#guard holds (opt .int) (p "String.to_int" [] [s "9007199254740993"]) (some .int (i 9007199254740993))
#guard holds .bool (p "String.is_empty" [] [s ""]) (.bool true)
#guard holds .bool (p "String.is_empty" [] [s " "]) (.bool false)
#guard holds .str (p "String.reverse" [] [s "abc"]) (s "cba")
#guard holds .str (p "String.reverse" [] [s "a👋"]) (s "👋a")
#guard holds .str (p "String.trim" [] [s "  a  "]) (s "a")
#guard holds .str (p "String.trim" [] [s ""]) (s "")
#guard holds .str (p "String.to_upper" [] [s "aB"]) (s "AB")
#guard holds .str (p "String.to_upper" [] [s "1"]) (s "1")
#guard holds .str (p "String.to_lower" [] [s "Ab"]) (s "ab")
#guard holds .bool (p "String.contains" [] [s "abc", s "b"]) (.bool true)
#guard holds .bool (p "String.contains" [] [s "abc", s "d"]) (.bool false)
#guard holds .bool (p "String.contains" [] [s "a", s ""]) (.bool true)
#guard holds .bool (p "String.starts_with" [] [s "abc", s "ab"]) (.bool true)
#guard holds .bool (p "String.starts_with" [] [s "abc", s "b"]) (.bool false)
#guard holds (.list .str) (p "String.split" [] [s "a,b", s ","]) (strs ["a", "b"])
#guard holds (.list .str) (p "String.split" [] [s "a", s ","]) (strs ["a"])
#guard holds (.list .str) (p "String.split" [] [s "a👋", s ""]) (strs ["a", "👋"])
#guard holds .str (p "String.join" [] [strs ["a", "b"], s ", "]) (s "a, b")
#guard holds .str (p "String.join" [] [strs [], s ","]) (s "")
#guard holds .str (p "String.join" [] [strs ["a"], s ","]) (s "a")
#guard holds .str (p "String.slice" [] [s "abcd", i 1, i 3]) (s "bc")
#guard holds .str (p "String.slice" [] [s "abc", i 0, i 9]) (s "abc")
#guard holds .str (p "String.slice" [] [s "abc", i 2, i 1]) (s "")
#guard holds .str (p "String.slice" [] [s "a👋b", i 1, i 2]) (s "👋")

-- Option
#guard holds .int (p "Option.with_default" [.int] [some .int (i 1), i 9]) (i 1)
#guard holds .int (p "Option.with_default" [.int] [p "String.to_int" [] [s "x"], i 0]) (i 0)
#guard holds (opt .int) (p "Option.map" [.int, .int] [some .int (i 2), fn [("x", .int)] (p "*" [] [v "x", i 3])]) (some .int (i 6))
#guard holds (opt .int) (p "Option.map" [.int, .int] [p "String.to_int" [] [s "x"], fn [("x", .int)] (p "*" [] [v "x", i 3])]) (none .int)
#guard holds (opt .int) (p "Option.and_then" [.str, .int] [some .str (s "2"), fn [("s", .str)] (p "String.to_int" [] [v "s"])]) (some .int (i 2))
#guard holds (opt .int) (p "Option.and_then" [.str, .int] [some .str (s "x"), fn [("s", .str)] (p "String.to_int" [] [v "s"])]) (none .int)

/-! Beyond `stdlib.json`: the rules the plan names for each module. -/

-- `String.split` keeps empty pieces; `to_int` stays within i64.
#guard holds (.list .str) (p "String.split" [] [s ",a,,b,", s ","]) (strs ["", "a", "", "b", ""])
#guard holds (.list .str) (p "String.split" [] [s "", s ","]) (strs [""])
#guard holds (.list .str) (p "String.split" [] [s "aaa", s "aa"]) (strs ["", "a"])
#guard holds (opt .int) (p "String.to_int" [] [s "9223372036854775807"]) (some .int (i 9223372036854775807))
#guard holds (opt .int) (p "String.to_int" [] [s "9223372036854775808"]) (none .int)
#guard holds (opt .int) (p "String.to_int" [] [s "-9223372036854775808"]) (some .int (p "-" [] [neg 9223372036854775807, i 1]))
#guard holds (opt .int) (p "String.to_int" [] [s "00000000000000000000001"]) (some .int (i 1))
#guard holds (opt .int) (p "String.to_int" [] [s "+1"]) (none .int)
#guard holds (opt .int) (p "String.to_int" [] [s "-"]) (none .int)
-- `String.slice` clamps; a negative end counts back from the end.
#guard holds .str (p "String.slice" [] [s "abcd", neg 3, neg 1]) (s "abc")
-- `String.trim` strips Unicode white space; case functions are ASCII-only.
#guard holds .str (p "String.trim" [] [s "　a "]) (s "a")
#guard holds .str (p "String.to_upper" [] [s "é"]) (s "é")
-- `List.sum` is checked; `sort_by` is stable; `foldl` calls f(x, acc).
#guard Eval.eval {} 100 [] (p "List.sum" [] [ints [9223372036854775807, 1, -1]]) == .error .overflow
#guard holds (.list .str) (p "List.sort_by" [.str] [strs ["b", "a", "c", "d"], fn [("x", .str)] (i 0)]) (strs ["b", "a", "c", "d"])
#guard holds (.list .str) (p "List.foldl" [.str, .list .str] [strs ["a", "b"], .list .str [], fn [("x", .str), ("acc", .list .str)] (p "List.append" [.str] [v "acc", v "x"])]) (strs ["a", "b"])
-- `List.take`/`drop` clamp the count.
#guard holds (.list .int) (p "List.drop" [.int] [ints [1, 2], neg 9]) (ints [1, 2])
-- `Map.*` work in key order; a later key wins.
def m : Expr := .map .str .int [(s "b", i 2), (s "a", i 1)]
#guard holds (.list .str) (p "Map.keys" [.str, .int] [m]) (strs ["a", "b"])
#guard holds (.list .int) (p "Map.values" [.str, .int] [m]) (ints [1, 2])
#guard holds (.list (.tuple [.str, .int])) (p "Map.to_list" [.str, .int] [m]) (.list (.tuple [.str, .int]) [.tuple [s "a", i 1], .tuple [s "b", i 2]])
#guard holds (opt .int) (p "Map.get" [.str, .int] [m, s "b"]) (some .int (i 2))
#guard holds (opt .int) (p "Map.get" [.str, .int] [m, s "c"]) (none .int)
#guard holds (.map .str .int) (p "Map.put" [.str, .int] [m, s "a", i 9]) (.map .str .int [(s "a", i 9), (s "b", i 2)])
#guard holds (.map .str .int) (p "Map.delete" [.str, .int] [m, s "a"]) (.map .str .int [(s "b", i 2)])
#guard holds .bool (p "Map.has_key" [.str, .int] [m, s "a"]) (.bool true)
#guard holds .int (p "Map.size" [.str, .int] [m]) (i 2)
#guard holds (.map .int .int) (p "Map.from_list" [.int, .int] [.list (.tuple [.int, .int]) [.tuple [i 1, i 1], .tuple [i 1, i 2]]]) (.map .int .int [(i 1, i 2)])
-- `Uuid.parse` takes any case and keeps it lowercase.
#guard holds .str (p "Option.with_default" [.str] [p "Option.map" [.uuid, .str] [p "Uuid.parse" [] [s "AAAAAAAA-0000-4000-8000-00000000000F"], .primRef "Uuid.to_string" []], s "none"]) (s "aaaaaaaa-0000-4000-8000-00000000000f")
#guard holds (opt .uuid) (p "Uuid.parse" [] [s "not-a-uuid"]) (none .uuid)
-- A stdlib function as a value equals itself.
#guard holds (.arrow [.str] .int) (.primRef "String.length" []) (.primRef "String.length" [])
#guard holds (.list .int) (p "List.map" [.str, .int] [strs ["ab", ""], .primRef "String.length" []]) (ints [2, 0])

end Tests.Stdlib
