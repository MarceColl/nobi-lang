defmodule Kinoko.Lang.SalsaGraph do
  @moduledoc """
  A random query graph for the salsa model test (`Graph` and `Fresh` in
  `crates/yabu/tests/salsa.rs`). Query `i` runs the steps `env[i]`, mixing
  what each read gives into a small value, so many changes compute an equal
  one (early cutoff).

  Steps: `{:input, k}`, `{:query, j}`, `{:branch, k, odd, even}` (read `k`,
  then ask `odd` if it is odd, `even` if not), `{:ignore, j}` (ask `j`,
  reading an error as 0).

  `fresh/4` evaluates the same graph from scratch with no memo: a query asked
  while being evaluated is a cycle, and a query fails with the first error a
  query it asked met, even one it ignored.
  """
  @behaviour Kinoko.Lang.Salsa

  alias Kinoko.Lang.Salsa

  @impl true
  def compute(q, r), do: body(Salsa.env(r), q, r, &Salsa.input/2, &Salsa.ask/2)

  @doc "What `query` gives in `ctx`, from scratch; `layers` is `%{{layer, key} => value | nil}`."
  def fresh(steps, layers, ctx, query) do
    st = %{steps: steps, layers: layers, ctx: ctx, active: [], failed: nil}
    {answer, _} = fresh_ask(st, query)
    answer
  end

  defp body(steps, i, st, read, ask) do
    steps
    |> Enum.at(i)
    |> Enum.reduce_while({0, st}, fn step, {acc, st} ->
      case step(step, st, read, ask) do
        {{:ok, v}, st} -> {:cont, {rem(acc * 7 + v, 5), st}}
        {{:error, _}, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {{:error, _}, _} = err -> err
      {acc, st} -> {{:ok, acc}, st}
    end
  end

  defp step({:input, k}, st, read, _ask) do
    {v, st} = read.(st, k)
    {{:ok, if(v, do: v + 1, else: 0)}, st}
  end

  defp step({:query, j}, st, _read, ask), do: ask.(st, j)

  defp step({:branch, k, odd, even}, st, read, ask) do
    {v, st} = read.(st, k)
    ask.(st, if(v != nil and rem(v, 2) == 1, do: odd, else: even))
  end

  defp step({:ignore, j}, st, _read, ask) do
    case ask.(st, j) do
      {{:ok, v}, st} -> {{:ok, v}, st}
      {{:error, _}, st} -> {{:ok, 0}, st}
    end
  end

  defp fresh_read(st, key) do
    held =
      Enum.find_value(st.ctx, fn layer ->
        case Map.fetch(st.layers, {layer, key}) do
          {:ok, v} -> {v}
          :error -> nil
        end
      end)

    {if(held, do: elem(held, 0)), st}
  end

  defp fresh_ask(st, q) do
    {answer, st} =
      if q in st.active do
        {{:error, {:cycle, q}}, st}
      else
        outer = st.failed
        st = %{st | active: [q | st.active], failed: nil}
        {value, st} = body(st.steps, q, st, &fresh_read/2, &fresh_ask/2)
        failed = st.failed
        st = %{st | active: tl(st.active), failed: outer}
        {if(failed, do: {:error, failed}, else: value), st}
      end

    case answer do
      {:error, e} -> {answer, %{st | failed: st.failed || e}}
      _ -> {answer, st}
    end
  end
end
