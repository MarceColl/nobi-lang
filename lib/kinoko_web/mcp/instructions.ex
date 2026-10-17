defmodule KinokoWeb.Mcp.Instructions do
  @moduledoc """
  The MCP server's `instructions`: what an agent must know before its
  first patch. Adapted from the TS server's (the code-database framing,
  the syntax you cannot guess, the stage loop, what costs rework), keeping
  only what this server has. The stdlib list is generated from the
  stdlib's own table (`Kinoko.Lang.Rt.Stdlib` / `Kinoko.Lang.Types.Stdlib`),
  so it cannot drift; the code examples are `examples/0` (the DECLARATIONS
  app, then the form and the route table built on it), which a test stages
  in order into a fresh universe (each must promote), so they cannot drift
  either. The "there is no ..." facts are each asserted against the parser
  and checker by the MCP tests.

  Claude Code shows only the first ~4096 characters of a server's
  instructions, so the text opens with `head/0` (kept under 4000 by a
  test): the facts that cost the most in a real agent run, and a pointer to
  the `guide` tool, which answers the whole text.
  """

  alias Kinoko.Lang.Format
  alias Kinoko.Lang.Rt.Stdlib, as: Rt
  alias Kinoko.Lang.Types.{Extract, Stdlib}

  # Every declaration form in one small app (a cut-down
  # test/fixtures/yabu/counter.yabu, plus a stored model, Cmd.store and a
  # tx closure). The MCP tests stage it: it must promote.
  @example """
  defmodel Counter.Snapshot do
    id : Uuid
    count : Int
    label : String
    saves : Int = 1
  end

  defmodel Counter.Model do
    count : Int
    label : String
    snapshots : List<Counter.Snapshot>
  end

  deftype Counter.Msg do
    Increment | Add(Int) | Rename(String) | Save | Saved(Uuid) | Loaded(List<Counter.Snapshot>) | Again(Uuid) | Done(Result<(List<Uuid>, Int), String>)
  end

  def Counter.init() : (Counter.Model, Cmd<Counter.Msg>) do
    (%Counter.Model{count: 0, label: "clicks", snapshots: []}, Cmd.store.list(Counter.Msg.Loaded))
  end

  def Counter.again(id : Uuid) : Cmd<Counter.Msg> do
    Cmd.store.tx(
      fn (s : Store) ->
        case Store.get(s, id) do
          Option.Some(snap) -> ([Tx.update(id, %Counter.Snapshot{snap | saves: snap.saves + 1})], snap.saves + 1)
          Option.None -> ([], 0)
        end
      end,
      Counter.Msg.Done
    )
  end

  def Counter.update(msg : Counter.Msg, model : Counter.Model) : (Counter.Model, Cmd<Counter.Msg>) do
    case msg do
      Counter.Msg.Increment -> (%Counter.Model{model | count: model.count + 1}, Cmd.none())
      Counter.Msg.Add(n) -> if model.count + n >= 0 do (%Counter.Model{model | count: model.count + n}, Cmd.none()) else (model, Cmd.none()) end
      Counter.Msg.Rename(s) -> (%Counter.Model{model | label: s}, Cmd.none())
      Counter.Msg.Save -> (model, Cmd.store.insert(%Counter.Snapshot{count: model.count, label: model.label, saves: 1}, Counter.Msg.Saved))
      Counter.Msg.Saved(id) -> (model, Cmd.store.list(Counter.Msg.Loaded))
      Counter.Msg.Loaded(rows) -> (%Counter.Model{model | snapshots: rows}, Cmd.none())
      Counter.Msg.Again(id) -> (model, Counter.again(id))
      Counter.Msg.Done(result) -> (model, Cmd.store.list(Counter.Msg.Loaded))
    end
  end

  def Counter.view(model : Counter.Model) : Html<Counter.Msg> do
    shown = String.concat(String.concat(model.label, ": "), String.from_int(model.count))
    <div class="flex flex-col gap-2 p-4">
      <span class="font-bold">{shown}</span>
      <button class="rounded bg-blue-600 px-3 text-white" on-click={Counter.Msg.Increment}>+</button>
      <button on-click={Counter.Msg.Add(10)}>+10</button>
      <button on-click={Counter.Msg.Save}>Save</button>
      <ul>{List.map(model.snapshots, fn (snap : Counter.Snapshot) -> <li><button on-click={Counter.Msg.Again(snap.id)}>{snap.label} {String.from_int(snap.count)} x{String.from_int(snap.saves)}</button></li> end)}</ul>
    </div>
  end

  defapp Counter

  defroutes Main do
    "/" -> Counter
  end
  """

  # A text input and a submit button, on the example's Counter.
  @form_example """
  def Counter.form(model : Counter.Model) : Html<Counter.Msg> do
    <form on-submit={Counter.Msg.Save}>
      <input value={model.label} on-change={Counter.Msg.Rename} />
      <button type="submit">Save</button>
    </form>
  end
  """

  # A route table of the app's own, for `create_deployment`.
  @routes_example """
  defroutes Counter.Routes do
    "/" -> Counter
  end
  """

  # What an agent must see first. Claude Code shows a server's instructions
  # only up to about 4096 characters, so this part (with the "serving at"
  # line before it) must fit in 4000 (a test checks): the facts whose
  # absence cost the most in a real agent run, and the pointer to `guide`.
  @head """
  Kinoko is a code database. You change code by staging a patch that either
  PROMOTES (the whole committed image still typechecks) or stays staged with
  the exact reasons it cannot. Small patches read for their reasons are the
  fast path.

  CALL `guide` BEFORE YOUR FIRST PATCH: your client may cut these
  instructions short, and it holds the rest: a whole app with every
  declaration form, events and forms, stored data, and the whole stdlib.

  Code lives in UNIVERSES (named code databases). Every tool but
  `list_universes`, `create_universe`, `list_deployments` and `guide` takes an
  optional `universe` (default "main", which is shared).

  The language is Yabu: defmodel / deftype / def / deftest / defapp / defroutes.
  An app is one Elm-style loop: init() -> (Model, Cmd<Msg>), update(msg, model)
  -> (Model, Cmd<Msg>), view(model) -> Html<Msg>, JSX styled by Tailwind.

  THE SYNTAX YOU CANNOT GUESS (Elixir-flavoured, not ML or JS)
    %App.Model{count: 1, name: "x"}   construct; NO Model(...), .new or .create
    %App.Model{row | count: 2}        update a copy; there is no assignment
    %{"k" => v}   [1, 2]              map and list literals
    case msg do App.Msg.Add(n) -> ... end    match (`do`, never `of`)
    if c do a else b end              an expression; else is required
    fn (x : Int) -> x + 1 end         lambda
    not a / a and b / a or b          booleans; no `!`, `&&` or `||`
    x = e                             binds ONE name; no `(a, b) = e`
    case t do (m, cmd) -> m end       take a tuple apart; there is no `t.0`
    Option.Some(x) / Option.None      variants are qualified too
    deftest App.adds do always(App.add(1, 2) == 3) end
  Every name is fully qualified everywhere: `App.helper(x)`, never `helper(x)`.
  Construction lists EVERY field (no defaults); `{row | f: v}` copies the rest.
  A pattern is `_`, a lowercase name, an Int, String, true or false, a tuple
  or a variant. NO list patterns (`[]`, `[x | rest]`): use
  `case List.head(xs) do Option.Some(x) -> ... Option.None -> ... end`.
  There is no List.find: `List.head(List.filter(xs, fn (x : T) -> ... end))`.
  `defapp App` is a bare declaration: no `do` block, no options. It needs
  App.Model, App.Msg, App.init, App.update and App.view.
  Events: on-click, on-blur, on-focus, on-keydown, on-keyup and on-submit (on
  a <form>) take a message VALUE. Text comes in only through on-change on an
  input, textarea or select: an unapplied constructor of one String
  (`on-change={App.Msg.SetTitle}`), sent with the text on every edit.
  There is no on-input.
  A case arm's body is ONE expression: no `x = e` in it (bind before the
  case, or call a helper). Annotations name concrete types, never a type
  variable: a shared view helper returns `Html<App.Msg>`, not `Html<a>`.
  JSX text is trimmed at both ends: `by {name}` shows "byname"; write
  `{String.concat("by ", name)}`.

  THE LOOP
  1. Look first: `symbols`, then `read` what you will touch.
  2. `stage_patch` with a patch id and source (`remove` deletes symbols).
  3. `promoted: ids` is committed. `staged: id` is NOT success: fix each
     `- symbol [code] message` reason and restage THE SAME id.
  4. Prove it: `eval` an expression (`value : type`), `test` a deftest.

  SERVING YOUR APP
  `defroutes Main` is served at http://localhost:<port>/ by the built-in
  `local` deployment. To give an app its own address, give it a route table:
  #{@routes_example |> String.trim_trailing() |> String.split("\n") |> Enum.map_join("\n", &String.trim_trailing("  " <> &1))}
  and call `create_deployment` (name "counter", routes "Counter.Routes"): it
  serves at http://counter.localhost:<port>/ and follows the universe's head,
  so every promotion is live at once. `list_deployments` shows them all.
  There is no other way to make a deployment.
  """

  # The rest: `guide` answers the whole text.
  @body """
  DECLARATIONS: one whole app, every form you need (it promotes as written)
  #{@example |> String.trim_trailing() |> String.split("\n") |> Enum.map_join("\n", &String.trim_trailing("  " <> &1))}

  - defmodel: one `field : Type` per line, optionally `= <constant>` (a
    default; see STORED DATA). deftype: variants separated by `|`, a payload
    in parentheses, `Counter.Msg.Add(Int)`.
  - def: every parameter and the return type annotated; the body's last
    expression is the value. `next = expr` binds a local (no reassignment).
  - case arms are `Pattern -> expr`, one per line, and must cover every
    variant.
  - JSX: attributes are strings or `{expr}`; `{expr}` in a body renders its
    value. Any on-* other than the events above does nothing. A text input
    and a submit button:
  #{@form_example |> String.trim_trailing() |> String.split("\n") |> Enum.map_join("\n", &String.trim_trailing("    " <> &1))}
  - `defapp Counter` names an app; its name ends in a capitalized segment,
    and it needs Counter.Model (a defmodel), Counter.Msg (a deftype) and
    exactly `Counter.init() : (Counter.Model, Cmd<Counter.Msg>)`,
    `Counter.update(msg : Counter.Msg, model : Counter.Model) : (Counter.Model, Cmd<Counter.Msg>)`,
    `Counter.view(model : Counter.Model) : Html<Counter.Msg>`.
  - defroutes maps URL paths to apps; a deployment serves one route table.
    `:name` captures a segment
    and is passed to the app's `init` as a parameter, typed Int, String or
    Uuid: `"/post/:id" -> Forum.Post` needs
    `def Forum.Post.init(id : Uuid) : (Forum.Post.Model, Cmd<Forum.Post.Msg>)`
    (the init's parameter names are exactly the pattern's params, as a set;
    the URL fills them by name). A URL that does not parse as its type is a
    404.
  - Cmd.navigate(App, args...) goes to the route that opens App with those
    args: `Cmd.navigate(Forum.Post, topic.id)` from update, `Cmd.navigate(Forum.Settings)`
    when it takes none. Promotion checks that the target is an app and the
    args fit its init; whether a route reaches it is checked at run time, by
    the deployment serving the page (with none, the page shows an error).
  - `list_staged` shows every staged patch, its reasons and source;
    `unstage` drops one. `history` shows what promoted, and when.

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
  - Cmd values (effects) are data to `eval`: it shows the Cmd a function
    returns and runs nothing. A deployment serving the app runs them
    (Cmd.store.*, Cmd.time.now in Unix milliseconds, Cmd.random.int,
    Cmd.navigate); Cmd.blob.*
    and Cmd.ai.* are not available yet.

  STORED DATA (Cmd.store.*): the Model is session state and is gone on reload;
  durable rows go to the store. Each DEPLOYMENT has its own data (staging and
  prod never share rows), whatever commit it serves.
  - A STORED model is a defmodel with `id : Uuid`. Only stored models go
    through Cmd.store.* or Tx (else `not-stored`). Never write `id`:
    construction omits it (`%Counter.Snapshot{count: 1, label: "x", saves: 1}`),
    insert mints it, and every row read back carries a real one.
  - A stored model's fields may hold any data: scalars, List, Map, Option,
    tuples, nested models, your own deftype and Result<T, E> too. Every
    one is stored and read back exactly.
  - Cmd.store.insert(row, fn (id : Uuid) -> msg end)
    Cmd.store.list(fn (rows : List<M>) -> msg end)       insertion order, max 10000
    Cmd.store.get(id, fn (row : Option<M>) -> msg end)
    Cmd.store.update(id, row, fn (id : Uuid) -> msg end)  whole-row replace
    Cmd.store.delete(id, fn (row : Option<M>) -> msg end)
    The model M comes from the row (insert, update) or from the callback's
    type (list, get, delete), so pass a Msg constructor
    (`Cmd.store.list(Counter.Msg.Loaded)` with `Loaded(List<Counter.Snapshot>)`).
    A failed operation shows the page's error banner and sends no msg.
  - Read-modify-write is a TRANSACTION closure, run atomically (concurrent
    ones never lose an update):
      Cmd.store.tx(fn (s : Store) -> (List<Tx.Op>, r) end,
                   fn (result : Result<(List<Uuid>, r), String>) -> msg end)
    Inside it, read with Store.get(s, id) : Option<M> and Store.list(s) : List<M>
    (annotate when nothing else fixes M: `(Store.list(s) : List<App.Row>)`),
    and return the writes as ops: Tx.insert(row), Tx.update(id, row),
    Tx.delete(App.Row, id). They apply in order after the body returns (the
    body reads the data as it was before them); the callback gets
    Ok((inserted ids, r)) or Err(message), and on Err nothing was written.
    See Counter.again above.
  - Defaults: `saves : Int = 1`. A default is a constant (literal, list, map,
    tuple, variant of constants) of the field's type. It only fills in rows
    stored before the field existed; construction still lists EVERY field.
    An Option<T> field takes no default (absent reads as Option.None).
  - Evolution is ADD-ONLY, checked at promotion (`model-evolution`), for a
    stored model and for every model stored inside one (a field's List,
    Option, Map, tuple or nested model): a field never changes type and is
    never removed (leave it, unused), and a new field must be Option<T> or
    have a default. Changing a default is fine. A deftype stored inside one
    keeps every variant with exactly its payload and may only gain variants.
    Old code (a deployment pinned to an older commit) still reads rows newer
    code wrote; the newer fields are ignored.
  """

  @doc """
  The part every client shows: `text/0` up to the end of SERVING YOUR APP.
  Claude Code cuts a server's instructions at about 4096 characters.
  """
  @spec head() :: String.t()
  def head do
    port = Integer.to_string(KinokoWeb.Mcp.Tools.port())
    String.replace(serving(port) <> @head, "<port>", port)
  end

  defp serving(port), do: "Kinoko is serving at http://localhost:#{port}/.\n\n"

  @doc "The worked example the DECLARATIONS section shows: Yabu source that promotes."
  @spec example() :: String.t()
  def example, do: @example

  @doc """
  Every code example the instructions show, in order: each promotes when
  staged after the ones before it.
  """
  @spec examples() :: [String.t()]
  def examples, do: [@example, @form_example, @routes_example]

  @doc """
  The instructions text, with the stdlib generated from its table and
  `<port>` the port the endpoint listens on.
  """
  @spec text() :: String.t()
  def text do
    port = Integer.to_string(KinokoWeb.Mcp.Tools.port())

    String.replace(serving(port) <> @head <> "\n" <> @body, "<port>", port) <> "\n" <> stdlib()
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
    There is no List.find: `List.head(List.filter(xs, fn (x : T) -> ... end))`
    gives an Option<T>.
    That is all of it. If what you need is not listed, write it as your own def
    (fully qualified, in your patch) and say so rather than inventing a function.
    """
  end

  defp type_line(name, sig), do: Format.signature(name, sig) |> String.replace_prefix("type ", "")
end
