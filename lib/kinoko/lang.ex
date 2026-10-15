defmodule Kinoko.Lang do
  @moduledoc """
  The Yabu language core: parse, format, content-address, and stage code into
  a `Kinoko.Lang.Universe`. Pure values only; thread the returned universe.
  Every other piece of Kinoko goes through this module, never through the
  universe's own functions.

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
  that is not a string), "restore" (inconsistent history), and "internal"
  (a fault of the checker or universe, the universe left as it was).
  """

  alias Kinoko.Lang.{Ast, Cid, Codegen, Format, Parser, Universe}
  alias Kinoko.Lang.Types.{Check, Extract}

  @type reason :: %{name: String.t() | nil, code: String.t(), message: String.t()}

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
  """
  @spec stage(Universe.t(), String.t(), String.t(), keyword()) ::
          {Universe.t(), {:promoted, [String.t()]} | {:staged, [reason]}}
  def stage(u, id, source, opts \\ []) do
    removes = Keyword.get(opts, :remove, [])

    cond do
      not is_binary(id) ->
        {u, {:staged, [refused("bad-id", "a patch id is a string, not #{shown(id)}")]}}

      not is_list(removes) or not Enum.all?(removes, &is_binary/1) ->
        bad = if is_list(removes), do: Enum.find(removes, &(not is_binary(&1))), else: removes

        {u,
         {:staged, [refused("bad-name", "`remove:` lists names (strings), not #{shown(bad)}")]}}

      not is_binary(source) ->
        {u, {:staged, [refused("parse", "source is a string, not #{shown(source)}")]}}

      true ->
        guarded(u, fn -> stage_source(u, id, source, removes) end)
    end
  end

  defp stage_source(u, id, source, removes) do
    case parse(source) do
      {:ok, decls} ->
        gone = for name <- removes, do: {:gone, name}
        Universe.stage(u, id, Enum.map(decls, &{:live, &1}) ++ gone)

      {:error, %{message: message, line: line, col: col}} ->
        {u, _} = Universe.unstage(u, id)
        {u, {:staged, [refused("parse", "#{line}:#{col}: #{message}")]}}
    end
  end

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

  @doc "The canonical source of a declaration ever committed, by CID; `nil` if none was."
  @spec text(Universe.t(), String.t()) :: String.t() | nil
  defdelegate text(u, cid), to: Universe

  @doc """
  A universe from what storage keeps: `rounds` (oldest first, as `history/1`
  gives them) and `texts` (canonical source by CID, as `text/2` gives it).
  `{:error, reasons}` when they are inconsistent or the code they build
  does not typecheck.
  """
  @spec restore([map()], %{String.t() => String.t()}) :: {:ok, Universe.t()} | {:error, [reason]}
  defdelegate restore(rounds, texts), to: Universe

  @doc "Every promoted round, oldest first: `%{ids: [id], entries: [{:live, name, cid} | {:gone, name}]}`."
  @spec history(Universe.t()) :: [map()]
  defdelegate history(u), to: Universe

  @doc """
  The committed code compiled to one Erlang module (`Kinoko.Lang.Codegen`):
  `{:ok, %{module:, binary:, hash:, names:, tests:, sometimes:}}`, where
  `names` is `%{def => {fun, arity}}`, `tests` `%{test => fun}` and
  `sometimes` `%{test => [source]}` (the `sometimes` sites each test
  writes); or `{:error, %{code: "compile" | "internal", message: m}}`.
  Nothing is loaded (`Kinoko.Exec.load/1` loads).
  """
  @spec image(Universe.t()) :: {:ok, map()} | {:error, %{code: String.t(), message: String.t()}}
  def image(u), do: u |> committed() |> Codegen.compile()

  @doc """
  The expression `source` checked against the committed signatures (it
  may stay polymorphic): `{:ok, typed, type}`, or `{:error, [reason]}`
  with a `"parse"` reason or the checker's.
  """
  @spec check_expr(Universe.t(), String.t()) :: {:ok, tuple(), term()} | {:error, [reason]}
  def check_expr(u, source) when is_binary(source) do
    case Parser.expr(source) do
      {:ok, e} ->
        case Check.expr(Ast.without_positions(e), signatures(u)).result do
          {:ok, typed} -> {:ok, typed, Keyword.fetch!(elem(typed, 1), :type)}
          {:error, errors} -> {:error, Enum.map(errors, &Map.put_new(&1, :name, nil))}
        end

      {:error, %{message: message, line: line, col: col}} ->
        {:error, [refused("parse", "#{line}:#{col}: #{message}")]}
    end
  end
end
