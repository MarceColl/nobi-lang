defmodule KinokoWeb.ConsoleHelpers do
  @moduledoc "Test helpers for the `/_` console LiveViews."

  import ExUnit.Assertions, only: [flunk: 1]
  import Phoenix.LiveViewTest, only: [has_element?: 2, render: 1]

  @doc """
  Waits up to `ms` for `check` to hold on `view`, re-rendering between
  tries: `check` is a selector (`has_element?/2`) or a zero-arity function.
  Flunks with the last render when it never does.
  """
  def eventually(view, check, ms \\ 5_000),
    do: wait(view, check, System.monotonic_time(:millisecond) + ms)

  defp wait(view, check, deadline) do
    cond do
      holds?(view, check) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("never held: #{describe(check)}\n#{render(view)}")

      true ->
        receive do
        after
          5 -> wait(view, check, deadline)
        end
    end
  end

  defp holds?(view, selector) when is_binary(selector), do: has_element?(view, selector)

  defp holds?(view, check) when is_function(check, 0) do
    _ = render(view)
    check.()
  end

  defp describe(selector) when is_binary(selector), do: selector
  defp describe(check), do: inspect(check)
end
