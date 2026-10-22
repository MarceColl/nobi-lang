defmodule Nobi.Lang.Routes do
  @moduledoc """
  The pure route matcher: a route table's entries (`__nobi__(:routes)`, see
  `Nobi.Lang.Codegen`) against a URL path, and back. (The checker for
  `defroutes` is `Nobi.Lang.Types.Routes`.)

  An entry is `%{segments, app, params}`; `params` is the target `init`'s
  parameters in order as `{name, "Int" | "String" | "Uuid"}`, and the
  argument values match and `path/3` takes follow that order. Values are
  BEAM terms (`Nobi.Lang.Rt`): Int integer, String binary, Uuid
  `{:uuid, binary}`.

  Rules, chosen so each value has exactly one URL:

  - The first entry that matches wins.
  - A path starts with `/`; one trailing slash is ignored (`/post/1/` is
    `/post/1`; `/` is the root). Any empty segment elsewhere (`//`) matches
    nothing. A query or fragment is not part of the path.
  - Segments are split before percent-decoding, so `%2F` stays inside a
    String param. A literal segment compares after decoding, so `/%6E/5`
    matches `/n/5`: a URL has several spellings, `path/3` gives one.
  - Int: optional `-`, then digits without leading zeros (`0` alone), at
    most `Rt.max_int_digits/0` of them; `+1`, `007`, `-0`, `1.0` are 404s.
  - Uuid: canonical lowercase 36 characters (`8-4-4-4-12` hex); uppercase
    is a 404.
  - String: any non-empty, valid UTF-8 text after percent-decoding, except
    `.` and `..` (browsers normalise them away); invalid percent-encoding is
    a 404.
  - `path/3` only answers a path that `match/2` resolves back to the same
    app and args: an entry that cannot build, or is shadowed by an earlier
    entry, is skipped for the next entry of that app.
  - Pattern params and init params that do not line up raise
    `ArgumentError` (the checker prevents it).
  """

  alias Nobi.Lang.Rt

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @type entry :: %{segments: [tuple()], app: String.t(), params: [{String.t(), String.t()}]}

  @doc "The app and `init` arguments the path opens, or `:not_found`."
  @spec match([entry()], String.t()) :: {:ok, String.t(), [term()]} | :not_found
  def match(entries, path) when is_binary(path) do
    case split(path) do
      {:ok, parts} -> Enum.find_value(entries, :not_found, &match_entry(&1, parts))
      :error -> :not_found
    end
  end

  @doc "The URL path for opening `app` with `args` (`init`'s order), or `:error`."
  @spec path([entry()], String.t(), [term()]) :: {:ok, String.t()} | :error
  def path(entries, app, args) do
    # An entry that cannot build these args, or whose path an earlier entry
    # would capture, is skipped: a path always round-trips with `match/2`.
    Enum.find_value(entries, :error, fn
      %{app: ^app} = e ->
        with {:ok, p} <- build(e, args),
             {:ok, ^app, ^args} <- match(entries, p) do
          {:ok, p}
        else
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  # ---------- match ----------

  defp split("/" <> rest) do
    parts = String.split(rest, "/")

    parts =
      case parts do
        [""] -> []
        [_, _ | _] -> if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
        _ -> parts
      end

    if "" in parts, do: :error, else: {:ok, parts}
  end

  defp split(_), do: :error

  defp match_entry(%{segments: segs, app: app, params: params} = e, parts) do
    check_params!(e)

    with true <- length(segs) == length(parts),
         {:ok, bound} <- bind(Enum.zip(segs, parts), %{}, Map.new(params)),
         {:ok, args} <- ordered(params, bound) do
      {:ok, app, args}
    else
      _ -> nil
    end
  end

  defp bind([], acc, _), do: {:ok, acc}

  defp bind([{{:lit, s}, part} | rest], acc, types) do
    if decode(part) == {:ok, s}, do: bind(rest, acc, types), else: :error
  end

  defp bind([{{:param, n}, part} | rest], acc, types) do
    with {:ok, type} <- Map.fetch(types, n),
         {:ok, v} <- parse(type, part) do
      bind(rest, Map.put(acc, n, v), types)
    else
      _ -> :error
    end
  end

  defp ordered(params, bound) do
    Enum.reduce_while(params, {:ok, []}, fn {n, _}, {:ok, acc} ->
      case Map.fetch(bound, n) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      :error -> :error
    end
  end

  defp parse("Int", part) do
    with {:ok, s} <- decode(part),
         true <- Regex.match?(~r/\A(0|-?[1-9][0-9]*)\z/, s),
         true <- byte_size(String.trim_leading(s, "-")) <= Rt.max_int_digits() do
      {:ok, String.to_integer(s)}
    else
      _ -> :error
    end
  end

  defp parse("Uuid", part) do
    case decode(part) do
      {:ok, s} -> if Regex.match?(@uuid, s), do: {:ok, {:uuid, s}}, else: :error
      :error -> :error
    end
  end

  defp parse("String", part) do
    case decode(part) do
      {:ok, s} when s not in [".", ".."] -> {:ok, s}
      _ -> :error
    end
  end

  defp parse(_, _), do: :error

  defp decode(part) do
    s = URI.decode(part)

    if String.valid?(s) and not Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, part),
      do: {:ok, s},
      else: :error
  rescue
    ArgumentError -> :error
  end

  # ---------- path ----------

  defp build(%{segments: segs, params: params} = e, args) when length(params) == length(args) do
    check_params!(e)
    values = params |> Enum.zip(args) |> Map.new(fn {{n, t}, v} -> {n, {t, v}} end)

    segs
    |> Enum.reduce_while({:ok, []}, fn
      {:lit, s}, {:ok, acc} ->
        {:cont, {:ok, [encode(s) | acc]}}

      {:param, n}, {:ok, acc} ->
        case values do
          %{^n => {t, v}} -> param_segment(t, v, acc)
          _ -> {:halt, :error}
        end
    end)
    |> case do
      {:ok, []} -> {:ok, "/"}
      {:ok, rev} -> {:ok, "/" <> Enum.join(Enum.reverse(rev), "/")}
      :error -> :error
    end
  end

  defp build(_, _), do: :error

  # The checker guarantees a pattern's params are exactly its target init's.
  defp check_params!(%{segments: segs, params: params, app: app}) do
    names = for {:param, n} <- segs, do: n

    if Enum.sort(names) != Enum.sort(Enum.map(params, &elem(&1, 0))) do
      raise ArgumentError,
            "route to #{app}: pattern params #{inspect(names)} do not match " <>
              "init params #{inspect(Enum.map(params, &elem(&1, 0)))}"
    end
  end

  defp param_segment(type, v, acc) do
    case segment(type, v) do
      {:ok, s} -> {:cont, {:ok, [s | acc]}}
      :error -> {:halt, :error}
    end
  end

  defp segment("Int", n) when is_integer(n), do: {:ok, Integer.to_string(n)}

  defp segment("Uuid", {:uuid, u}) when is_binary(u) do
    if Regex.match?(@uuid, u), do: {:ok, u}, else: :error
  end

  defp segment("String", s) when is_binary(s) and s not in ["", ".", ".."] do
    if String.valid?(s), do: {:ok, encode(s)}, else: :error
  end

  defp segment(_, _), do: :error

  defp encode(s), do: URI.encode(s, &URI.char_unreserved?/1)
end
