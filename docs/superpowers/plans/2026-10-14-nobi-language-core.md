# Nobi Language Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure Elixir port of the Rust `nobi` crate: it parses, formats, hashes and incrementally typechecks Nobi source, and runs a universe that promotes staged patches only when the whole image typechecks.

**Architecture:**
- The library lives under `lib/nobi/lang/` and is called only through the `Nobi.Lang` façade.
- Source text becomes an AST of tagged tuples. The canonical text the formatter writes is what gets hashed into a CID.
- Every typecheck goes through a pure, layered salsa memo, so an edit that keeps a signature never rechecks its dependents.
- The universe is a plain struct, ready to become a GenServer's state in piece 2/3.

**Tech Stack:** Elixir 1.19 / OTP 28, ExUnit, `:crypto`, and the built-in `JSON` module for fixtures. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-14-nobi-language-core-design.md`

**Reference implementation:** `~/proj/kinoko-next/crates/yabu`. Every task names the Rust file it ports. Read that file before writing Elixir. Port the *behaviour* and the *rules in its doc comments*, not its memory tricks (`Arc`, big stacks, 16-byte values).

## Global Constraints

- Pure code only. Nothing under `lib/nobi/lang/` starts processes, touches the Repo, does IO, or uses the process dictionary.
- No new deps. Fixtures are read with `JSON.decode!/1` (built into Elixir 1.18+).
- Never `String.to_atom/1` on source. Names stay as strings. AST kinds and operators come from a closed atom set written in the parser.
- `cid = :crypto.hash(:sha256, "yabu/1\n" <> canonical_text) |> Base.encode16(case: :lower)`.
- References between declarations are by fully qualified name, never by CID.
- Error codes are spelled exactly as the oracle spells them: `"unbound"`, `"mismatch"`, `"arity"`, `"occurs"`, `"not-a-function"`, `"unknown-field"`, `"missing-field"`, `"extra-field"`, `"not-a-model"`, `"non-exhaustive"`, `"bad-pattern"`, `"cannot-infer"`, `"invalid-model-field"`, `"non-data-map-key"`, `"bad-app-shape"`, `"bad-event"`, `"bad-name"`, `"type-too-large"`, `"internal"`.
- A reason is `%{name: String.t() | nil, code: String.t(), message: String.t()}`. Besides the checker codes, the parser and universe add `"parse"`, `"duplicate"` (a name defined twice in one patch) and `"bad-id"` (the empty patch id). A staged patch that would break a committed dependent carries that dependent's checker reasons, with `name` set to the dependent.
- Salsa nesting limit is 256. Memo versions kept per query: 4.
- `mix precommit` must be green at the end of every task.
- VCS is jj. Each task ends with `jj commit -m "<message>"`, which describes the current change and starts a new one.

## Review Focus

These failure modes are implied by the spec but no oracle fixture exercises them. The test that pins each one is added to the task named.

1. **Deeply nested or huge input** (a 10k-deep `((((…))))`, or a 5 MB source). Expected: a `{:error, %{code: "parse", …}}` or `"type-too-large"` reason, never a crash or hang. *Task 3, Task 6.*
2. **Non-ASCII source** (`"猫"` in strings, tabs, CRLF line endings). Expected: it parses, and its CID equals the CID of the same text with LF endings. *Task 4.*
3. **A patch that defines the same name twice, or an empty patch id.** Expected: staged with a reason, or refused, and committed code unchanged. *Task 10.*
4. **Unstage of an unknown id, and restaging an id with identical source.** Expected: a no-op returning `false`, and the same verdict without growing history. *Task 10.*
5. **Integer literals beyond i64.** Expected: a parse error, as in Rust, never a bignum silently accepted. *Task 3.*

---

## File Structure

```
lib/nobi/lang.ex                     façade: parse/format/cid/new/stage/unstage/read/symbols/history
lib/nobi/lang/ast.ex                 AST shape docs + typespecs + small helpers (name/1, capitalised?/1, ops table)
lib/nobi/lang/lexer.ex               text → tokens                          (syntax/lexer.rs)
lib/nobi/lang/parser.ex              tokens → AST                           (syntax/parser.rs)
lib/nobi/lang/format.ex              AST → canonical text                   (syntax/format.rs)
lib/nobi/lang/cid.ex                 canonical text → CID
lib/nobi/lang/types/stdlib.ex        stdlib + Cmd signatures                (types/stdlib.rs)
lib/nobi/lang/types/extract.ex       decl → signature, decl → deps          (types/extract.rs)
lib/nobi/lang/types/infer.ex         uvars, unify, occurs, instantiate      (types/infer.rs)
lib/nobi/lang/types/check.ex         check_decl/2, check_program/2, check_expr/2 (types/check/mod.rs, decl.rs)
lib/nobi/lang/types/patterns.ex      pattern typing                         (types/check/patterns.rs)
lib/nobi/lang/types/exhaustive.ex    Maranget exhaustiveness                (types/check/exhaustive.rs)
lib/nobi/lang/types/keys.ex          map-key rule, deftype reachability     (types/check/keys.rs)
lib/nobi/lang/types/jsx_app.ex       JSX + app-shape rules                  (types/check/jsx_app.rs)
lib/nobi/lang/types/hints.ex         message hints                          (types/check/hints.rs)
lib/nobi/lang/types/quote.ex         type/expr quoting for messages         (types/quote.rs)
lib/nobi/lang/salsa.ex               layered red-green memo                 (salsa.rs)
lib/nobi/lang/universe.ex            stage/unstage/promote/history/replay   (universe/mod.rs, db.rs)
lib/nobi/lang/universe/search.ex     promotion search                       (universe/search.rs)

test/fixtures/nobi/{counter,notes,split,todo}.nobi
test/fixtures/nobi/{corpus,generated,ill_typed,source}.json
test/support/nobi_oracle.ex            fixture loader
test/nobi/lang/*_test.exs            one per module + oracle_test.exs
```

## AST (the shape every task shares)

Every node is `{kind, meta, args}`. `meta` is a keyword list: `[line: l, col: c]` after parsing, plus `type:` and `res:` after checking.

```elixir
# Types (no meta: they're values, compared structurally)
{:named, "Int"} | {:applied, "List", [t]} | {:arrow, [t], t} | {:tuple, [t, ...]} | {:var, "T"}

# Patterns (no meta)
:wild | {:pvar, n} | {:pint, i} | {:pstr, s} | {:pbool, b} | {:pvariant, "Counter.Msg.Add", [p]} | {:ptuple, [p, ...]}

# Expressions
{:int, m, [i]}            {:str, m, [s]}            {:bool, m, [b]}           {:name, m, [n]}
{:list, m, [e]}           {:map, m, [{k, v}]}       {:tuple, m, [e]}
{:bin, m, [op, l, r]}     # op ∈ ~w(or and == != < > <= >= ++ + - * /)a
{:not, m, [e]}            {:neg, m, [e]}
{:call, m, [n, [arg]]}    {:field, m, [e, field]}
{:construct, m, [model, [{field, e}]]}
{:update, m, [model, base, [{field, e}]]}
{:case, m, [scrutinee, [{pattern, e}]]}
{:if, m, [c, t, e]}
{:fn, m, [[{param, type}], body]}
{:block, m, [[stmt], last]}         # stmt = {:bind, n, e} | {:expr, e}
{:always, m, [e]}         {:sometimes, m, [e]}
{:jsx, m, [tag, [attr], [child]]}   # attr = {:text, n, s} | {:expr, n, e} | {:event, n, e}
                                    # child = {:text, s} | {:expr, e} | {:element, jsx}
{:annot, m, [e, type]}

# Declarations
{:def, m, [name, [{param, type}], ret, block]}
{:defmodel, m, [name, [{field, type}]]}
{:deftype, m, [name, [param], [{variant, [type]}]]}
{:defapp, m, [name]}
{:deftest, m, [name, block]}
```

Signatures, from `types/api.rs`:

```elixir
{:def, params :: [type], ret :: type} | {:model, [{field, type}]}
| {:type, params :: [String.t()], [{variant, [type]}]} | :app | :test
```

Resolutions stored in `meta[:res]`: `:local | {:def, n} | {:variant, owner, variant, arity} | {:ctor_ref, owner, variant, arity}`.

---

### Task 1: Oracle fixtures and loader

**Files:**
- Create: `test/fixtures/nobi/*` (copied)
- Create: `test/support/nobi_oracle.ex`
- Test: `test/nobi/lang/oracle_fixtures_test.exs`

**Interfaces:**
- Produces:
  - `NobiOracle.corpus() :: [%{"file", "verdicts", "codes", "deps"}]`
  - `NobiOracle.corpus_source(file) :: String.t()`
  - `NobiOracle.generated() :: [%{"seed", "source", "verdicts", "codes", "deps"}]`
  - `NobiOracle.ill_typed() :: [%{"seed", "source", "wrong", …}]`
  - `NobiOracle.every_source() :: [{label, source}]`

Every source is already migrated to typed `Html`.

- [ ] **Step 1: Copy and migrate fixtures.** We have no backwards compatibility, so the typed-`Html` migration (`oracle/mod.rs:210`, `with_typed_html`) is applied once at copy time, and the Elixir parser only ever sees `Html<App.Msg>`. The script below also drops the `calls` and `traces` keys, which hold eval goldens that piece 4 will want: keep the originals in `~/proj/kinoko-next` as the source for piece 4.

```bash
mkdir -p test/fixtures/nobi
cp ~/proj/kinoko-next/corpus/*.yabu test/fixtures/nobi/
cp ~/proj/kinoko-next/crates/yabu/tests/oracle/source.json test/fixtures/nobi/
python3 - <<'PY'
import json, re, pathlib
src = pathlib.Path.home()/"proj/kinoko-next/crates/yabu/tests/oracle"
dst = pathlib.Path("test/fixtures/nobi")
def migrate(s):
    apps = [l[len("defapp "):].strip() for l in s.split("\n") if l.startswith("defapp ")]
    out = []
    for l in s.split("\n"):
        m = re.match(r"def ([^(]+)\.[^.(]+\((.*)\) : Html do(.*)$", l)
        if m and m.group(1) in apps:
            head, _, body = l.partition(") : Html do")
            l = f"{head}) : Html<{m.group(1)}.Msg> do{body}"
        out.append(l)
    return "\n".join(out)
for f in dst.glob("*.nobi"): f.write_text(migrate(f.read_text()))
keep = ("seed","source","wrong","verdicts","codes","deps","file")
c = json.load(open(src/"corpus.json")); json.dump([{k:v for k,v in e.items() if k in keep} for e in c], open(dst/"corpus.json","w"), ensure_ascii=False)
for name in ("generated","ill_typed"):
    d = json.load(open(src/f"{name}.json"))
    progs = d["programs"] if name == "generated" else d
    progs = [{**{k:v for k,v in p.items() if k in keep}, "source": migrate(p["source"])} for p in progs]
    json.dump(progs, open(dst/f"{name}.json","w"), ensure_ascii=False)
PY
grep -c "Html<" test/fixtures/nobi/counter.nobi   # expect 1
```

- [ ] **Step 2: Write the loader**

```elixir
# test/support/nobi_oracle.ex
defmodule NobiOracle do
  @moduledoc "The TS/Rust golden files, migrated to typed Html. See test/fixtures/nobi/source.json."
  @dir Path.expand("../fixtures/nobi", __DIR__)

  def corpus, do: read("corpus.json")
  def corpus_source(file), do: File.read!(Path.join(@dir, file))
  def generated, do: read("generated.json")
  def ill_typed, do: read("ill_typed.json")

  def every_source do
    gen = generated() |> Enum.with_index() |> Enum.map(fn {p, i} -> {"generated[#{i}] seed #{p["seed"]}", p["source"]} end)
    ill = ill_typed() |> Enum.with_index() |> Enum.map(fn {p, i} -> {"ill_typed[#{i}] seed #{p["seed"]}", p["source"]} end)
    cor = Enum.map(corpus(), &{&1["file"], corpus_source(&1["file"])})
    gen ++ ill ++ cor
  end

  defp read(file), do: @dir |> Path.join(file) |> File.read!() |> JSON.decode!()
end
```

- [ ] **Step 3: Write the fixture test**

```elixir
# test/nobi/lang/oracle_fixtures_test.exs
defmodule Nobi.Lang.OracleFixturesTest do
  use ExUnit.Case, async: true

  test "the golden files are whole" do
    assert length(NobiOracle.corpus()) == 4
    assert length(NobiOracle.generated()) == 300
    assert length(NobiOracle.ill_typed()) == 307
    refute Enum.any?(NobiOracle.every_source(), fn {_, s} -> s =~ ~r/\) : Html do/ end)
  end
end
```

- [ ] **Step 4: Run.** `mix test test/nobi/lang/oracle_fixtures_test.exs`. Expected: PASS. `test/support` is already in `elixirc_paths(:test)`; check `mix.exs` if the module isn't found.
- [ ] **Step 5: Commit.** `jj commit -m "test: Nobi oracle fixtures (typed Html)"`

---

### Task 2: AST module and lexer

**Files:**
- Create: `lib/nobi/lang/ast.ex`, `lib/nobi/lang/lexer.ex`
- Test: `test/nobi/lang/lexer_test.exs`

**Interfaces:**
- Produces:
  - `Nobi.Lang.Ast.name(decl) :: String.t()`
  - `Ast.capitalised?(String.t()) :: boolean`
  - `Ast.ops() :: [{atom, String.t(), precedence :: 1..7}]`, in the `BinOp::ALL` order
  - `Ast.unary_precedence() :: 8`
  - `Lexer.tokens(String.t()) :: {:ok, [token]} | {:error, %{code: "parse", message: String.t(), line: pos_integer, col: pos_integer}}`
  - A token is `{kind :: atom, value, line, col}`.

- [ ] **Step 1: Read** `syntax/lexer.rs` fully. List its token kinds: identifiers (dotted and capitalised), ints, strings with escapes, operators, `%{`, `%Name{`, `do`/`end`/`fn`/`case`/`if`/`else`, `->`, `=>`, `|`, JSX `<tag`, `</tag>`, JSX text, `{`/`}` inside JSX. Carry over its rule for when `<` begins JSX versus less-than.
- [ ] **Step 2: Write failing tests.** Port every case in `crates/nobi/tests/syntax_parser.rs` that asserts on lexing errors or positions. Add these:

```elixir
defmodule Nobi.Lang.LexerTest do
  use ExUnit.Case, async: true
  alias Nobi.Lang.Lexer

  test "dotted names, ints, strings with unicode" do
    assert {:ok, toks} = Lexer.tokens(~s|Counter.Msg.Add(10) ++ "猫"|)
    assert Enum.map(toks, &elem(&1, 0)) == [:name, :lparen, :int, :rparen, :op, :str, :eof]
  end

  test "an int past i64 is a parse error" do
    assert {:error, %{code: "parse"}} = Lexer.tokens("9223372036854775808")
  end

  test "CRLF lexes like LF" do
    assert {:ok, a} = Lexer.tokens("def A.f() : Int do\r\n  1\r\nend")
    assert {:ok, b} = Lexer.tokens("def A.f() : Int do\n  1\nend")
    assert Enum.map(a, &Tuple.delete_at(&1, 3)) == Enum.map(b, &Tuple.delete_at(&1, 3))
  end
end
```

- [ ] **Step 3: Run it to see it fail.** `mix test test/nobi/lang/lexer_test.exs`. Expected: FAIL, module not defined.
- [ ] **Step 4: Implement.**
  - `Ast` holds the ops table, copied from `ast.rs` `BinOp::precedence` / `symbol`:

    ```elixir
    @ops [or: {"or", 1}, and: {"and", 2}, ==: {"==", 3}, !=: {"!=", 3}, <: {"<", 4}, >: {">", 4},
          <=: {"<=", 4}, >=: {">=", 4}, ++: {"++", 5}, +: {"+", 6}, -: {"-", 6}, *: {"*", 7}, /: {"/", 7}]
    ```

  - The lexer is binary pattern matching over the source, one clause per token start, threading `{line, col}`.
  - Normalise `\r\n` to `\n` up front.
- [ ] **Step 5: Run it to see it pass.** Then commit: `jj commit -m "feat(lang): AST shape and lexer"`

---

### Task 3: Parser

**Files:**
- Create: `lib/nobi/lang/parser.ex`
- Test: `test/nobi/lang/parser_test.exs`

**Interfaces:**
- Consumes: `Lexer.tokens/1` and `Ast`.
- Produces:
  - `Parser.program(String.t()) :: {:ok, [decl]} | {:error, %{code: "parse", message, line, col}}`
  - `Parser.expr(String.t()) :: {:ok, expr} | {:error, …}`
  - `Parser.max_depth() :: 512`

- [ ] **Step 1: Read** `syntax/parser.rs` fully. It is recursive descent with precedence climbing for `bin`, and `not`/`-` bind at precedence 8. Its rules:
  - A capitalised head decides between a dotted declaration name and a local.
  - Tuples are taken apart only in `case` patterns.
  - A `do … end` with one statement is that expression; with more than one it is a `:block`.
- [ ] **Step 2: Write failing tests.** Port `crates/nobi/tests/syntax_parser.rs` case by case. Each Rust `assert_eq!(parse(..), Decl::…)` becomes a match against the tuple shape in the "AST" section above, ignoring `meta`. Use this helper:

```elixir
defp strip({k, _m, args}) when is_atom(k) and is_list(args), do: {k, strip(args)}
defp strip(list) when is_list(list), do: Enum.map(list, &strip/1)
defp strip(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> strip() |> List.to_tuple()
defp strip(x), do: x
```

  Add these golden and robustness tests:

```elixir
test "every golden program parses" do
  for {label, src} <- NobiOracle.every_source() do
    assert {:ok, [_ | _]} = Parser.program(src), label
  end
end

test "the counter app parses to the expected declarations" do
  {:ok, decls} = Parser.program(NobiOracle.corpus_source("counter.nobi"))
  assert Enum.map(decls, &elem(&1, 0)) == [:defmodel, :deftype, :def, :def, :def, :defapp]
  assert {:def, _, ["Counter.view", [{"model", {:named, "Counter.Model"}}], {:applied, "Html", [{:named, "Counter.Msg"}]}, _]} =
           Enum.at(decls, 4)
end

test "nesting past max_depth is a parse error, not a crash" do
  deep = String.duplicate("(", 10_000) <> "1" <> String.duplicate(")", 10_000)
  assert {:error, %{code: "parse"}} = Parser.expr(deep)
end

test "a 5 MB source returns within a second" do
  src = String.duplicate("def A.f() : Int do\n  1\nend\n\n", 200_000)
  {us, result} = :timer.tc(fn -> Parser.program(src) end)
  assert {:ok, _} = result   # duplicates are the universe's concern, not the parser's
  assert us < 1_000_000
end
```

- [ ] **Step 3: Run it to see it fail.**
- [ ] **Step 4: Implement.**
  - Each `parse_*` function takes the token list and returns `{node, rest}`, or throws `{:parse_error, msg, tok}`. That throw is caught once in `program/1` and `expr/1`.
  - Thread a depth counter, and raise the parse error at depth > 512.
  - Ints outside `-2^63..2^63-1` are a parse error.
- [ ] **Step 5: Run it to see it pass.** Then commit: `jj commit -m "feat(lang): parser"`

---

### Task 4: Formatter and CID

**Files:**
- Create: `lib/nobi/lang/format.ex`, `lib/nobi/lang/cid.ex`
- Test: `test/nobi/lang/format_test.exs`

**Interfaces:**
- Consumes: `Parser.program/1`.
- Produces:
  - `Format.program([decl]) :: String.t()`, with declarations joined by a blank line
  - `Format.decl(decl)`, `Format.expr(expr)`, `Format.type(type)`, `Format.pattern(p) :: String.t()`
  - `Cid.of(decl) :: String.t()`, 64 lowercase hex characters
  - `Cid.version() :: "yabu/1"`

- [ ] **Step 1: Read** `syntax/format.rs`, especially its rules for parenthesisation, `Field` after a capitalised name, and line breaking for JSX and `case`.
- [ ] **Step 2: Write failing tests.** Port `tests/syntax_format.rs`, then add:

```elixir
test "the formatter writes what TS wrote" do
  for {label, src} <- NobiOracle.every_source(), not String.ends_with?(label, ".nobi") do
    {:ok, decls} = Parser.program(src)
    assert Format.program(decls) == String.trim_trailing(src), label
  end
end

test "formatting never changes the tree, and is idempotent" do
  for {label, src} <- NobiOracle.every_source() do
    {:ok, a} = Parser.program(src)
    {:ok, b} = a |> Format.program() |> Parser.program()
    assert strip(a) == strip(b), label
    assert Format.program(b) == Format.program(a), label
  end
end

test "CID ignores layout and line endings, sees content" do
  {:ok, [a]} = Parser.program("def A.f() : Int do\n  1\nend")
  {:ok, [b]} = Parser.program("def A.f()   :   Int do\r\n\r\n      1\r\nend")
  {:ok, [c]} = Parser.program("def A.f() : Int do\n  2\nend")
  assert Cid.of(a) == Cid.of(b)
  refute Cid.of(a) == Cid.of(c)
  assert Cid.of(a) =~ ~r/^[0-9a-f]{64}$/
end

test "CID of non-ASCII content is stable" do
  {:ok, [d]} = Parser.program(~s|def A.s() : String do\n  "猫\\t"\nend|)
  assert Cid.of(d) == Cid.of(d |> Format.decl() |> Parser.program() |> elem(1) |> hd())
end
```

  Reuse the `strip/1` helper from Task 3. Move it to `test/support/nobi_oracle.ex` as `NobiOracle.strip/1`.

  If the "writes what TS wrote" test fails only on whitespace that TS chose and the Rust formatter also deviates from, read `golden.rs` `the_formatter_writes_what_ts_wrote` and copy its exceptions exactly. Add nothing beyond them.
- [ ] **Step 3: Run it to see it fail.**
- [ ] **Step 4: Implement.**
  - The formatter builds iodata and calls `IO.iodata_to_binary` once.
  - `Cid.of(decl)` is `:crypto.hash(:sha256, ["yabu/1\n", Format.decl(decl)]) |> Base.encode16(case: :lower)`.
- [ ] **Step 5: Run it to see it pass.** Then commit: `jj commit -m "feat(lang): canonical formatter and CID"`

---

### Task 5: Stdlib signatures and extraction

**Files:**
- Create: `lib/nobi/lang/types/stdlib.ex`, `lib/nobi/lang/types/extract.ex`
- Test: `test/nobi/lang/extract_test.exs`

**Interfaces:**
- Produces:
  - `Stdlib.signatures() :: %{String.t() => signature}`, built once with a module attribute
  - `Stdlib.names() :: [String.t()]`
  - `Extract.signature(decl) :: signature`
  - `Extract.deps(decl) :: MapSet.t(String.t())`

- [ ] **Step 1: Read** `types/stdlib.rs` (59 entries, plus the `Cmd.*` effects) and `types/extract.rs`.
- [ ] **Step 2: Write failing tests.** Port `tests/types_extract.rs`, and add:

```elixir
test "deps match the oracle for every corpus declaration" do
  for %{"file" => f, "deps" => want} <- NobiOracle.corpus() do
    {:ok, decls} = Parser.program(NobiOracle.corpus_source(f))
    for d <- decls do
      assert d |> Extract.deps() |> MapSet.subset?(MapSet.new(want[Ast.name(d)])), "#{f} #{Ast.name(d)}"
    end
  end
end

test "stdlib has every name the oracle stdlib.json examples use" do
  for n <- ~w(List.map List.filter List.append List.concat String.from_int Cmd.none JSON.parse) do
    assert Map.has_key?(Stdlib.signatures(), n)
  end
end
```

  `deps` here is the syntactic `extract_deps`. The oracle's deps are the checker's (a superset), so this asserts subset only. Task 8 asserts equality.
- [ ] **Step 3: Run it to see it fail. Step 4: Implement** as a direct port. **Step 5: Run it to see it pass.** Commit: `jj commit -m "feat(lang): stdlib signatures and extraction"`

---

### Task 6: Inference core

**Files:**
- Create: `lib/nobi/lang/types/infer.ex`, `lib/nobi/lang/types/quote.ex`
- Test: `test/nobi/lang/infer_test.exs`

**Interfaces:**
- Produces a pure substitution state, `%Infer{next: n, subst: %{uvar => type}}`, where unification variables are `{:uvar, n}`:
  - `Infer.new()`
  - `Infer.fresh(st) :: {{:uvar, n}, st}`
  - `Infer.unify(st, a, b) :: {:ok, st} | {:error, code :: "mismatch" | "occurs", st}`
  - `Infer.resolve(st, type) :: type`
  - `Infer.instantiate(st, scheme_type) :: {type, st}`, which replaces `{:var, _}` with fresh uvars
  - `Quote.type(type) :: String.t()`, cut at the Rust `QUOTE_LIMIT`
  - `Quote.expr(expr) :: String.t()`

- [ ] **Step 1: Read** `types/infer.rs` and `types/quote.rs`.
- [ ] **Step 2: Write failing tests:** unify identical types; unify a uvar with `List<Int>` and resolve it; the occurs check (`u ~ List<u>` gives `"occurs"`); a mismatch between `Int` and `String`; instantiating `List.map`'s scheme twice yields distinct uvars; quoting a type over the limit is cut.
- [ ] **Step 3: Run it to see it fail. Step 4: Implement.**
  - `resolve` follows `subst` to a fixpoint.
  - Track type size, and return `"type-too-large"` past the Rust limit. This is Review Focus 1.

  Add this test to Step 2 before implementing:

```elixir
test "a doubling type stops at type-too-large, not OOM" do
  {t, st} = Enum.reduce(1..64, {{:named, "Int"}, Infer.new()}, fn _, {t, st} -> {{:tuple, [t, t]}, st} end)
  assert {:error, "type-too-large", _} = Infer.check_size(st, t)
end
```

  Expose `Infer.check_size/2`, which mirrors the size limit in `infer.rs`.
- [ ] **Step 5: Run it to see it pass.** Commit: `jj commit -m "feat(lang): inference core"`

---

### Task 7: Checker — expressions, declarations, patterns

**Files:**
- Create: `lib/nobi/lang/types/check.ex`, `lib/nobi/lang/types/patterns.ex`, `lib/nobi/lang/types/exhaustive.ex`
- Test: `test/nobi/lang/check_test.exs`

**Interfaces:**
- Consumes: `Infer`, `Extract`, `Stdlib`, `Quote`.
- Produces:
  - `Check.decl(decl, sigs :: %{name => signature}) :: %{deps: MapSet.t(), result: {:ok, typed_decl} | {:error, [%{code, message}]}}`
  - `Check.expr(expr, sigs)`, with the same result shape
  - `Check.program([decl], base_sigs) :: %{name => same}`, which checks each declaration against the program's own signatures merged over `base_sigs`

  `deps` is every name whose signature the check *consulted*. On success it is a superset of `Extract.deps`.

- [ ] **Step 1: Read** `types/check/mod.rs`, `decl.rs`, `patterns.rs` and `exhaustive.rs`. The checker is bidirectional, with `check` and `synth` modes.
- [ ] **Step 2: Write failing tests.** Port `tests/types_check.rs`, `types_tuples.rs` and `types_annotations.rs`, except their JSX, app and map-key cases, which are Task 8's. Every Rust assertion of the form `codes == ["mismatch"]` becomes `assert codes(result) == ["mismatch"]`, using:

```elixir
defp codes(%{result: {:ok, _}}), do: []
defp codes(%{result: {:error, errs}}), do: Enum.map(errs, & &1.code)
```

- [ ] **Step 3: Run it to see it fail.**
- [ ] **Step 4: Implement.**
  - Thread `{infer_state, consulted :: MapSet}` through every function.
  - Record each name the checker looks up in `sigs` into `consulted`. This set is `deps`, and salsa needs it to be exact.
  - Store `type:` and `res:` in each node's meta in the returned typed tree.
- [ ] **Step 5: Run it to see it pass.** Commit: `jj commit -m "feat(lang): checker for expressions, decls, patterns"`

---

### Task 8: Checker — JSX, app shape, map keys, hints; full oracle green

**Files:**
- Create: `lib/nobi/lang/types/jsx_app.ex`, `lib/nobi/lang/types/keys.ex`, `lib/nobi/lang/types/hints.ex`
- Modify: `lib/nobi/lang/types/check.ex`
- Test: `test/nobi/lang/check_test.exs` (extend), `test/nobi/lang/oracle_test.exs`

**Interfaces:**
- Produces: `Keys.reaching(name, sigs) :: MapSet.t()`, the group of deftypes a map-key check consults. Universe/salsa uses it as its own query in Task 10.

- [ ] **Step 1: Read** `types/check/jsx_app.rs`, `keys.rs` and `hints.rs`, and `golden.rs:129-305`.
- [ ] **Step 2: Write the oracle test**

```elixir
defmodule Nobi.Lang.OracleTest do
  use ExUnit.Case, async: true
  alias Nobi.Lang.{Parser, Ast, Types.Check, Types.Stdlib}

  defp run(src) do
    {:ok, decls} = Parser.program(src)
    Check.program(decls, Stdlib.signatures())
  end

  defp assert_matches(label, checked, %{"verdicts" => v, "codes" => c, "deps" => d}) do
    for {name, ok?} <- v do
      got = checked[name]
      assert match?({:ok, _}, got.result) == ok?, "#{label} #{name} verdict"
      assert Enum.sort(codes(got)) == Enum.sort(c[name]), "#{label} #{name} codes"
      if ok?, do: assert(MapSet.new(d[name]) == got.deps, "#{label} #{name} deps")
    end
  end

  defp codes(%{result: {:ok, _}}), do: []
  defp codes(%{result: {:error, e}}), do: Enum.map(e, & &1.code)

  test "corpus" do
    for e <- NobiOracle.corpus(), do: assert_matches(e["file"], run(NobiOracle.corpus_source(e["file"])), e)
  end

  test "generated" do
    for p <- NobiOracle.generated(), do: assert_matches("seed #{p["seed"]}", run(p["source"]), p)
  end

  test "ill_typed fails exactly at its wrong declaration" do
    for p <- NobiOracle.ill_typed() do
      checked = run(p["source"])
      failing = for {n, %{result: {:error, _}}} <- checked, do: n
      assert failing == [p["wrong"]], "seed #{p["seed"]}"
      assert_matches("seed #{p["seed"]}", checked, p)
    end
  end

  test "an unbound constructor message shows the %M{} syntax" do
    {:ok, [_, d]} = Parser.program("defmodel A.M do\n  n : Int\nend\n\ndef A.f() : A.M do\n  A.M(1)\nend")
    %{result: {:error, [e | _]}} = Check.decl(d, Map.merge(Stdlib.signatures(), %{"A.M" => {:model, [{"n", {:named, "Int"}}]}}))
    assert e.message =~ "%A.M{"
  end
end
```

  For the deps comparison, read `golden.rs` `assert_codes_and_deps_match`: if Rust unions with `extract_deps` on failure, do the same.

- [ ] **Step 3: Port** the JSX, app, map-key and hint cases from `types_check.rs` and `types_html.rs` into `check_test.exs`.
- [ ] **Step 4: Run them to see them fail. Step 5: Implement** the three modules and wire them into `Check`.
- [ ] **Step 6: Run** `mix test test/nobi/lang`. Expected: everything passes. A divergence from the oracle is a bug in the port; never edit a fixture.
- [ ] **Step 7: Commit.** `jj commit -m "feat(lang): JSX/app/map-key rules; oracle green"`

---

### Task 9: Salsa

**Files:**
- Create: `lib/nobi/lang/salsa.ex`
- Test: `test/nobi/lang/salsa_test.exs`

**Interfaces:**
- Produces a pure struct. The compute callback is a module implementing `@callback compute(query, Salsa.Reads.t()) :: {{:ok, out} | {:error, term}, Salsa.Reads.t()}`.

```elixir
Salsa.new(compute_module, opts \\ [])          # opts: versions: 4, depth: 256
Salsa.set(db, layer, key, value | :tombstone)  :: db     # moves revision only if value differs
Salsa.unset(db, layer, key)                    :: db
Salsa.query(db, ctx :: [layer], q)             :: {{:ok, out} | {:error, {:cycle, q} | :too_deep}, db}
Salsa.input(reads, key)                        :: {value | nil, reads}   # inside compute
Salsa.ask(reads, q)                            :: {{:ok, out} | {:error, _}, reads}
Salsa.retain(db, keep_query? :: (q -> bool))   :: db
Salsa.retain_reads(db, keep_value? :: (v -> bool)) :: db
Salsa.trim(db)                                 :: db
Salsa.revision(db) / Salsa.stats(db)           # stats: %{queries, memos, reads, computes: %{q => n}}
```

  `stats.computes` counts real recomputes per query. It replaces the Rust test's `logging` closure, and is what the incrementality tests assert on.

- [ ] **Step 1: Read** `salsa.rs` fully, including its module doc, which states the semantics.
- [ ] **Step 2: Write failing tests.** Port every test in `crates/nobi/tests/salsa.rs`: from `second_identical_query_does_not_re_run` through `rust_only_trim_follows_what_read_what_it_drops`, plus the randomized model test at the bottom, using `:rand.seed(:exsss, {1, 2, 3})` and 500 iterations in place of proptest. Their test `Queries` impl becomes a test module:

```elixir
defmodule Nobi.Lang.SalsaTest.Q do
  @behaviour Nobi.Lang.Salsa
  alias Nobi.Lang.Salsa
  # {:sig, name} reads input name → its first line; {:check, name} reads :sig of each dep listed after "|"
  def compute({:sig, n}, r) do
    {src, r} = Salsa.input(r, n)
    {{:ok, src && hd(String.split(src, "|"))}, r}
  end
  def compute({:check, n}, r) do
    {src, r} = Salsa.input(r, n)
    deps = src |> String.split("|") |> tl() |> Enum.flat_map(&String.split(&1, ",", trim: true))
    Enum.reduce(deps, {{:ok, :ok}, r}, fn d, {acc, r} ->
      {sig, r} = Salsa.ask(r, {:sig, d})
      {if(sig == {:ok, nil}, do: {:error, {:unbound, d}}, else: acc), r}
    end)
  end
  def compute({:self, _} = q, r), do: Salsa.ask(r, q)
end
```

  The key test, which states the property the whole design rests on:

```elixir
test "body edit with unchanged signature never recomputes dependents" do
  db = Salsa.new(Q) |> Salsa.set(:committed, "a", "Int|") |> Salsa.set(:committed, "b", "Int|a")
  {{:ok, :ok}, db} = Salsa.query(db, [:committed], {:check, "b"})
  db = Salsa.set(db, :committed, "a", "Int|x")   # body changed, sig ("Int") same
  {{:ok, :ok}, db} = Salsa.query(db, [:committed], {:check, "b"})
  assert Salsa.stats(db).computes[{:check, "b"}] == 1
  assert Salsa.stats(db).computes[{:sig, "a"}] == 2
end
```

- [ ] **Step 3: Run them to see them fail.**
- [ ] **Step 4: Implement.**
  - Struct: `%Salsa{mod, revision, layers: %{layer => %{key => value | :tombstone}}, memos: %{q => [memo]}, verified: %{ctx => %{q => memo_ref}}, computes: %{}}`.
  - A memo is `%{reads: [{:input, key, value} | {:query, q, out}], out, verified_at}`.
  - Red-green: walk `reads` in order, re-reading each in the asked context, and stop at the first difference.
  - Cycle detection: keep the active-query stack in `Reads`.
- [ ] **Step 5: Run them to see them pass.** Commit: `jj commit -m "feat(lang): salsa memo"`

---

### Task 10: Universe and promotion search

**Files:**
- Create: `lib/nobi/lang/universe.ex`, `lib/nobi/lang/universe/search.ex`, `lib/nobi/lang/universe/db.ex` (the salsa `compute` module)
- Test: `test/nobi/lang/universe_test.exs`

**Interfaces:**
- Consumes: `Salsa`, `Check`, `Extract`, `Keys`, `Cid`, `Format`.
- Produces:

```elixir
@type entry :: {:live, decl} | {:gone, name}
@type round :: %{ids: [id], entries: [{:live, name, cid} | {:gone, name}]}   # entries sorted by name
@type verdict :: {:promoted, [id]} | {:staged, [reason]}

Universe.new() :: t
Universe.stage(u, id :: String.t(), [entry]) :: {t, verdict}      # id "" → {u, {:staged, [%{code: "bad-id", …}]}}, nothing staged
Universe.unstage(u, id) :: {t, boolean}
Universe.reasons(u, id) :: [reason]
Universe.staged(u) :: %{id => [entry]}
Universe.committed(u) :: %{name => %{cid, decl, typed, deps}}
Universe.history(u) :: [round]                       # oldest first
Universe.text(u, cid) :: String.t() | nil            # canonical source (cas)
Universe.replay([round]) :: %{name => cid}
Universe.restore([round], %{cid => text}) :: {:ok, t} | {:error, [reason]}
```

  Internally `history` is stored newest-first (prepend only), and `history/1` reverses it.

- [ ] **Step 1: Read** `universe/mod.rs`, `db.rs`, `search.rs`, and `specs/universe/universe.qnt`, which holds the invariants.
- [ ] **Step 2: Write failing tests.** Port `src/universe/tests.rs`, all of it: every scenario from `a_well_typed_patch_promotes_whole` to `promoting_a_new_signature_cannot_leave_a_committed_dependent_broken`, and the property tests, using seeded `:rand` and 200 iterations each. Rust assertions on reason strings become assertions on `reason.code` and `reason.name`. The `logging` / `checked_during` helpers become reads of `Salsa.stats(u.salsa).computes` before and after. Add the Review Focus tests:

```elixir
test "the same name twice in one patch is a reason, committed unchanged" do
  u = Universe.new()
  {u2, {:staged, [%{code: "duplicate"} | _]}} = Universe.stage(u, "p", patch("def A.f() : Int do\n  1\nend\n\ndef A.f() : Int do\n  2\nend"))
  assert Universe.committed(u2) == Universe.committed(u)
end

test "empty id is refused and stages nothing" do
  {u, {:staged, [%{code: "bad-id"}]}} = Universe.stage(Universe.new(), "", patch("def A.f() : Int do\n  1\nend"))
  assert Universe.staged(u) == %{}
end

test "unstaging an unknown id is a no-op" do
  u = Universe.new()
  assert {^u, false} = Universe.unstage(u, "nope")
end

test "restaging an id with identical source grows no history" do
  {u, {:promoted, ["p"]}} = Universe.stage(Universe.new(), "p", patch("def A.f() : Int do\n  1\nend"))
  {u2, _} = Universe.stage(u, "p", patch("def A.f() : Int do\n  1\nend"))
  assert length(Universe.history(u2)) == length(Universe.history(u))
end

test "search equals the naive every-subset search" do
  :rand.seed(:exsss, {7, 7, 7})
  for _ <- 1..200 do
    {base, patches} = random_case()            # port `case()` strategy from tests.rs
    assert promoted_by(Universe, base, patches) == promoted_by(NaiveUniverse, base, patches)
  end
end
```

  Here `patch/1` is `fn src -> {:ok, ds} = Parser.program(src); Enum.map(ds, &{:live, &1}) end`. `NaiveUniverse` is a test-only module that tries every subset, as `tests.rs` does.

  Port the body-edit property exactly (`rust_only_a_body_edit_checks_only_that_declaration_never_its_dependents`):

```elixir
test "a body edit checks only that declaration, never its dependents" do
  {u, {:promoted, _}} = Universe.stage(Universe.new(), "base", patch(chain(20)))   # A.f0 … A.f19, each calls the previous
  before = Universe.check_count(u)
  {u, {:promoted, _}} = Universe.stage(u, "edit", patch("def A.f0() : Int do\n  41 + 1\nend"))
  assert Universe.check_count(u) - before == 1
end
```

  Expose `Universe.check_count(u) :: non_neg_integer`, the sum of `{:check, _}` computes from salsa stats.

- [ ] **Step 3: Run them to see them fail.**
- [ ] **Step 4: Implement.**
  - **Salsa queries** (in `Universe.Db.compute/2`):
    - `{:signature, cid}` reads input `{:decl, cid}`.
    - `{:sig, name}` reads input `{:name, name}`, which gives a cid or a tombstone, then asks `{:signature, cid}`.
    - `{:reaching, name}` covers deftype map-key groups.
    - `{:check, cid}` asks `{:sig, n}` for each name `Check.decl` consults.
  - To make `Check.decl` consult signatures through salsa, pass it a `sigs` *lookup function* rather than a map. Change Task 7's `Check.decl/2` to accept either a map or a `(name -> signature | nil)` function. The function variant is the one used here.
  - **Layers:** `:committed`, plus `{:patch, id}` per staged patch. A trial context is `[{:patch, id} …, :committed]`.
  - **Search:** a port of `search.rs` (root, links, components, pruning, copies-as-one).
  - **History:** each promotion prepends a round, then updates the `:committed` layer inputs.
- [ ] **Step 5: Run them to see them pass.** Commit: `jj commit -m "feat(lang): universe and promotion search"`

---

### Task 11: Quint trace conformance

**Files:**
- Test: `test/nobi/lang/universe_conformance_test.exs`
- Modify: `test/test_helper.exs`, to exclude `:quint` unless `quint` is on PATH

**Interfaces:**
- Consumes: the `Universe` public API and `quint` (`/opt/homebrew/bin/quint`).

- [ ] **Step 1: Read** `tests/universe_conformance.rs`. It runs `quint run --out-itf` on `specs/universe/abstract.qnt` and `universe.qnt`, maps each step to Nobi source, replays it, and compares.
- [ ] **Step 2: Port it** with `@moduletag :quint`. Shell out with `System.cmd("quint", [...])`, read the ITF JSON with `JSON.decode!`, and point at the specs in `~/proj/kinoko-next/specs/universe/` through an env var `KINOKO_NEXT_SPECS`, defaulting to `Path.expand("~/proj/kinoko-next/specs")`.
- [ ] **Step 3:** In `test_helper.exs`:

```elixir
ExUnit.configure(exclude: if(System.find_executable("quint"), do: [], else: [:quint]))
```

- [ ] **Step 4: Run** `mix test --only quint`. Expected: PASS. Commit: `jj commit -m "test(lang): universe conforms to Quint traces"`

---

### Task 12: `Nobi.Lang` façade

**Files:**
- Create: `lib/nobi/lang.ex`
- Test: `test/nobi/lang_test.exs`

**Interfaces:**
- Produces the only API the later pieces call:

```elixir
Nobi.Lang.parse(source) :: {:ok, [decl]} | {:error, reason}
Nobi.Lang.format(source_or_decls) :: {:ok, String.t()} | {:error, reason}
Nobi.Lang.cid(decl) :: String.t()
Nobi.Lang.new() :: Universe.t()
Nobi.Lang.stage(u, id, source, opts \\ [remove: [name]]) :: {Universe.t(), verdict}   # parse error → {u, {:staged, [reason]}} without touching u
Nobi.Lang.unstage(u, id) :: {Universe.t(), boolean}
Nobi.Lang.read(u, name) :: {:ok, String.t()} | :error        # committed, else staged
Nobi.Lang.symbols(u) :: [%{name, cid, signature :: String.t()}]
Nobi.Lang.history(u) :: [round]
```

- [ ] **Step 1: Write failing tests:**
  - The counter corpus file stages under `"counter"` and promotes.
  - `read(u, "Counter.update")` equals its canonical text.
  - `symbols/1` lists 6 names with signatures rendered by `Format.type`.
  - A parse error comes back as `{:staged, [%{code: "parse"}]}` and the universe is unchanged.
  - `stage(u, "rm", "", remove: ["Counter"])` promotes the removal of the app.
- [ ] **Step 2: Run them to see them fail. Step 3: Implement** a thin delegation with no logic beyond parse-then-stage. **Step 4: Run them to see them pass.**
- [ ] **Step 5: Run** `mix precommit`. Expected: compiles with no warnings, formatted, all tests green.
- [ ] **Step 6: Commit.** `jj commit -m "feat(lang): Nobi.Lang façade"`
