defmodule Nobi.Repl do
  @moduledoc """
  A tiny helper for trying Nobi from `iex -S mix`. Every call goes through
  `Nobi.Universe`, against the session's CURRENT universe: `"main"` until
  you `use/1` another (kept in the shell process's dictionary, so each iex
  session has its own), so you never thread the universe by hand. The state
  lives in the universe, not here: it survives a restart of the shell or of
  the universe's process. The repo's `.iex.exs` aliases this module as `Y`.

  To start from nothing, create a fresh universe and switch to it
  (there is no reset; `main` is the shared one):

      iex> Y.create("scratch")
      created: scratch
      :ok
      iex> Y.use("scratch")
      using: scratch
      :ok
      iex> Y.universes()
      main
      scratch (current)

  Everything prints readably and returns a useful value. `eval/2` and
  `call/3` print the value (or the error) as Nobi source; inside iex they
  return nothing iex would echo (the raw BEAM term would only repeat it,
  less readably), and `last/0` hands back the last value they computed. Outside iex (a
  script, a test) they return the value itself.

  ## Walkthrough

      iex> Y.load("test/fixtures/nobi/counter.nobi")
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

      iex> Y.load("test/fixtures/nobi/countr.nobi")
      no such file: test/fixtures/nobi/countr.nobi
      {:error, :enoent}

  Also: `call/2`, `last/0`, `test/1`, `symbols/0`, `read/1`, `unstage/1`,
  `history/0`, `current/0`, `use/1`, `universes/0` and `create/1`.
  """

  alias Nobi.{Exec, Universe}
  alias Nobi.Lang.Format

  @current_key {__MODULE__, :universe}
  @last_key {__MODULE__, :last}
  @default "main"

  @doc "The name of the session's current universe (`\"main\"` by default)."
  @spec current() :: String.t()
  def current, do: Process.get(@current_key, @default)

  @doc """
  Switch the session to universe `name`. An unknown name prints an error
  and changes nothing.
  """
  @spec use(String.t()) :: :ok | {:error, :no_such_universe | :bad_name}
  def use(name) do
    cond do
      not is_binary(name) ->
        print_error(:bad_name, name)

      name in Enum.map(Universe.list(), & &1.name) ->
        Process.put(@current_key, name)
        IO.puts("using: #{name}")
        :ok

      true ->
        print_error(:no_such_universe, name)
    end
  end

  @doc "Prints every universe, marking the current one."
  @spec universes() :: :ok
  def universes do
    case Universe.list() do
      {:error, error} ->
        fail(error)

      universes ->
        for %{name: name} <- universes,
            do: IO.puts(if(name == current(), do: "#{name} (current)", else: name))

        :ok
    end
  end

  @doc "Create an empty universe (it does not switch to it: `use/1`)."
  @spec create(String.t()) :: :ok | {:error, :exists | :bad_name}
  def create(name) do
    case Universe.create(name) do
      :ok ->
        IO.puts("created: #{name}")
        :ok

      {:error, :exists} ->
        IO.puts("error: universe #{name} already exists")
        {:error, :exists}

      {:error, :bad_name} ->
        print_error(:bad_name, name)

      {:error, error} ->
        fail(error)
    end
  end

  @doc """
  Prints whether the current universe is healthy or degraded (its committed
  code no longer typechecks; see `Nobi.Universe.health/1`), and returns
  `:ok | {:degraded, reasons}`.
  """
  @spec health() :: :ok | {:degraded, [map()]} | {:error, term()}
  def health do
    case Universe.health(current()) do
      :ok ->
        IO.puts("ok: #{current()} is healthy")
        :ok

      {:degraded, reasons} = degraded ->
        IO.puts("degraded: #{current()}'s committed code no longer typechecks")
        print_reasons(reasons)
        IO.puts("stage a patch that fixes these; eval, call and test resume once it promotes")
        degraded

      {:error, error} ->
        fail(error)
    end
  end

  @doc """
  Stage `path_or_source`: a file when the argument names one, else source
  text. The patch id is the file's base name, `repl-N` for source, or
  `id:` if given (restage the same id to fix a staged patch). Returns `:ok`
  when it promoted, `{:staged, reasons}` otherwise.

  An argument that looks like a path (it ends in `.nobi`, or is one word
  with no space or newline) but names no file is not staged as source:
  it prints `no such file: <path>` (or says it is a directory) and returns
  `{:error, :enoent}` (`{:error, :eisdir}`).
  """
  @spec load(String.t(), keyword()) ::
          :ok | {:staged, [Universe.reason()]} | {:error, :enoent | :eisdir}
  def load(path_or_source, opts \\ []) when is_binary(path_or_source) do
    case source_of(path_or_source) do
      {:ok, source, default_id} -> stage(source, default_id, opts)
      {:error, why} -> {:error, why}
    end
  end

  defp source_of(arg) do
    cond do
      File.regular?(arg) ->
        {:ok, File.read!(arg), Path.basename(arg, ".nobi")}

      File.dir?(arg) ->
        IO.puts("#{arg} is a directory, not a .nobi file")
        {:error, :eisdir}

      path_like?(arg) ->
        IO.puts("no such file: #{arg}")
        {:error, :enoent}

      true ->
        {:ok, arg, nil}
    end
  end

  # No Nobi program is one word: a declaration starts with a keyword and a
  # space.
  defp path_like?(arg) do
    String.ends_with?(arg, ".nobi") or
      (arg != "" and not String.contains?(arg, [" ", "\n", "\t", "\r"]))
  end

  defp stage(source, default_id, opts) do
    u = current()
    id = opts[:id] || default_id || next_id(u)

    case Universe.stage(u, id, source) do
      {:error, error} -> fail(error, u)
      verdict -> report_verdict(id, verdict)
    end
  end

  # `repl-N`, N one past the highest the universe has seen (promoted or staged).
  defp next_id(u) do
    seen =
      for list <- [Universe.history(u) |> ids_of(:ids), Universe.staged(u) |> ids_of(:id)],
          id <- list,
          {n, ""} <- [repl_number(id)],
          do: n

    "repl-#{Enum.max([0 | seen]) + 1}"
  end

  defp ids_of(entries, key) when is_list(entries),
    do: Enum.flat_map(entries, &List.wrap(Map.fetch!(&1, key)))

  defp ids_of(_error, _key), do: []

  defp repl_number("repl-" <> n), do: Integer.parse(n)
  defp repl_number(_), do: :error

  @doc """
  Evaluate an expression against the session; prints `value : type`. Inside
  iex returns nothing to echo (see `last/0`); elsewhere the value. An error
  is printed, and returned as `{:error, error}` outside iex.
  """
  @spec eval(String.t(), keyword()) :: term()
  def eval(source, opts \\ []) when is_binary(source) do
    case Universe.eval(current(), source, opts) do
      {:ok, value, type} ->
        IO.puts("#{Exec.show(value, type)} : #{Format.type(type)}")
        remember(value)

      {:error, error} ->
        fail(error)
    end
  end

  @doc """
  Call a committed def with already-built values (BEAM terms, see
  `Nobi.Lang.Rt`); prints the shown value and returns it as `eval/2` does.
  """
  @spec call(String.t(), [term()], keyword()) :: term()
  def call(name, args, opts \\ []) do
    case Universe.call(current(), name, args, opts) do
      {:ok, value, type} ->
        IO.puts("#{Exec.show(value, type)} : #{Format.type(type)}")
        remember(value)

      {:error, error} ->
        fail(error)
    end
  end

  @doc "The value the last successful `eval/2` or `call/3` computed (`nil` before any)."
  @spec last() :: term()
  def last, do: Process.get(@last_key)

  defp remember(value) do
    Process.put(@last_key, value)
    quiet(value)
  end

  # Inside iex, nothing for it to echo: what was printed says it all.
  defp quiet(result), do: if(iex?(), do: IEx.dont_display_result(), else: result)

  defp iex?, do: Code.ensure_loaded?(IEx) and IEx.started?()

  @doc "Run a deftest; prints `ok` or its failures."
  @spec test(String.t(), keyword()) :: :ok | {:error, map()}
  def test(name, opts \\ []) do
    case Universe.test(current(), name, opts) do
      :ok ->
        IO.puts("#{name}: ok")
        :ok

      {:error, %{failures: failures} = error} ->
        Enum.each(failures, &IO.puts("#{name}: FAILED #{&1}"))
        {:error, error}

      {:error, error} ->
        fail(error)
    end
  end

  @doc "Prints the signature of every committed symbol."
  @spec symbols() :: :ok
  def symbols do
    case Universe.symbols(current()) do
      {:error, error} ->
        fail(error)

      symbols ->
        Enum.each(symbols, fn %{symbol: name, signature: sig} ->
          IO.puts(if String.starts_with?(sig, name), do: sig, else: "#{name} : #{sig}")
        end)
    end
  end

  @doc "Prints the committed source of `name`; returns `:ok` or `:error`."
  @spec read(String.t()) :: :ok | :error
  def read(name) do
    case Universe.read(current(), name) do
      {:ok, text} ->
        IO.puts(text)
        :ok

      :error ->
        IO.puts("no committed symbol named #{name}")
        :error

      {:error, error} ->
        fail(error)
    end
  end

  @doc """
  Drop a staged patch by id; prints what happened. `:ok`, `:not_found`
  (nothing staged under `id`) or `{:error, reason}`.
  """
  @spec unstage(String.t()) :: :ok | :not_found | {:error, term()}
  def unstage(id) do
    case Universe.unstage(current(), id) do
      :ok ->
        IO.puts("unstaged: #{id}")
        :ok

      :not_found ->
        IO.puts("nothing staged under #{id}")
        :not_found

      {:error, error} ->
        fail(error)
    end
  end

  @doc "Every promoted round, oldest first."
  @spec history() :: [map()] | {:error, term()}
  def history do
    case Universe.history(current()) do
      {:error, error} -> fail(error)
      rounds -> rounds
    end
  end

  defp report_verdict(_id, {:promoted, ids}) do
    IO.puts("promoted: #{Enum.join(ids, ", ")}")
    :ok
  end

  defp report_verdict(id, {:staged, reasons} = verdict) do
    IO.puts("staged: #{id}")
    print_reasons(reasons)
    verdict
  end

  # Each reason said once: a check can find the same fault twice (say, two
  # branches updating the same missing field).
  defp print_reasons(reasons) do
    reasons
    |> Enum.uniq_by(&{Map.get(&1, :name), &1.code, &1.message})
    |> Enum.each(&IO.puts("  #{Map.get(&1, :name) || "-"}: [#{&1.code}] #{&1.message}"))
  end

  defp fail(error, universe \\ nil)

  defp fail(error, universe) when is_atom(error),
    do: quiet(print_error(error, universe || current()))

  defp fail(error, _universe) do
    print_error(error)
    quiet({:error, error})
  end

  defp print_error(:no_such_universe, name) do
    IO.puts("error: no such universe: #{name}")
    {:error, :no_such_universe}
  end

  defp print_error(:bad_name, name) do
    IO.puts("error: bad universe name: #{inspect(name)}")
    {:error, :bad_name}
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
        print_reasons(reasons)
    end

    :ok
  end
end
