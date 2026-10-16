defmodule Kinoko.Lang do
  @moduledoc """
  The Yabu language core: parse, format, content-address, and stage code into
  a `Kinoko.Lang.Universe`. Pure values only; thread the returned universe.

  **Internal.** Only `Kinoko.CodeDb` (whose pure core this is) and
  `Kinoko.Universe` call it; every other caller uses `Kinoko.Universe`.
  Nothing calls the universe's own functions but this module.

  The universe keeps no text. What storage keeps is `durable/1` (names and
  CIDs only); declarations live in the CAS (`Kinoko.Cas`) by CID, and
  `restore/3` rebuilds the universe from both. `prepare/2` turns source into
  entries and the CAS rows to write before staging them (`stage_entries/3`);
  `snapshot/1` is what `Kinoko.Exec` runs against.

      iex> alias Kinoko.Lang
      iex> {u, {:staged, [reason]}} = Lang.stage(Lang.new(), "p1", "def A.f() : Int do\\n  A.g()\\nend")
      iex> reason.code
      "unbound"
      iex> {u, {:promoted, ["p1"]}} =
      ...>   Lang.stage(u, "p1", "def A.g() : Int do\\n  1\\nend\\n\\ndef A.f() : Int do\\n  A.g()\\nend")
      iex> Enum.map(Lang.symbols(u), & &1.name)
      ["A.f", "A.g"]
      iex> {:ok, "def A.g" <> _} = Lang.read(u, "A.g")

  ## Staging

  Staging the same id again replaces that patch; restaging identical source
  promotes a no-op round. A patch that cannot promote stays staged and carries
  its reasons; fix it and restage the same id.

  Restaging an id with source that does not parse drops what the id staged
  before (as `unstage/2` does) and returns `{:staged, [parse reason]}`: the
  id then stages nothing, so a later patch never promotes alongside the
  superseded one.

  `stage/4` and `unstage/2` never raise on a fault of the checker or the
  universe: they return the universe they were given, unchanged, with an
  `"internal"` reason (see each).

  ## Reason codes

  A reason is `%{name: String.t() | nil, code: String.t(), message: String.t()}`.
  Checker codes: "unbound", "mismatch", "arity", "occurs", "not-a-function",
  "unknown-field", "missing-field", "extra-field", "not-a-model",
  "non-exhaustive", "bad-pattern", "cannot-infer", "invalid-model-field",
  "non-data-map-key", "bad-app-shape", "bad-event", "bad-name",
  "type-too-large", "internal". Added by parser and universe: "parse" (message
  includes `line:col`), "duplicate" (a name defined twice in one patch),
  "bad-id" (an empty or non-string patch id), "bad-name" (a `remove:` entry
  that is not a string), "restore" (storage `restore/3` cannot rebuild from), and "internal"
  (a fault of the checker or universe, the universe left as it was).
  """

  alias Kinoko.Lang.{Ast, Cid, Codegen, Format, Graph, Parser, Universe}
  alias Kinoko.Lang.Types.{Check, Extract}

  @type reason :: %{name: String.t() | nil, code: String.t(), message: String.t()}
  @type snapshot :: %{committed: %{String.t() => map()}, signatures: map()}

  @doc "Parse source into declarations (with positions)."
  @spec parse(String.t()) :: {:ok, [Ast.decl()]} | {:error, map()}
  defdelegate parse(source), to: Parser, as: :program

  @doc "Canonical text of source text or of a list of declarations."
  @spec format(String.t() | [Ast.decl()]) :: {:ok, String.t()} | {:error, map()}
  def format(source) when is_binary(source) do
    with {:ok, decls} <- parse(source), do: format(decls)
  end

  def format(decls) when is_list(decls), do: {:ok, Format.program(decls)}

  @doc "Content identifier of a declaration."
  @spec cid(Ast.decl()) :: String.t()
  defdelegate cid(decl), to: Cid, as: :of

  @spec new() :: Universe.t()
  defdelegate new(), to: Universe

  @doc """
  Parse `source` and stage it under `id`, then promote whatever can.
  `remove: [name]` also stages removals.

  - A parse error drops what `id` staged before (`unstage/2`) and returns
    that universe with `{:staged, [%{code: "parse", ...}]}`.
  - An `id` that is not a string, or a `remove:` entry that is not, is
    refused (`"bad-id"`, `"bad-name"`): the universe is returned unchanged.
  - Should the checker or universe raise, the universe given is returned
    unchanged with `{:staged, [%{name: nil, code: "internal", message: ...}]}`.

  For tests and the REPL: the universe's callers `prepare/2` and then
  `stage_entries/3`.
  """
  @spec stage(Universe.t(), String.t(), String.t(), keyword()) ::
          {Universe.t(), {:promoted, [String.t()]} | {:staged, [reason]}}
  def stage(u, id, source, opts \\ [])

  def stage(u, id, source, opts) when is_binary(id) do
    guarded(u, fn ->
      case prepare(source, opts) do
        {:ok, entries, _texts} ->
          Universe.stage(u, id, entries)

        # Source that does not parse supersedes what `id` staged; input
        # refused for its type does not.
        {:error, [%{code: "parse"}] = reasons} when is_binary(source) ->
          {u, _} = Universe.unstage(u, id)
          {u, {:staged, reasons}}

        {:error, reasons} ->
          {u, {:staged, reasons}}
      end
    end)
  end

  def stage(u, id, _source, _opts), do: stage_entries(u, id, [])

  @doc """
  Parse `source` into the entries a patch stages, without staging them:
  `{:ok, entries, texts}`, where `entries` is each declaration as
  `{:live, decl}` and then each `remove:` name as `{:gone, name}`, and
  `texts` is `[{cid, canonical_text}]`, one per declaration in order (the
  CAS rows to put before staging). Pure.

  `{:error, [reason]}`: `"parse"` (with `line:col`; also for source that is
  not a string) or `"bad-name"` (a `remove:` entry that is not a string).
  """
  @spec prepare(String.t(), keyword()) ::
          {:ok, [Universe.entry()], [{String.t(), String.t()}]} | {:error, [reason]}
  def prepare(source, opts \\ []) do
    removes = Keyword.get(opts, :remove, [])

    cond do
      not is_list(removes) or not Enum.all?(removes, &is_binary/1) ->
        bad = if is_list(removes), do: Enum.find(removes, &(not is_binary(&1))), else: removes
        {:error, [refused("bad-name", "`remove:` lists names (strings), not #{shown(bad)}")]}

      not is_binary(source) ->
        {:error, [refused("parse", "source is a string, not #{shown(source)}")]}

      true ->
        case parse(source) do
          {:ok, decls} ->
            entries = Enum.map(decls, &{:live, &1}) ++ for(name <- removes, do: {:gone, name})
            {:ok, entries, Enum.map(decls, &{Cid.of(&1), Format.decl(&1)})}

          {:error, %{message: message, line: line, col: col}} ->
            {:error, [refused("parse", "#{line}:#{col}: #{message}")]}
        end
    end
  end

  @doc """
  Stage already parsed `entries` (`{:live, decl} | {:gone, name}`, as
  `prepare/2` gives them) under `id`, then promote whatever can. An `id`
  that is not a string is refused (`"bad-id"`); should the checker or
  universe raise (malformed entries included), the universe given is
  returned unchanged with an `"internal"` reason, as for `stage/4`.
  """
  @spec stage_entries(Universe.t(), String.t(), [Universe.entry()]) ::
          {Universe.t(), {:promoted, [String.t()]} | {:staged, [reason]}}
  def stage_entries(u, id, entries) when is_binary(id),
    do: guarded(u, fn -> Universe.stage(u, id, entries) end)

  def stage_entries(u, id, _entries),
    do: {u, {:staged, [refused("bad-id", "a patch id is a string, not #{shown(id)}")]}}

  @doc """
  Drop what `id` staged: `{u, true}`, or `{u, false}` when nothing is staged
  under `id`. Should the universe raise, the universe given is returned
  unchanged with `{:error, %{name: nil, code: "internal", message: ...}}`.
  """
  @spec unstage(Universe.t(), String.t()) :: {Universe.t(), boolean() | {:error, reason}}
  def unstage(u, id) when is_binary(id) do
    case guarded(u, fn -> Universe.unstage(u, id) end) do
      {u, {:staged, [reason]}} -> {u, {:error, reason}}
      result -> result
    end
  end

  def unstage(u, _id), do: {u, false}

  # `f.()`, or the universe as given and an internal reason if it raises.
  defp guarded(u, f) do
    f.()
  rescue
    e -> {u, {:staged, [refused("internal", Exception.message(e))]}}
  end

  defp refused(code, message), do: %{name: nil, code: code, message: message}

  defp shown(term), do: inspect(term, limit: 5, printable_limit: 64)

  @doc """
  Canonical text of `name`: the committed declaration; else, when no
  committed one has the name, the first staged one that defines it, staged
  patches taken in ascending id order (byte order of the id). A patch that
  only removes `name` gives nothing. `:error` when none defines it.
  """
  @spec read(Universe.t(), String.t()) :: {:ok, String.t()} | :error
  def read(u, name) do
    case Map.fetch(Universe.committed(u), name) do
      {:ok, %{decl: decl}} -> {:ok, Format.decl(decl)}
      :error -> read_staged(u, name)
    end
  end

  defp read_staged(u, name) do
    u
    |> Universe.staged()
    |> Enum.sort()
    |> Enum.flat_map(fn {_id, entries} -> entries end)
    |> Enum.find_value(:error, fn
      {:live, decl} -> if Ast.name(decl) == name, do: {:ok, Format.decl(decl)}
      {:gone, _} -> nil
    end)
  end

  @doc """
  Committed names, name-sorted, with cid and signature text
  (`Kinoko.Lang.Format.signature/2`).
  """
  @spec symbols(Universe.t()) :: [%{name: String.t(), cid: String.t(), signature: String.t()}]
  def symbols(u) do
    u
    |> Universe.committed()
    |> Enum.sort()
    |> Enum.map(fn {name, %{cid: cid, decl: decl}} ->
      %{name: name, cid: cid, signature: Format.signature(name, Extract.signature(decl))}
    end)
  end

  @doc """
  Committed code: `name => %{cid, decl, typed, deps, signature}`. `decl` has
  no positions; `typed` is its checked tree (every expression node's meta
  carries `type:` and `res:`), as checked against the signatures it now
  sees; `deps` the names its check consulted; `signature` its
  `Kinoko.Lang.Types.Extract.signature/1`.
  """
  @spec committed(Universe.t()) :: %{String.t() => map()}
  def committed(u) do
    sigs = Universe.signatures(u)
    Map.new(Universe.committed(u), fn {name, c} -> {name, Map.put(c, :signature, sigs[name])} end)
  end

  @doc """
  Every signature a check sees: the stdlib's and committed code's, by name
  (what `Kinoko.Lang.Types.Check.expr/2` takes to check an expression).
  """
  @spec signatures(Universe.t()) :: map()
  defdelegate signatures(u), to: Universe

  @doc """
  What is staged, by id: `%{source:, removes:, reasons:}`. `source` is the
  canonical text of the declarations the patch defines (`""` for none),
  `removes` the names it removes, in the order staged, and `reasons` why it
  cannot promote now (`reasons/2`, worked out afresh for each patch).
  """
  @spec staged(Universe.t()) :: %{
          String.t() => %{source: String.t(), removes: [String.t()], reasons: [reason]}
        }
  def staged(u) do
    Map.new(Universe.staged(u), fn {id, entries} ->
      {id,
       %{
         source: Format.program(for {:live, decl} <- entries, do: decl),
         removes: for({:gone, name} <- entries, do: name),
         reasons: Universe.reasons(u, id)
       }}
    end)
  end

  @doc "Why the patch staged under `id` cannot promote now; `[]` when none is staged under it."
  @spec reasons(Universe.t(), String.t()) :: [reason]
  defdelegate reasons(u, id), to: Universe

  @doc """
  What storage keeps of a universe:
  `%{commits: [commit], staged: [{id, [{name, cid | :gone}]}]}`, commits
  oldest first (as `history/1` gives them), staged patches in the order they
  were last staged. Only ids, names and CIDs: no declaration, no text.
  """
  @spec durable(Universe.t()) :: %{commits: [map()], staged: [{String.t(), [tuple()]}]}
  defdelegate durable(u), to: Universe

  @doc """
  The universe `durable/1` describes, given `decls`, the declaration of each
  CID (`%{cid => decl}`; parsed from the CAS's text). Committed code is
  checked again, then the staged patches are staged again in order, so
  their reasons are worked out afresh.

  `{:degraded, u, reasons}` when committed code no longer typechecks (the
  checker changed under it): `u` keeps committed code as stored and
  `reasons` say which declarations fail and why. A degraded universe
  stages, unstages and reads as ever, but a patch promotes only when the
  whole image typechecks with it; the first that does makes it sound again
  (`health/1`). Its `snapshot/1` is not runnable: check `health/1` first.

  `{:error, reasons}`: storage that cannot be restored at all, a
  `"restore"` reason for a CID with no declaration (`name: nil`, the message
  naming the CID) or a declaration that is not the CID or name it is given
  for.
  """
  @spec restore([map()], [{String.t(), [tuple()]}], %{String.t() => Ast.decl()}) ::
          {:ok, Universe.t()} | {:degraded, Universe.t(), [reason]} | {:error, [reason]}
  defdelegate restore(commits, staged, decls), to: Universe

  @doc """
  `:ok`, or `{:degraded, reasons}` while committed code does not typecheck
  (`restore/3` restored it degraded and nothing has promoted since).
  """
  @spec health(Universe.t()) :: :ok | {:degraded, [reason]}
  def health(u) do
    case Universe.degraded(u) do
      nil -> :ok
      reasons -> {:degraded, reasons}
    end
  end

  @doc """
  What `Kinoko.Exec` runs against: `%{committed: committed(u), signatures:
  signatures(u)}`. `check_expr/2` and `image/1` take it as they take a universe.
  """
  @spec snapshot(Universe.t()) :: %{committed: %{String.t() => map()}, signatures: map()}
  def snapshot(u), do: %{committed: committed(u), signatures: signatures(u)}

  @doc "Every promoted round, oldest first: `%{ids: [id], entries: [{:live, name, cid} | {:gone, name}]}`."
  @spec history(Universe.t()) :: [map()]
  defdelegate history(u), to: Universe

  @doc """
  The hash of the committed code's image (`Kinoko.Lang.Codegen.image_hash/1`):
  what `image/1` would name its module by, without compiling anything.
  """
  @spec image_hash(Universe.t() | snapshot()) :: String.t()
  def image_hash(%{committed: committed, signatures: _}), do: Codegen.image_hash(committed)
  def image_hash(u), do: u |> Universe.committed() |> Codegen.image_hash()

  @doc """
  The committed code's system graph (`Kinoko.Lang.Graph.of/1`): its apps
  with their route patterns, its stored models with their fields, and the
  `reads`/`writes` edges from apps to models.
  """
  @spec graph(Universe.t() | snapshot()) :: Graph.t()
  def graph(%{committed: committed, signatures: _}), do: Graph.of(committed)
  def graph(u), do: u |> committed() |> Graph.of()

  @doc """
  The committed code compiled to one Erlang module (`Kinoko.Lang.Codegen`):
  `{:ok, %{module:, binary:, hash:, names:, tests:, sometimes:}}`, where
  `names` is `%{def => {fun, arity}}`, `tests` `%{test => fun}` and
  `sometimes` `%{test => [source]}` (the `sometimes` sites each test
  writes); or `{:error, %{code: "compile" | "internal", message: m}}`,
  `"compile"` also when the code is past a cap (more than 20_000 defs and
  tests, or a def needing more than 10_000 Erlang variables). Nothing is
  loaded (`Kinoko.Exec.load/2` loads).
  """
  @spec image(Universe.t() | snapshot()) ::
          {:ok, map()} | {:error, %{code: String.t(), message: String.t()}}
  def image(%{committed: committed, signatures: _}), do: Codegen.compile(committed)
  def image(u), do: u |> committed() |> Codegen.compile()

  @doc """
  The expression `source` checked against the committed signatures (of a
  universe, a snapshot, or any map holding `signatures:`; it
  may stay polymorphic): `{:ok, typed, type}`, or `{:error, [reason]}`
  with a `"parse"` reason or the checker's.
  """
  @spec check_expr(Universe.t() | %{signatures: map()}, String.t()) ::
          {:ok, tuple(), term()} | {:error, [reason]}
  def check_expr(u, source) when is_binary(source) do
    sigs =
      case u do
        %{signatures: sigs} when not is_struct(u) -> sigs
        u -> signatures(u)
      end

    case Parser.expr(source) do
      {:ok, e} ->
        case Check.expr(Ast.without_positions(e), sigs).result do
          {:ok, typed} -> {:ok, typed, Keyword.fetch!(elem(typed, 1), :type)}
          {:error, errors} -> {:error, Enum.map(errors, &Map.put_new(&1, :name, nil))}
        end

      {:error, %{message: message, line: line, col: col}} ->
        {:error, [refused("parse", "#{line}:#{col}: #{message}")]}
    end
  end
end
