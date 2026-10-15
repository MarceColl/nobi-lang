defmodule KinokoWeb.Mcp.Instructions do
  @moduledoc """
  The MCP server's `instructions`: what an agent must know before its
  first patch. Adapted from the TS server's (the code-database framing,
  the syntax you cannot guess, the stage loop, what costs rework), keeping
  only what this server has. The stdlib list is generated from the
  stdlib's own table (`Kinoko.Lang.Rt.Stdlib` / `Kinoko.Lang.Types.Stdlib`),
  so it cannot drift.
  """

  alias Kinoko.Lang.Format
  alias Kinoko.Lang.Rt.Stdlib, as: Rt
  alias Kinoko.Lang.Types.{Extract, Stdlib}

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
  - Every Model field must be defaultable (Int, String, Bool, Uuid, List, Map,
    Option, tuple, nested model). A custom deftype can never be a Model field:
    use String / Option<...> / Bool for state like the current screen.
  - always(...) is checked when it runs: an `eval` that reaches it, or a `test`.
    Nothing explores states for you, so drive update through the cases that
    matter (init's model included) with eval, or write a deftest.
  - `eval` and `test` see only committed code: a staged patch is invisible
    until it promotes.
  - Cmd values (effects) are data here: `eval` shows the Cmd a function returns,
    but nothing runs it yet (no store, no hosting).
  """

  @doc "The instructions text, with the stdlib generated from its table."
  @spec text() :: String.t()
  def text do
    @head <> "\n" <> stdlib()
  end

  defp stdlib do
    defs =
      for name <- Stdlib.names(),
          {:def, _, _} = sig <- [Stdlib.signature(name)],
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
    That is all of it. If what you need is not listed, write it as your own def
    (fully qualified, in your patch) and say so rather than inventing a function.
    """
  end

  defp type_line(name, sig), do: Format.signature(name, sig) |> String.replace_prefix("type ", "")
end
