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

  - defmodel: one `field : Type` per line, optionally `= <constant>` (a
    default; see STORED DATA). deftype: variants separated by `|`, a payload
    in parentheses, `Counter.Msg.Add(Int)`.
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
    (the init's parameter names are exactly the pattern's params, as a set;
    the URL fills them by name). A URL that does not parse as its type is a
    404.
  - Cmd.navigate(App, args...) goes to the route that opens App with those
    args: `Cmd.navigate(Forum.Post, topic.id)` from update, `Cmd.navigate(Forum.Settings)`
    when it takes none. Promotion checks that the target is an app and the
    args fit its init; whether a route reaches it is checked at run time, by
    the deployment serving the page (with none, the page shows an error).

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
  - Cmd values (effects) are data to `eval`: it shows the Cmd a function
    returns and runs nothing. A deployment serving the app runs them
    (Cmd.store.*, Cmd.time.now, Cmd.random.int, Cmd.navigate); Cmd.blob.*
    and Cmd.ai.* are not available yet.

  STORED DATA (Cmd.store.*): the Model is session state and is gone on reload;
  durable rows go to the store. Each DEPLOYMENT has its own data (staging and
  prod never share rows), whatever commit it serves.
  - A STORED model is a defmodel with `id : Uuid`. Only stored models go
    through Cmd.store.* or Tx (else `not-stored`). Never write `id`:
    construction omits it (`%Counter.Snapshot{count: 1, label: "x", saves: 1}`),
    insert mints it, and every row read back carries a real one.
  - Cmd.store.insert(row, fn (id : Uuid) -> msg end)
    Cmd.store.list(fn (rows : List<M>) -> msg end)       insertion order, max 10000
    Cmd.store.get(id, fn (row : Option<M>) -> msg end)
    Cmd.store.update(id, row, fn (id : Uuid) -> msg end)  whole-row replace
    Cmd.store.delete(id, fn (row : Option<M>) -> msg end)
    The model M comes from the callback's type, so pass a Msg constructor
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
