defmodule NobiWeb.Console.Cell do
  @moduledoc """
  A stored value (`Nobi.Lang.Rt`) as the Data stage's table shows it: as
  a person reads it, not as source. Int and Float as their number, String as its text,
  Uuid as its canonical string, Bool as `true`/`false`, Option as its
  value or blank, anything else (list, map, record, tuple, variant) as the
  compact JSON `Nobi.Lang.Rt.Json` writes for `JSON.stringify`.
  """

  alias Nobi.Lang.Rt.Json

  @doc "`value`'s cell text; `models` gives a record's field order."
  @spec text(term(), map()) :: String.t()
  def text(n, _models) when is_integer(n), do: Integer.to_string(n)
  def text(f, _models) when is_float(f), do: Nobi.Lang.Rt.float_text(f)
  def text(s, _models) when is_binary(s), do: s
  def text(b, _models) when is_boolean(b), do: Atom.to_string(b)
  def text({:uuid, s}, _models), do: s
  def text({:var, "Option", "None", []}, _models), do: ""
  def text({:var, "Option", "Some", [v]}, models), do: text(v, models)

  def text(v, models) do
    case Json.stringify(v, nil, models) do
      {:var, "Result", "Ok", [json]} -> json
      _ -> ""
    end
  end

  @doc "Whether a column of `type` is right-aligned in mono, as the prototype's `cents`."
  @spec numeric?(term()) :: boolean()
  def numeric?({:named, "Int"}), do: true
  def numeric?({:named, "Float"}), do: true
  def numeric?(_type), do: false
end
