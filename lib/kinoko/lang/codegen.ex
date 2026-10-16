defmodule Kinoko.Lang.Codegen do
  @moduledoc """
  Committed Yabu code to one Erlang module, as abstract forms (piece 4;
  `docs/superpowers/specs/2026-10-15-yabu-erlang-codegen-design.md`). Pure:
  `:compile.noenv_forms/2` runs in the calling process
  (`:no_spawn_compiler_process`), and nothing here loads code.

  ## The image module

  - Its name is `:"yabu_img_<first 20 hex of image_hash/1>"`: the one atom an
    image adds, one per distinct committed code ever compiled.
  - Each def and each deftest is a function named by its position among
    the committed defs' and tests' names in sorted order: `d0`, `d1`, …. A
    def takes its parameters; a test takes none, and its value is ignored:
    it is scored by what it recorded (`Kinoko.Exec.Hooks`), each failed
    `always` and each `sometimes` that held.
  - `__yabu__/1` answers `names` (`%{def => {fun, arity}}`), `tests`
    (`%{test => fun}`), `image` (the hash), `models`
    (`%{model => [{field, type, default}]}`, declaration order: what JSON
    and the store need; `default` is the field default's value,
    `Kinoko.Lang.Rt.constant/1`, or `:none` without one) and
    `types` (`%{deftype => {params, [{variant, [type]}]}}`) and `routes`
    (`%{routes_name => [%{segments, app, params}]}`, declaration order, the
    first match wins): `segments` are `{:lit, s} | {:param, name}`, `params`
    is the target app's `init` parameters in order as `{name, type_name}`
    (`"Int" | "String" | "Uuid"`), read from the committed signatures. Match
    a path with `Kinoko.Lang.Routes`.

  Calls between defs are local calls, so a module is one consistent
  snapshot. A def used as a value is the external fun `fun Mod:dN/K`, the
  same term inside the module and in an expression evaluated against it
  (`expr_forms/3`).

  No atom is made from user text (see `Kinoko.Lang.Codegen.Expr`), and the
  positional atoms are bounded: an image holds at most `max_functions/0`
  defs and tests (`d0`..`d19999`), a function at most
  `Kinoko.Lang.Codegen.Expr.max_vars/0` variables (`V0`..`V9999`), and
  every image reuses the same names. Past either cap `compile/1` answers
  `{:error, %{code: "compile", message}}` before making the atom.
  """

  alias Kinoko.Lang.Codegen.Expr
  alias Kinoko.Lang.Format
  alias Kinoko.Lang.Rt

  @a 1
  @max_functions 20_000

  @compile_options [
    :binary,
    :return_errors,
    :return_warnings,
    :deterministic,
    :no_spawn_compiler_process,
    # Generated code binds what it may not use (a pattern's binders, a
    # sequenced part) and builds what a statement discards.
    :nowarn_unused_vars,
    :nowarn_ignored
  ]

  @doc "The options an image compiles with."
  @spec compile_options() :: [atom()]
  def compile_options, do: @compile_options

  @doc """
  `sha256` over the sorted committed `name <> "\\0" <> cid <> "\\n"` lines,
  as lowercase hex: two universes with the same code share it.
  """
  @spec image_hash(%{String.t() => %{cid: String.t()}}) :: String.t()
  def image_hash(committed) do
    lines =
      committed
      |> Enum.sort()
      |> Enum.map(fn {name, %{cid: cid}} -> [name, 0, cid, ?\n] end)

    Base.encode16(:crypto.hash(:sha256, lines), case: :lower)
  end

  @doc "The image module's name for `hash`."
  @spec module_name(String.t()) :: atom()
  def module_name(<<prefix::binary-size(20), _::binary>>), do: :"yabu_img_#{prefix}"

  @doc """
  The module's forms: `{module, forms, names, tests}`, where `names` is
  `%{def => {fun, arity}}` and `tests` is `%{test => fun}`.
  """
  @spec forms(map()) :: {atom(), [tuple()], map(), map()}
  def forms(committed), do: forms(committed, image_hash(committed))

  defp forms(committed, hash) do
    module = module_name(hash)

    runnable =
      committed
      |> Enum.filter(fn {_, %{typed: {kind, _, _}}} -> kind in [:def, :deftest] end)
      |> limit_functions!()
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.map(fn {{name, %{typed: typed}}, i} -> {name, :"d#{i}", typed} end)

    names =
      for {name, fun, {:def, _, [_, ps, _, _]}} <- runnable,
          into: %{},
          do: {name, {fun, length(ps)}}

    tests = for {name, fun, {:deftest, _, _}} <- runnable, into: %{}, do: {name, fun}

    functions =
      Enum.map(runnable, fn {name, fun, typed} -> function(name, fun, typed, names, module) end)

    exports =
      [{:__yabu__, 1} | Enum.map(runnable, fn {_, fun, typed} -> {fun, arity(typed)} end)]

    meta = %{
      names: names,
      tests: tests,
      image: hash,
      # Each model's fields as `{field, type, default}`, the default as
      # its value (`Kinoko.Lang.Rt.constant/1`; `:none` without one).
      models:
        for(
          {name, %{signature: {:model, fields}}} <- committed,
          into: %{},
          do: {name, Enum.map(fields, fn {f, t, d} -> {f, t, Rt.constant(d)} end)}
        ),
      types:
        for(
          {name, %{signature: {:type, params, variants}}} <- committed,
          into: %{},
          do: {name, {params, variants}}
        ),
      routes:
        for(
          {name, %{signature: {:routes, routes}}} <- committed,
          into: %{},
          do: {name, Enum.map(routes, &route_entry(&1, committed))}
        )
    }

    forms =
      [
        {:attribute, @a, :module, module},
        {:attribute, @a, :export, exports}
      ] ++ functions ++ [yabu(meta), {:eof, @a}]

    {module, forms, names, tests}
  end

  # A route with its target's init parameters (the image typechecks, so the
  # target and its init exist; a missing one yields no params).
  defp route_entry({segments, app}, committed) do
    params =
      case Map.get(committed, app <> ".init") do
        %{signature: {:def, types, _, names}} ->
          for {n, {:named, t}} <- Enum.zip(names, types), do: {n, t}

        _ ->
          []
      end

    %{segments: segments, app: app, params: params}
  end

  # Counted before any `dN` atom is made: every image reuses `d0`, `d1`, …,
  # so the cap bounds the atoms all images share.
  defp limit_functions!(runnable) do
    if length(runnable) > @max_functions do
      throw(
        {:codegen_limit,
         "the image has #{length(runnable)} defs and tests; at most #{@max_functions} compile"}
      )
    end

    runnable
  end

  defp arity({:def, _, [_, ps, _, _]}), do: length(ps)
  defp arity({:deftest, _, _}), do: 0

  defp function(name, fun, {:def, _, [_name, params, _ret, body]}, names, module) do
    ctx = Expr.ctx(names, module, true, name)
    {vars, ctx} = Expr.params(ctx, params)
    {forms, _} = Expr.body(body, ctx)
    {:function, @a, fun, length(params), [{:clause, @a, vars, [], forms}]}
  end

  defp function(name, fun, {:deftest, _, [_name, body]}, names, module) do
    {forms, _} = Expr.body(body, Expr.ctx(names, module, true, name))
    {:function, @a, fun, 0, [{:clause, @a, [], [], forms}]}
  end

  defp yabu(meta) do
    clauses =
      for key <- [:names, :tests, :image, :models, :types, :routes] do
        {:clause, @a, [Expr.lit(key)], [], [Expr.lit(Map.fetch!(meta, key))]}
      end

    {:function, @a, :__yabu__, 1, clauses}
  end

  @doc """
  The committed code compiled:
  `{:ok, %{module, binary, hash, names, tests, sometimes}}`, where
  `sometimes` is `%{test => [source]}`: each `sometimes` site written in the
  test (`sometimes_sites/1`). `{:error, %{code: "compile", message}}` when
  the compiler refuses the forms or the code is past a cap (see the
  moduledoc), `{:error, %{code: "internal", message}}`
  when lowering them faults.
  """
  @spec compile(map()) :: {:ok, map()} | {:error, %{code: String.t(), message: String.t()}}
  def compile(committed) do
    hash = image_hash(committed)
    {module, forms, names, tests} = forms(committed, hash)

    case :compile.noenv_forms(forms, @compile_options) do
      {:ok, ^module, binary, _warnings} ->
        {:ok,
         %{
           module: module,
           binary: binary,
           hash: hash,
           names: names,
           tests: tests,
           sometimes:
             for(
               {name, %{typed: {:deftest, _, [_, body]}}} <- committed,
               into: %{},
               do: {name, sometimes_sites(body)}
             )
         }}

      {:error, errors, _warnings} ->
        {:error, %{code: "compile", message: inspect(errors, limit: 50)}}
    end
  rescue
    e -> {:error, %{code: "internal", message: Exception.message(e)}}
  catch
    :throw, {:codegen_limit, message} -> {:error, %{code: "compile", message: message}}
  end

  @doc "The most defs and tests (together) one image may hold."
  @spec max_functions() :: pos_integer()
  def max_functions, do: @max_functions

  @doc """
  The source of each `sometimes` site in `tree`, in the order written, each
  once (as Rust's `Program` finds a declaration's sites: one site per
  distinct expression, `fn` bodies included). The source is
  `Kinoko.Lang.Format.expr/1` of the asserted expression, as the generated
  code records it.
  """
  @spec sometimes_sites(term()) :: [String.t()]
  def sometimes_sites(tree), do: tree |> sites([]) |> Enum.reverse() |> Enum.uniq()

  defp sites({:sometimes, meta, [x]}, acc) when is_list(meta),
    do: sites(x, [Format.expr(x) | acc])

  defp sites({kind, meta, args}, acc) when is_atom(kind) and is_list(meta) and is_list(args),
    do: sites(args, acc)

  defp sites(list, acc) when is_list(list), do: Enum.reduce(list, acc, &sites/2)

  defp sites(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> sites(acc)

  defp sites(_, acc), do: acc

  @doc """
  A checked expression's forms, for `:erl_eval.exprs/2` with no bindings:
  it calls the image's defs remotely (`module:dN(...)`), its models through
  `module:'__yabu__'(models)`, and the runtime through
  `Kinoko.Lang.Rt`. `names` is the image's `names`. Throws
  `{:codegen_limit, message}` when the expression needs more variables
  than `Kinoko.Lang.Codegen.Expr.max_vars/0`.
  """
  @spec expr_forms(tuple(), map(), atom()) :: [tuple()]
  def expr_forms(typed, names, module) do
    {forms, _} = Expr.body(typed, Expr.ctx(names, module, false))
    forms
  end
end
