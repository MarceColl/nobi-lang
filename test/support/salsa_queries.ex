defmodule Nobi.Lang.SalsaQueries do
  @moduledoc """
  The queries `Nobi.Lang.SalsaTest` uses: the Rust `Tests` impl of
  `crates/nobi/tests/salsa.rs`, one clause per variant.

  A declaration's source is `text|D,E`; `{:sig, name}` is its first
  character (cheap, often unchanged), `{:check, name}` its text and each
  dependency's `:sig`. A missing source is a domain error, memoized like any
  value: `{:error, "no source for A"}`.
  """
  @behaviour Nobi.Lang.Salsa

  alias Nobi.Lang.Salsa

  @impl true
  def compute({:sig, name}, r) do
    case source(r, name) do
      {{:ok, {text, _}}, r} -> {{:ok, String.slice(text, 0, 1)}, r}
      {err, r} -> {err, r}
    end
  end

  def compute({:check, name}, r) do
    case source(r, name) do
      {{:ok, {text, deps}}, r} ->
        Enum.reduce_while(deps, {{:ok, text}, r}, fn dep, {{:ok, text}, r} ->
          case Salsa.ask(r, {:sig, dep}) do
            {{:ok, sig}, r} -> {:cont, {{:ok, text <> "+" <> sig}, r}}
            {err, r} -> {:halt, {err, r}}
          end
        end)

      {err, r} ->
        {err, r}
    end
  end

  # Reads nothing: TS's context-free `parse(hash)`.
  def compute({:parse, hash}, r), do: {{:ok, "ast-of-" <> hash}, r}
  def compute({:echo, args}, r), do: {{:ok, Enum.join(args, "|")}, r}
  def compute(:loop, r), do: Salsa.ask(r, :loop)

  def compute(:loop_quietly, r) do
    {_ignored, r} = Salsa.ask(r, :loop_quietly)
    {{:ok, "fine"}, r}
  end

  def compute({:chain, 0}, r), do: {{:ok, "end"}, r}
  def compute({:chain, n}, r), do: Salsa.ask(r, {:chain, n - 1})

  defp source(r, name) do
    case Salsa.input(r, name) do
      {nil, r} ->
        {{:error, "no source for #{name}"}, r}

      {src, r} ->
        {text, deps} =
          case String.split(src, "|", parts: 2) do
            [text, deps] -> {text, deps}
            [text] -> {text, ""}
          end

        deps = deps |> String.split(",") |> Enum.flat_map(&List.wrap(String.first(&1)))
        {{:ok, {text, deps}}, r}
    end
  end
end
