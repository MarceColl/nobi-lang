defmodule Kinoko.Exec do
  @moduledoc """
  Runs committed Yabu code on the BEAM (piece 4,
  `docs/superpowers/specs/2026-10-15-yabu-erlang-codegen-design.md`): loads
  a universe's image (one module per distinct committed code), calls its
  defs, evaluates expressions against it, runs its deftests and shows
  values as Yabu source.

      iex> alias Kinoko.{Exec, Lang}
      iex> {u, {:promoted, _}} = Lang.stage(Lang.new(), "c", File.read!("test/fixtures/yabu/counter.yabu"))
      iex> {:ok, {model, _cmd}, _type} = Exec.eval(u, "Counter.update(Counter.Msg.Add(2), %Counter.Model{count: 1})")
      iex> Exec.show(model, {:named, "Counter.Model"})
      "%Counter.Model{count: 3}"

  ## Trying it from iex

  `iex -S mix` aliases `Kinoko.Repl` as `Y` (see `.iex.exs`), which keeps
  the session universe for you. Without it, thread the universe yourself:

      iex> {u, {:promoted, _}} = Lang.stage(Lang.new(), "c", File.read!("test/fixtures/yabu/counter.yabu"))
      iex> {:ok, {_model, _cmd}, _type} = Exec.eval(u, "Counter.init()")
      iex> {:ok, {model, _cmd}, _} = Exec.eval(u, "Counter.update(Counter.Msg.Add(5), %Counter.Model{count: 1})")
      iex> Exec.show(model, {:named, "Counter.Model"})
      "%Counter.Model{count: 6}"

  The REPL walkthrough (load counter, init, update with `Add(5)`, view, stage
  a broken def and read its reason, fix it, eval it) is in `Kinoko.Repl`.

  ## Images

  `load/1` compiles a universe's committed code (`Kinoko.Lang.Codegen`) and
  loads it, keeping the image in `:persistent_term` under its hash: two
  universes with the same code share one module, loaded once. The module
  stays loaded after a promotion, so an image keeps answering with the
  code it was made from until `unload/1` purges it. (Each new image is one
  `:persistent_term` write, which costs a global GC pass; that is paid once
  per distinct code.)

  Images are never evicted automatically. Each distinct image ever loaded
  keeps one atom (its module name, which is never freed), one loaded
  module and one `:persistent_term` entry until `unload/1`. Whoever loads
  images in bulk (a long-lived host stepping many versions) owns calling
  `unload/1` for the ones no longer needed.

  `unload/1` is global: the image is shared by every universe with the
  same code, so unloading it stops every worker running it, other
  callers' included. Those callers get `{:error, %{code: "unloaded"}}`;
  their next `load/1` loads it again.

  ## Runs

  Every call, evaluation and test runs in a fresh worker process
  (`Kinoko.Exec.Worker`), bounded by `:timeout` (ms, default 5_000) and
  `:max_heap_size` (words, default 1 GB's worth); both are options of
  `call/4`, `eval/3` and `test/3`. Errors are
  `%{code: code, message: message}`, with code:

  - `"runtime"`: the program's error, worded as Rust's `EvalError`
    (`"division by zero"`, `"integer overflow"`, `"no case arm matched"`,
    `"result too large"`, `"evaluation took more than 1000000 steps"` (a
    comparison or map key too large to walk), `"no def named `X`"`, …);
  - `"timeout"`, `"heap"`: the worker hit a limit and was killed;
  - `"unloaded"`: `unload/1` stopped the worker;
  - `"compile"`, `"internal"`: a fault of the codegen or the runtime;
  - for `eval/3`, `"parse"` or a checker code (`"unbound"`, `"mismatch"`,
    …) when the expression does not check; nothing is run then.
  """

  alias Kinoko.Exec.{Hooks, Show, Worker}
  alias Kinoko.Lang
  alias Kinoko.Lang.Codegen

  @type image :: %{
          module: atom(),
          binary: binary(),
          hash: String.t(),
          names: %{String.t() => {atom(), non_neg_integer()}},
          tests: %{String.t() => atom()},
          sometimes: %{String.t() => [String.t()]}
        }
  @type error :: %{
          required(:code) => String.t(),
          required(:message) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  The universe's image, loaded: `{:ok, image}` (see `t:image/0` and
  `Kinoko.Lang.image/1`), or the codegen's `{:error, %{code, message}}`.
  The image is cached by hash; its module is loaded only when it is not.
  """
  @spec load(Lang.Universe.t()) :: {:ok, image} | {:error, error}
  def load(u) do
    committed = Lang.committed(u)
    hash = Codegen.image_hash(committed)

    case :persistent_term.get(key(hash), nil) do
      nil ->
        :global.trans({__MODULE__, hash}, fn -> compile_and_load(hash, committed) end, [node()])

      image ->
        ensure_loaded(image)
    end
  end

  defp key(hash), do: {__MODULE__, :image, hash}

  defp compile_and_load(hash, committed) do
    # Another caller may have loaded it while this one waited for the lock.
    case :persistent_term.get(key(hash), nil) do
      nil ->
        with {:ok, image} <- Codegen.compile(committed),
             {:ok, image} <- ensure_loaded(image) do
          :persistent_term.put(key(hash), image)
          {:ok, image}
        end

      image ->
        ensure_loaded(image)
    end
  end

  defp ensure_loaded(%{module: module, binary: binary} = image) do
    if :code.is_loaded(module) do
      {:ok, image}
    else
      case :code.load_binary(module, ~c"yabu_image", binary) do
        {:module, ^module} ->
          {:ok, image}

        {:error, why} ->
          {:error, %{code: "internal", message: "loading the image failed: #{inspect(why)}"}}
      end
    end
  end

  @doc """
  Purges the image's module and forgets it. Every worker running its code
  (anyone's) is stopped and its caller answers code `"unloaded"`; any
  other process still running it is killed by the purge. `:ok` whether or
  not it was loaded.
  """
  @spec unload(image) :: :ok
  def unload(%{module: module, hash: hash}) do
    :persistent_term.erase(key(hash))
    # Its current code becomes old code, which `check_process_code` finds.
    :code.purge(module)
    :code.delete(module)

    stopping =
      for pid <- Process.list(),
          pid != self(),
          :erlang.check_process_code(pid, module) do
        monitor = Process.monitor(pid)
        Process.exit(pid, Worker.unloaded_reason())
        monitor
      end

    # Each stopped before the purge would kill it under another reason.
    for monitor <- stopping do
      receive do
        {:DOWN, ^monitor, :process, _, _} -> :ok
      after
        100 -> Process.demonitor(monitor, [:flush])
      end
    end

    :code.purge(module)
    :ok
  end

  @doc """
  The def `name` of `u_or_image` applied to `args` (BEAM values, see
  `Kinoko.Lang.Rt`): `{:ok, value}` or `{:error, %{code, message}}`. Only
  the image's own defs are called by name, as in Rust's `call`.
  """
  @spec call(Lang.Universe.t() | image, String.t(), [term()], keyword()) ::
          {:ok, term()} | {:error, error}
  def call(u_or_image, name, args, opts \\ []) when is_binary(name) and is_list(args) do
    with {:ok, image} <- image(u_or_image) do
      case image.names do
        %{^name => {f, arity}} when arity == length(args) ->
          Worker.run(fn -> apply(image.module, f, args) end, opts)

        %{^name => {_, arity}} ->
          runtime("`#{name}` takes #{arity} argument(s), got #{length(args)}")

        _ ->
          runtime("no def named `#{name}`")
      end
    end
  end

  defp image(%{module: _, binary: _} = image), do: ensure_loaded(image)
  defp image(u), do: load(u)

  defp runtime(message), do: {:error, %{code: "runtime", message: message}}

  @doc """
  The expression `source`, checked against `u`'s committed code and
  evaluated with it: `{:ok, value, type}` or `{:error, %{code, message}}`.
  An expression that does not parse or check is refused with its first
  reason's code and message (`reasons:` holds them all) before anything
  runs. `always` and `sometimes` in it are evaluated, never scored.
  """
  @spec eval(Lang.Universe.t(), String.t(), keyword()) :: {:ok, term(), term()} | {:error, error}
  def eval(u, source, opts \\ []) when is_binary(source) do
    case Lang.check_expr(u, source) do
      {:ok, typed, type} ->
        with {:ok, image} <- load(u),
             {:ok, forms} <- expr_forms(typed, image),
             {:ok, value} <- Worker.run(fn -> erl_eval(forms) end, opts) do
          {:ok, value, type}
        end

      {:error, [first | _] = reasons} ->
        {:error, %{code: first.code, message: first.message, reasons: reasons}}
    end
  end

  defp expr_forms(typed, image) do
    {:ok, Codegen.expr_forms(typed, image.names, image.module)}
  rescue
    e -> {:error, %{code: "internal", message: Exception.message(e)}}
  end

  defp erl_eval(forms) do
    {:value, value, _bindings} = :erl_eval.exprs(forms, :erl_eval.new_bindings())
    value
  end

  @doc """
  Runs the deftest `name`, scored as Rust's `run_test` scores it: `:ok`
  when it passes, else
  `{:error, %{code: "test", message: lines, failures: [String.t()]}}`,
  the failures in Rust's order:

  1. `"always failed: <source>"` for each `always` that evaluated false,
     in the test or anything it called, in the order evaluated;
  2. `"crashed: <message>"` when the test threw a runtime error (which
     ends it);
  3. `"never reached: <source>"` for each `sometimes` written in the test
     that never held, in the order written.

  `message` is the failures joined by newlines. A name that is no test is
  `{:error, %{code: "runtime", message: "no test named `X`"}}`; a test
  that hits a limit is the worker's `"timeout"` or `"heap"` error, with no
  failures (they died with the worker).
  """
  @spec test(Lang.Universe.t() | image, String.t(), keyword()) :: :ok | {:error, error}
  def test(u_or_image, name, opts \\ []) when is_binary(name) do
    with {:ok, image} <- image(u_or_image) do
      case image.tests do
        %{^name => f} -> score(image, name, run_test(image.module, f, opts))
        _ -> runtime("no test named `#{name}`")
      end
    end
  end

  defp run_test(module, f, opts) do
    Worker.run(
      fn ->
        outcome =
          try do
            apply(module, f, [])
            :ok
          catch
            :throw, {:yabu_error, message} -> {:crashed, message}
          end

        {Hooks.take_failures(), Hooks.take_reached(), outcome}
      end,
      Keyword.put(opts, :max_result, :infinity)
    )
  end

  defp score(image, name, {:ok, {failed, reached, outcome}}) do
    crashed = with {:crashed, m} <- outcome, do: ["crashed: " <> m], else: (_ -> [])

    never =
      for source <- Map.get(image.sometimes, name, []),
          not MapSet.member?(reached, {name, source}),
          do: "never reached: " <> source

    case failed ++ crashed ++ never do
      [] ->
        :ok

      failures ->
        {:error, %{code: "test", message: Enum.join(failures, "\n"), failures: failures}}
    end
  end

  defp score(_image, _name, {:error, _} = error), do: error

  @doc """
  `value` as Yabu source (`Kinoko.Exec.Show`): what `eval/3` reads back as
  `value`, where source can write it.
  """
  @spec show(term(), term()) :: String.t()
  defdelegate show(value, type), to: Show
end
