defmodule Kinoko.Lang do
  @moduledoc """
  The Yabu language core: parse, format, content-address, and stage code into
  a `Kinoko.Lang.Universe`. Pure values only; thread the returned universe.

      iex> alias Kinoko.Lang
      iex> {u, {:staged, [reason]}} = Lang.stage(Lang.new(), "p1", "def A.f() : Int do\\n  A.g()\\nend")
      iex> reason.code
      "unbound"
      iex> {u, {:promoted, ["p1"]}} =
      ...>   Lang.stage(u, "p1", "def A.g() : Int do\\n  1\\nend\\n\\ndef A.f() : Int do\\n  A.g()\\nend")
      iex> Enum.map(Lang.symbols(u), & &1.name)
      ["A.f", "A.g"]
      iex> {:ok, "def A.g" <> _} = Lang.read(u, "A.g")

  Staging the same id again replaces that patch; restaging identical source
  promotes a no-op round. A patch that cannot promote stays staged and carries
  its reasons; fix it and restage the same id.

  ## Reason codes

  A reason is `%{name: String.t() | nil, code: String.t(), message: String.t()}`.
  Checker codes: "unbound", "mismatch", "arity", "occurs", "not-a-function",
  "unknown-field", "missing-field", "extra-field", "not-a-model",
  "non-exhaustive", "bad-pattern", "cannot-infer", "invalid-model-field",
  "non-data-map-key", "bad-app-shape", "bad-event", "bad-name",
  "type-too-large", "internal". Added by parser and universe: "parse" (message
  includes `line:col`), "duplicate" (a name defined twice in one patch),
  "bad-id" (empty patch id), "restore" (inconsistent history).
  """

  alias Kinoko.Lang.{Ast, Cid, Format, Parser, Universe}
  alias Kinoko.Lang.Types.Extract

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
  Parse `source` and stage it under `id`. `remove: [name]` also stages removals.
  A parse error returns the universe untouched with a `"parse"` reason.
  """
  @spec stage(Universe.t(), String.t(), String.t(), keyword()) ::
          {Universe.t(), {:promoted, [String.t()]} | {:staged, [reason]}}
  def stage(u, id, source, opts \\ []) do
    case parse(source) do
      {:ok, decls} ->
        gone = for name <- Keyword.get(opts, :remove, []), do: {:gone, name}
        Universe.stage(u, id, Enum.map(decls, &{:live, &1}) ++ gone)

      {:error, %{message: message, line: line, col: col}} ->
        {u, {:staged, [%{name: nil, code: "parse", message: "#{line}:#{col}: #{message}"}]}}
    end
  end

  @spec unstage(Universe.t(), String.t()) :: {Universe.t(), boolean()}
  defdelegate unstage(u, id), to: Universe

  @doc "Canonical text of `name`: the committed declaration, else a staged one."
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
  Committed names, name-sorted, with cid and signature text. A def renders as
  `Name(T1, T2) : Ret`; a model as `model {f : T, ...}`; a type as
  `type Name<P> = V(T) | W`; apps and tests as `app` / `test`.
  """
  @spec symbols(Universe.t()) :: [%{name: String.t(), cid: String.t(), signature: String.t()}]
  def symbols(u) do
    u
    |> Universe.committed()
    |> Enum.sort()
    |> Enum.map(fn {name, %{cid: cid, decl: decl}} ->
      %{name: name, cid: cid, signature: render(name, Extract.signature(decl))}
    end)
  end

  defp render(name, {:def, params, ret}),
    do: "#{name}(#{types(params)}) : #{Format.type(ret)}"

  defp render(_, {:model, fields}),
    do:
      "model {" <> Enum.map_join(fields, ", ", fn {f, t} -> "#{f} : #{Format.type(t)}" end) <> "}"

  defp render(name, {:type, params, variants}) do
    head = if params == [], do: name, else: "#{name}<#{Enum.join(params, ", ")}>"

    "type #{head} = " <>
      Enum.map_join(variants, " | ", fn
        {v, []} -> v
        {v, ts} -> "#{v}(#{types(ts)})"
      end)
  end

  defp render(_, :app), do: "app"
  defp render(_, :test), do: "test"

  defp types(ts), do: Enum.map_join(ts, ", ", &Format.type/1)

  @spec history(Universe.t()) :: [map()]
  defdelegate history(u), to: Universe
end
