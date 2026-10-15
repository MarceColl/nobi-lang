defmodule KinokoWeb.Mcp.Instructions do
  @moduledoc """
  The MCP server's `instructions`: what an agent must know before its
  first patch. Adapted from the TS server's (the code-database framing,
  the syntax you cannot guess, the stage loop, what costs rework), keeping
  only what this server has. The stdlib list is generated from the
  stdlib's own table (`Kinoko.Lang.Rt.Stdlib` / `Kinoko.Lang.Types.Stdlib`),
  so it cannot drift; the DECLARATIONS example is `example/0`, which a test
  stages into a fresh universe (it must promote), so it cannot drift either.
  """

  alias Kinoko.Lang.Format
  alias Kinoko.Lang.Rt.Stdlib, as: Rt
  alias Kinoko.Lang.Types.{Extract, Stdlib}

  # Every declaration form in one small app (a cut-down
  # test/fixtures/yabu/counter.yabu). The MCP tests stage it: it must promote.
  @example """
  defmodel Counter.Model do
    count : Int
    label : String
  end

  deftype Counter.Msg do
    Increment | Add(Int) | Rename(String)
  end

  def Counter.init() : (Counter.Model, Cmd<Counter.Msg>) do
    (%Counter.Model{count: 0, label: "clicks"}, Cmd.none())
  end

  def Counter.update(msg : Counter.Msg, model : Counter.Model) : (Counter.Model, Cmd<Counter.Msg>) do
    next = case msg do
      Counter.Msg.Increment -> %Counter.Model{model | count: model.count + 1}
      Counter.Msg.Add(n) -> if model.count + n >= 0 do %Counter.Model{model | count: model.count + n} else model end
      Counter.Msg.Rename(s) -> %Counter.Model{model | label: s}
    end
    (next, Cmd.none())
  end

  def Counter.view(model : Counter.Model) : Html<Counter.Msg> do
    <div class="flex gap-2 p-4">
      <span class="font-bold">{model.label}: {String.from_int(model.count)}</span>
      <button class="rounded bg-blue-600 px-3 text-white" on-click={Counter.Msg.Increment}>+</button>
      <button on-click={Counter.Msg.Add(10)}>+10</button>
    </div>
  end

  defapp Counter

  defroutes Main do
    "/" -> Counter
  end
  """

  @head """
  Kinoko is a code database, not a filesystem with a compiler. Every declaration
  is stored by content; you change the code by staging a patch that either
  PROMOTES (the whole committed image still typechecks) or stays staged carrying
  the exact reasons it cannot. You get a precise verdict on every attempt, so
  small patches read for their reasons are the fast path, not writing a lot and
  hoping.

  The code lives in UNIVERSES: independent, named code databases. Every tool
  takes an optional `universe` (default "main", which is shared). To experiment
  without touching main, `create_universe` and pass its name everywhere;
  `list_universes` shows what exists.

  The language is Yabu: defmodel / deftype / def / deftest / defapp. An app is one
  Elm-style loop: init() -> (Model, Cmd<Msg>), update(msg, model) -> (Model,
  Cmd<Msg>), view(model) -> Html<Msg>, with JSX styled by Tailwind classes.

  THE SYNTAX YOU CANNOT GUESS (it is Elixir-flavoured, not ML- or JS-flavoured)
    %App.Model{count: 1, name: "x"}   construct; there is NO Model(...), .new or .create
    %App.Model{row | count: 2}        update a copy; there is no assignment
    %{"k" => v}                       map literal        [1, 2]  list literal
    case msg do App.Msg.Add(n) -> ... end                match (`do`, never `of`)
    if c do a else b end                                 if is an expression
    fn (x : Int) -> x + 1 end                            lambda
    Option.Some(x) / Option.None                         variants are qualified too
    deftest App.adds do always(App.add(1, 2) == 3) end   a test asserts with always
  Every name is fully qualified everywhere: `App.helper(x)`, never `helper(x)`.

  DECLARATIONS: one whole app, every form you need (it promotes as written)
  #{@example |> String.trim_trailing() |> String.split("\n") |> Enum.map_join("\n", &String.trim_trailing("  " <> &1))}

  - defmodel: one `field : Type` per line. deftype: variants separated by `|`,
    a payload in parentheses, `Counter.Msg.Add(Int)`.
  - def: every parameter and the return type annotated; the body's last
    expression is the value. `next = expr` binds a local (no reassignment).
  - case arms are `Pattern -> expr`, one per line, and must cover every
    variant; `if c do a else b end` is an expression.
  - JSX: attributes are strings or `{expr}`; `on-click={Msg}` sends that
    message to update; `{expr}` in a body renders its value.
  - defapp Counter wires Counter.init / Counter.update / Counter.view.
  - defroutes Main maps URL paths to apps; a deployment serves one route table
    (`Main` is what the local deployment serves). `:name` captures a segment
    and is passed to the app's `init` as a parameter, typed Int, String or
    Uuid: `"/post/:id" -> Forum.Post` needs
    `def Forum.Post.init(id : Uuid) : (Forum.Post.Model, Cmd<Forum.Post.Msg>)`
    (the names match the pattern's params, in order). A URL that does not
    parse as its type is a 404.
  - Cmd.navigate(App, args...) goes to the route that opens App with those
    args: `Cmd.navigate(Forum.Post, topic.id)` from update, `Cmd.navigate(Forum.Settings)`
    when it takes none. The target must be an app some route reaches.

  THE LOOP
  1. Look first: `symbols` (every committed signature), then `read` the
     declarations you will touch. `history` shows what promoted, and when.
  2. `stage_patch` with a patch id and source (and `remove` to delete symbols).
  3. Read the verdict. `promoted: ids` means it is committed. `staged: id` is NOT
     success: the patch is inert, and each `- symbol [code] message` line says
     why. Fix the reasons and restage THE SAME id (`list_staged` shows every
     staged patch, its reasons and source; `unstage` drops one).
  4. Prove it: `eval` an expression against the committed code (it answers
     `value : type`), and `test` a deftest.

  WHAT COSTS THE MOST REWORK
  - A patch replaces the declarations it names WHOLE. `read` before modifying,
    or you will silently drop fields, variants or branches you did not restate.
  - Symbols that change together must be in ONE patch: a patch that breaks a
    committed dependent cannot promote.
  - A Model field holds data: Int, String, Bool, Uuid, Unit, List<T>,
    Map<K, V>, Option<T>, tuples, another defmodel, or your own deftype (its
    payloads data too). Never a function, Cmd or Html.
  - Construction has NO defaults: `%App.Model{...}` must list EVERY field
    (a missing one is `missing-field`). `%App.Model{row | f: v}` copies the
    rest, so add a field and you must add it to every construction.
  - always(...) is checked when it runs: an `eval` that reaches it, or a `test`.
    Nothing explores states for you, so drive update through the cases that
    matter (init's model included) with eval, or write a deftest.
  - `eval` and `test` see only committed code: a staged patch is invisible
    until it promotes.
  - A universe can be DEGRADED: its committed code stopped typechecking (the
    checker changed under it). `symbols` and `list_universes` say so and
    `health` lists why; eval and test answer `[degraded]` until a patch that
    fixes every listed reason promotes (it must make the whole image check).
  - Cmd values (effects) are data here: `eval` shows the Cmd a function returns,
    but nothing runs it yet (no store, no hosting).
  """

  @doc "The worked example the DECLARATIONS section shows: Yabu source that promotes."
  @spec example() :: String.t()
  def example, do: @example

  @doc "The instructions text, with the stdlib generated from its table."
  @spec text() :: String.t()
  def text do
    @head <> "\n" <> stdlib()
  end

  defp stdlib do
    defs =
      for name <- Stdlib.names(),
          {:def, _, _, _} = sig <- [Stdlib.signature(name)],
          Rt.function_for(name) != nil,
          do: "  " <> Format.signature(name, sig)

    types =
      for name <- Stdlib.names(),
          {:type, _, variants} = sig <- [Stdlib.signature(name)],
          do: if(variants == [], do: name <> " (opaque)", else: type_line(name, sig))

    """
    THE WHOLE STDLIB (generated; nothing else exists)
    Built-in types: #{Enum.join(Extract.builtin_named(), ", ")}, List<a>, Map<k, v>, tuples,
    Cmd<msg>, Html<msg>. Stdlib types: #{Enum.join(types, "; ")}.
    #{Enum.join(defs, "\n")}
    Map.keys/values/to_list come out in key order; there is no `m[k]`, use Map.get.
    That is all of it. If what you need is not listed, write it as your own def
    (fully qualified, in your patch) and say so rather than inventing a function.
    """
  end

  defp type_line(name, sig), do: Format.signature(name, sig) |> String.replace_prefix("type ", "")
end
