defmodule Kinoko.Repl do
  @moduledoc """
  A tiny stateful helper for trying Yabu from `iex -S mix`. It keeps ONE
  session universe in a named Agent (started lazily on first use, deliberately
  outside the supervision tree: it is a dev convenience, and a crash just
  gives you a fresh session), so you never thread the universe by hand. The
  repo's `.iex.exs` aliases this module as `Y`.

  Everything prints readably and returns a useful value. `eval/2` and
  `call/3` print the value (or the error) as Yabu source; inside iex they
  return nothing iex would echo (the raw BEAM term would only repeat it,
  less readably), and `last/0` hands back the last value they computed. Outside iex (a
  script, a test) they return the value itself.

  ## Walkthrough

      iex> Y.load("test/fixtures/yabu/counter.yabu")
      promoted: counter
      :ok
      iex> Y.eval("Counter.init()")
      (%Counter.Model{count: 0}, Cmd.none()) : (Counter.Model, Cmd<Counter.Msg>)
      iex> Y.eval("Counter.update(Counter.Msg.Add(5), %Counter.Model{count: 1})")
      (%Counter.Model{count: 6}, Cmd.none()) : (Counter.Model, Cmd<Counter.Msg>)
      iex> {model, _cmd} = Y.last()
      {{:rec, "Counter.Model", %{"count" => 6}}, {:cmd, :none}}
      iex> Y.eval("Counter.view(%Counter.Model{count: 2})")
      <div class="counter">
        <button on-click={Counter.Msg.Decrement}>-</button>
        <span>2</span>
        ...
      </div> : Html<Counter.Msg>

  Stage something broken: it stays staged and says why, nothing is lost.

      iex> Y.load("def Counter.double(m : Counter.Model) : Int do Counter.twice(m.count) end", id: "double")
      staged: double
        Counter.double: [unbound] ...
      {:staged, [...]}

  Fix it by restaging the same id, and it promotes:

      iex> Y.load(~S'''
      ...> def Counter.twice(n : Int) : Int do n * 2 end
      ...> def Counter.double(m : Counter.Model) : Int do Counter.twice(m.count) end
      ...> ''', id: "double")
      promoted: double
      :ok
      iex> Y.eval("Counter.double(%Counter.Model{count: 21})")
      42 : Int

  A file that is not there is said so, and nothing is staged:

      iex> Y.load("test/fixtures/yabu/countr.yabu")
      no such file: test/fixtures/yabu/countr.yabu
      {:error, :enoent}

  Also: `call/2`, `last/0`, `test/1`, `symbols/0`, `read/1`, `unstage/1`,
  `history/0`, `u/0` (the universe, to hand to `Kinoko.Exec` /
  `Kinoko.Lang` directly) and `reset/0`.
  """

  alias Kinoko.{Exec, Lang}
  alias Kinoko.Lang.Format

  @agent __MODULE__.Session

  @doc """
  Stage `path_or_source`: a file when the argument names one, else source
  text. The patch id is the file's base name, `repl-N` for source, or
  `id:` if given (restage the same id to fix a staged patch). Returns `:ok`
  when it promoted, `{:staged, reasons}` otherwise.

  An argument that looks like a path (it ends in `.yabu`, or is one word
  with no space or newline) but names no file is not staged as source:
  it prints `no such file: <path>` (or says it is a directory) and returns
  `{:error, :enoent}` (`{:error, :eisdir}`).
  """
  @spec load(String.t(), keyword()) ::
          :ok | {:staged, [Lang.reason()]} | {:error, :enoent | :eisdir}
  def load(path_or_source, opts \\ []) when is_binary(path_or_source) do
    case source_of(path_or_source) do
      {:ok, source, default_id} -> stage(source, default_id, opts)
      {:error, why} -> {:error, why}
    end
  end

  defp source_of(arg) do
    cond do
      File.regular?(arg) ->
        {:ok, File.read!(arg), Path.basename(arg, ".yabu")}

      File.dir?(arg) ->
        IO.puts("#{arg} is a directory, not a .yabu file")
        {:error, :eisdir}

      path_like?(arg) ->
        IO.puts("no such file: #{arg}")
        {:error, :enoent}

      true ->
        {:ok, arg, nil}
    end
  end

  # No Yabu program is one word: a declaration starts with a keyword and a
  # space.
  defp path_like?(arg) do
    String.ends_with?(arg, ".yabu") or
      (arg != "" and not String.contains?(arg, [" ", "\n", "\t", "\r"]))
  end

  defp stage(source, default_id, opts) do
    Agent.get_and_update(
      session(),
      fn %{n: n} = s ->
        id = opts[:id] || default_id || "repl-#{n + 1}"
        {u, verdict} = Lang.stage(s.u, id, source)
        {{id, verdict}, %{s | u: u, n: if(default_id || opts[:id], do: n, else: n + 1)}}
      end,
      :infinity
    )
    |> report_verdict()
  end

  @doc """
  Evaluate an expression against the session; prints `value : type`. Inside
  iex returns nothing to echo (see `last/0`); elsewhere the value. An error
  is printed, and returned as `{:error, error}` outside iex.
  """
  @spec eval(String.t(), keyword()) :: term()
  def eval(source, opts \\ []) when is_binary(source) do
    case Exec.eval(Lang.snapshot(u()), source, opts) do
      {:ok, value, type} ->
        IO.puts("#{Exec.show(value, type)} : #{Format.type(type)}")
        remember(value)

      {:error, error} ->
        print_error(error)
        quiet({:error, error})
    end
  end

  @doc """
  Call a committed def with already-built values (BEAM terms, see
  `Kinoko.Lang.Rt`); prints the shown value and returns it as `eval/2` does.
  """
  @spec call(String.t(), [term()], keyword()) :: term()
  def call(name, args, opts \\ []) do
    case Exec.call(Lang.snapshot(u()), name, args, opts) do
      {:ok, value} ->
        IO.puts(show_untyped(name, value))
        remember(value)

      {:error, error} ->
        print_error(error)
        quiet({:error, error})
    end
  end

  @doc "The value the last successful `eval/2` or `call/3` computed (`nil` before any)."
  @spec last() :: term()
  def last, do: Agent.get(session(), & &1.last)

  defp remember(value) do
    Agent.update(session(), &%{&1 | last: value})
    quiet(value)
  end

  # Inside iex, nothing for it to echo: what was printed says it all.
  defp quiet(result), do: if(iex?(), do: IEx.dont_display_result(), else: result)

  defp iex?, do: Code.ensure_loaded?(IEx) and IEx.started?()

  @doc "Run a deftest; prints `ok` or its failures."
  @spec test(String.t(), keyword()) :: :ok | {:error, map()}
  def test(name, opts \\ []) do
    case Exec.test(Lang.snapshot(u()), name, opts) do
      :ok ->
        IO.puts("#{name}: ok")
        :ok

      {:error, %{failures: failures} = error} ->
        Enum.each(failures, &IO.puts("#{name}: FAILED #{&1}"))
        {:error, error}

      {:error, error} ->
        print_error(error)
        {:error, error}
    end
  end

  @doc "Prints the signature of every committed symbol."
  @spec symbols() :: :ok
  def symbols do
    Enum.each(Lang.symbols(u()), fn %{name: name, signature: sig} ->
      IO.puts(if String.starts_with?(sig, name), do: sig, else: "#{name} : #{sig}")
    end)
  end

  @doc "Prints the committed source of `name`; returns `:ok` or `:error`."
  @spec read(String.t()) :: :ok | :error
  def read(name) do
    case Lang.read(u(), name) do
      {:ok, text} ->
        IO.puts(text)
        :ok

      :error ->
        IO.puts("no committed symbol named #{name}")
        :error
    end
  end

  @doc """
  Drop a staged patch by id; prints what happened. `true`, `false` (nothing
  staged under `id`) or `{:error, reason}`.
  """
  @spec unstage(String.t()) :: boolean() | {:error, Lang.reason()}
  def unstage(id) do
    result =
      Agent.get_and_update(
        session(),
        fn s ->
          {u, result} = Lang.unstage(s.u, id)
          {result, %{s | u: u}}
        end,
        :infinity
      )

    case result do
      true -> IO.puts("unstaged: #{id}")
      false -> IO.puts("nothing staged under #{id}")
      {:error, reason} -> print_error(reason)
    end

    result
  end

  @doc "Every promoted round, oldest first."
  @spec history() :: [map()]
  def history, do: Lang.history(u())

  @doc "The session universe, for `Kinoko.Exec` / `Kinoko.Lang` directly."
  @spec u() :: Lang.Universe.t()
  def u, do: Agent.get(session(), & &1.u, :infinity)

  @doc "Start over with an empty universe."
  @spec reset() :: :ok
  def reset, do: Agent.update(session(), fn _ -> fresh() end)

  defp fresh, do: %{u: Lang.new(), n: 0, last: nil}

  defp session do
    case Agent.start(&fresh/0, name: @agent) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp report_verdict({_id, {:promoted, ids}}) do
    IO.puts("promoted: #{Enum.join(ids, ", ")}")
    :ok
  end

  defp report_verdict({id, {:staged, reasons} = verdict}) do
    IO.puts("staged: #{id}")
    Enum.each(reasons, &IO.puts("  #{&1.name || "-"}: [#{&1.code}] #{&1.message}"))
    verdict
  end

  # The reasons only when they say more than the message: the message is
  # the first reason's.
  defp print_error(%{code: code, message: message} = error) do
    IO.puts("error: [#{code}] #{message}")

    case Map.get(error, :reasons, []) do
      [] ->
        :ok

      [%{code: ^code, message: ^message}] ->
        :ok

      reasons ->
        for reason <- reasons,
            do: IO.puts("  #{Map.get(reason, :name) || "-"}: [#{reason.code}] #{reason.message}")
    end

    :ok
  end

  # `call/3` has no static type to hand to the printer; use the def's return type.
  defp show_untyped(name, value) do
    case Lang.signatures(u()) do
      %{^name => {:def, _params, ret}} -> "#{Exec.show(value, ret)} : #{Format.type(ret)}"
      _ -> Exec.show(value, nil)
    end
  rescue
    _ -> inspect(value)
  end
end
