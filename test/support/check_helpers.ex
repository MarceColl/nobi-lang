defmodule Kinoko.Lang.CheckHelpers do
  @moduledoc """
  What the checker's test files share (ported from the Rust crate's
  `tests/checking/mod.rs`): TS's `checkAll`, `firstError` and `expectAllOk`,
  and the types of a lone expression.
  """

  import ExUnit.Assertions

  alias Kinoko.Lang.{Ast, Format, Parser}
  alias Kinoko.Lang.Types.{Check, Extract, Stdlib}

  @msg """
  deftype M.Msg do Inc | Dec | Set(Int) end
  deftype N.Other do Z end
  def M.handle(m : M.Msg) : Int do 1 end
  def N.take(o : N.Other) : Int do 1 end
  """

  @doc "`M.Msg`, and what a nested pattern's type can turn out to be."
  def msg, do: @msg

  def parse(src) do
    case Parser.program(src) do
      {:ok, decls} -> decls
      {:error, e} -> flunk("#{inspect(src)}: #{inspect(e)}")
    end
  end

  def named(n), do: {:named, n}

  @doc "TS's `checkAll`: every declaration, against the stdlib and every declaration's signature."
  def check_all(src), do: Check.program(parse(src), Stdlib.signatures())

  @doc "Every error of the first declaration that fails, in program order."
  def errors(src) do
    results = check_all(src)

    Enum.find_value(parse(src), fn d ->
      case results[Ast.name(d)] do
        %{result: {:error, errs}} -> errs
        _ -> nil
      end
    end) || flunk("#{inspect(src)}: expected a type error, everything checked")
  end

  def first_error(src), do: hd(errors(src))

  def found(src), do: Enum.map(errors(src), &{&1.code, &1.message})

  def codes(%{result: {:ok, _}}), do: []
  def codes(%{result: {:error, errs}}), do: Enum.map(errs, & &1.code)

  @doc "TS's `expectAllOk`: every typed declaration by name."
  def all_ok(src) do
    src
    |> check_all()
    |> Map.new(fn
      {name, %{result: {:ok, typed}}} ->
        {name, typed}

      {name, %{result: {:error, errs}}} ->
        flunk("#{inspect(src)}: #{name} failed: #{inspect(errs)}")
    end)
  end

  def last_name(src), do: src |> parse() |> List.last() |> Ast.name()

  @doc "The value of the last declaration's body, a def's."
  def checks(src) do
    case all_ok(src)[last_name(src)] do
      {:def, _, [_, _, _, {:block, _, [_, last]}]} -> last
      other -> flunk("#{inspect(src)}: the last declaration is not a def: #{inspect(other)}")
    end
  end

  def last_checked(src), do: check_all(src)[last_name(src)]

  def ty({_, m, _}), do: Keyword.fetch!(m, :type)
  def res({_, m, _}), do: Keyword.fetch!(m, :res)

  def sorted(set), do: set |> MapSet.to_list() |> Enum.sort()

  @doc "The types of a lone expression's checked tree, each written out, outermost first."
  def lone_types(src), do: lone_types_in("", src)

  def lone_types_in(decls, src) do
    sigs =
      parse(decls)
      |> Map.new(&{Ast.name(&1), Extract.signature(&1)})
      |> then(&Map.merge(Stdlib.signatures(), &1))

    {:ok, expr} = Parser.expr(src)

    case Check.expr(expr, sigs).result do
      {:ok, typed} -> {:ok, typed |> walk([]) |> Enum.reverse()}
      {:error, errs} -> {:error, errs}
    end
  end

  defp walk({kind, _, args} = e, out) do
    out = [Format.type(ty(e)) | out]

    case {kind, args} do
      {k, items} when k in [:list, :tuple] -> Enum.reduce(items, out, &walk/2)
      {:call, [_, items]} -> Enum.reduce(items, out, &walk/2)
      {:annot, [x, _]} -> walk(x, out)
      _ -> out
    end
  end
end
