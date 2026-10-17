defmodule Nobi.Exec do
  @moduledoc """
  Runs committed Nobi code on the BEAM (piece 4,
  `docs/superpowers/specs/2026-10-15-nobi-erlang-codegen-design.md`): loads
  a snapshot's image (one module per distinct committed code), calls its
  defs, evaluates expressions against it, runs its deftests and shows
  values as Nobi source.

      iex> alias Nobi.{Exec, Lang}
      iex> {u, {:promoted, _}} = Lang.stage(Lang.new(), "c", File.read!("test/fixtures/nobi/counter.nobi"))
      iex> snapshot = Lang.snapshot(u)
      iex> {:ok, {model, _cmd}, _type} = Exec.eval(snapshot, "Counter.update(Counter.Msg.Add(2), %Counter.Model{count: 1})")
      iex> Exec.show(model, {:named, "Counter.Model"})
      "%Counter.Model{count: 3}"

  ## Trying it from iex

  `iex -S mix` aliases `Nobi.Repl` as `Y` (see `.iex.exs`), which drives
  the current `Nobi.Universe` for you. Without it, take a snapshot yourself:

      iex> {u, {:promoted, _}} = Lang.stage(Lang.new(), "c", File.read!("test/fixtures/nobi/counter.nobi"))
      iex> snapshot = Lang.snapshot(u)
      iex> {:ok, {_model, _cmd}, _type} = Exec.eval(snapshot, "Counter.init()")
      iex> {:ok, {model, _cmd}, _} = Exec.eval(snapshot, "Counter.update(Counter.Msg.Add(5), %Counter.Model{count: 1})")
      iex> Exec.show(model, {:named, "Counter.Model"})
      "%Counter.Model{count: 6}"

  The REPL walkthrough (load counter, init, update with `Add(5)`, view, stage
  a broken def and read its reason, fix it, eval it) is in `Nobi.Repl`.

  ## Snapshots, not universes

  Exec takes `Nobi.Lang.snapshot/1` (the committed code plus the
  signatures to check against), or an image. It never takes a
  `Nobi.Lang.Universe`, and calls no `Nobi.Lang` function that does:
  `load/2`, `call/4`, `eval/3` and `test/3` have no clause for one. Hosts
  reach Exec through `Nobi.Universe`, which hands out snapshots.

  ## Images

  `load/2` compiles a snapshot's committed code (`Nobi.Lang.Codegen`, in
  a bounded worker) and loads it, keeping the image in `:persistent_term`
  under its hash: two snapshots with the same code share one module,
  loaded once. The module stays loaded after a promotion, so an image
  keeps answering with the code it was made from until `unload/1` purges
  it. (Putting a new key in `:persistent_term` costs no global GC pass;
  erasing one, as `unload/1` does, makes every process that may reference
  the term copy it on its next GC: a global GC pass, paid per unload.)

  Images are never evicted automatically. Each distinct image ever loaded
  keeps one atom (its module name, which is never freed), one loaded
  module and one `:persistent_term` entry until `unload/1`. Whoever loads
  images in bulk (a long-lived host stepping many versions) owns calling
  `unload/1` for the ones no longer needed.

  `unload/1` is global: the image is shared by every snapshot with the
  same code, so unloading it stops every worker running it, other
  callers' included. Those callers get `{:error, %{code: "unloaded"}}`;
  their next `load/2` loads it again.

  ## Hosting Nobi values (the contract for hosts)

  A host that keeps Nobi running (piece 2's app runtime, stepping an app
  across many messages) must:

  - **hold the image, not the snapshot.** `call/4`, `eval/3` and `test/3`
    take a snapshot too, but each such call re-hashes its committed code to
    find the image (`Nobi.Lang.Codegen.image_hash/1`): cheap once, waste
    per message. `load/2` once, then call with the image.
  - **invoke every Nobi value only through `Nobi.Exec.Worker.run/2`.** A
    closure, a callback carried in a Cmd effect, a def taken as a value:
    any of them may loop, allocate without bound or throw a Nobi error.
    Applied in the host's own process, none of that is bounded or caught.
    `call/4` runs a def by name in a worker; for a value in hand, wrap the
    application: `Worker.run(fn -> f.(arg) end, opts)`.
  - **unload only what no live value needs.** A closure (and a def taken as
    a value) points into its image's module: once `unload/1` purges it,
    calling the closure raises (`:undef` for a def, `:badfun` for a
    closure), which `Worker.run/2` answers as code `"internal"`. Keep the
    image loaded while any of its values may still be called.

  ## Runs

  Every call, evaluation and test runs in a fresh worker process
  (`Nobi.Exec.Worker`), bounded by `:timeout` (ms, default 5_000) and
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

  alias Nobi.Exec.{Hooks, Show, Worker}
  alias Nobi.Lang
  alias Nobi.Lang.Codegen

  @compile_timeout 30_000

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
  The snapshot's image (or a bare committed map's), loaded: `{:ok, image}` (see `t:image/0` and
  `Nobi.Lang.image/1`), or the codegen's `{:error, %{code, message}}`.
  The image is cached by hash; its module is loaded only when it is not.

  Compiling runs in a worker (`Nobi.Exec.Worker`), bounded by
  `:compile_timeout` (ms, default #{@compile_timeout}) and `:max_heap_size`:
  past them the answer is code `"timeout"` or `"heap"`. Only installing the
  compiled module holds the image's lock, so two callers compiling the
  same new code each compile it, and the first to install it wins.
  """
  @spec load(Lang.snapshot() | map(), keyword()) :: {:ok, image} | {:error, error}
  def load(snapshot_or_committed, opts \\ [])

  def load(%{committed: committed} = snapshot, opts) when not is_struct(snapshot),
    do: load_committed(committed, opts)

  def load(committed, opts) when is_map(committed) and not is_struct(committed),
    do: load_committed(committed, opts)

  defp load_committed(committed, opts) do
    hash = Codegen.image_hash(committed)

    case :persistent_term.get(key(hash), nil) do
      nil ->
        with {:ok, image} <- compile(committed, opts),
             do: locked(hash, fn -> install(image) end)

      image ->
        ensure_loaded(image)
    end
  end

  defp key(hash), do: {__MODULE__, :image, hash}

  @doc """
  The image `load/2` loaded under `hash` (`Nobi.Lang.image_hash/1`),
  loaded again if purged since: `{:ok, image}`, or `:error` when no image
  of that hash is loaded (or it was `unload/1`ed). Compiles nothing: a host
  that knows its code's hash asks here first and builds a snapshot only on
  `:error`.
  """
  @spec loaded(String.t()) :: {:ok, image} | :error
  def loaded(hash) when is_binary(hash) do
    case :persistent_term.get(key(hash), nil) do
      nil ->
        :error

      image ->
        case ensure_loaded(image) do
          {:ok, image} -> {:ok, image}
          {:error, _} -> :error
        end
    end
  end

  # `f` under the image's lock, which `load/2` and `unload/1` share: a
  # module is never loaded while another caller purges it.
  # (The lock's requester is the caller: `:global` lets one requester hold
  # a resource's lock from several processes at once.)
  defp locked(hash, f), do: :global.trans({{__MODULE__, hash}, self()}, f, [node()])

  defp compile(committed, opts) do
    timeout = Keyword.get(opts, :compile_timeout, @compile_timeout)

    worker_opts =
      opts
      |> Keyword.take([:max_heap_size])
      |> Keyword.merge(timeout: timeout, max_result: :infinity)

    case Worker.run(fn -> Codegen.compile(committed) end, worker_opts) do
      {:ok, compiled} ->
        compiled

      {:error, %{code: "timeout"} = error} ->
        {:error, %{error | message: "compiling the image took more than #{timeout} ms"}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp install(%{hash: hash} = image) do
    # Another caller may have installed it while this one compiled.
    case :persistent_term.get(key(hash), nil) do
      nil ->
        with {:ok, image} <- load_module(image) do
          :persistent_term.put(key(hash), image)
          {:ok, image}
        end

      cached ->
        load_module(cached)
    end
  end

  defp ensure_loaded(%{module: module, hash: hash} = image) do
    if :code.is_loaded(module), do: {:ok, image}, else: locked(hash, fn -> load_module(image) end)
  end

  # Under the lock.
  defp load_module(%{module: module, binary: binary} = image) do
    if :code.is_loaded(module) do
      {:ok, image}
    else
      case :code.load_binary(module, ~c"nobi_image", binary) do
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
  not it was loaded. Holds the image's lock, as `load/2` does.
  """
  @spec unload(image) :: :ok
  def unload(%{module: module, hash: hash}) do
    locked(hash, fn -> purge(module, hash) end)
  end

  defp purge(module, hash) do
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
  The def `name` of `snapshot_or_image` applied to `args` (BEAM values, see
  `Nobi.Lang.Rt`): `{:ok, value}` or `{:error, %{code, message}}`. Only
  the image's own defs are called by name, as in Rust's `call`.
  """
  @spec call(Lang.snapshot() | image, String.t(), [term()], keyword()) ::
          {:ok, term()} | {:error, error}
  def call(snapshot_or_image, name, args, opts \\ []) when is_binary(name) and is_list(args) do
    with {:ok, image} <- image(snapshot_or_image, opts) do
      case image.names do
        %{^name => {f, arity}} when arity == length(args) ->
          run(image, fn -> apply(image.module, f, args) end, opts)

        %{^name => {_, arity}} ->
          runtime("`#{name}` takes #{arity} argument(s), got #{length(args)}")

        _ ->
          runtime("no def named `#{name}`")
      end
    end
  end

  # `fun` in a worker. A worker that started after `unload/1` looked for
  # the image's workers finds the module gone: unloaded too, not internal.
  defp run(image, fun, opts) do
    case Worker.run(fun, opts) do
      {:error, %{code: "internal"}} = error ->
        if :code.is_loaded(image.module), do: error, else: Worker.unloaded_error()

      result ->
        result
    end
  end

  @doc """
  `fun` (a Nobi function value: a closure, a def taken as a value, a
  constructor) applied to `args` in a worker, bounded as `call/4` is:
  `{:ok, value}` or `{:error, %{code, message}}`. `snapshot_or_image` is
  the code the value is run against (its image is loaded first). A value
  that is no function, or takes another number of arguments, is code
  `"runtime"`; a closure whose image was unloaded (`unload/1`) is code
  `"unloaded"`, before or while it runs.
  """
  @spec apply(
          Lang.snapshot() | image | %{image: image, signatures: map()},
          term(),
          [term()],
          keyword()
        ) ::
          {:ok, term()} | {:error, error}
  def apply(snapshot_or_image, fun, args, opts) when is_list(args) do
    with :ok <- applicable(fun, args),
         {:ok, image} <- image(snapshot_or_image, opts),
         :ok <- fun_loaded(fun) do
      case run(image, fn -> Kernel.apply(fun, args) end, opts) do
        {:error, %{code: "internal"}} = error ->
          if fun_loaded(fun) == :ok, do: error, else: Worker.unloaded_error()

        result ->
          result
      end
    end
  end

  defp applicable(fun, args) when is_function(fun, length(args)), do: :ok

  defp applicable(fun, args) when is_function(fun) do
    {:arity, arity} = Function.info(fun, :arity)
    runtime("the function takes #{arity} argument(s), got #{length(args)}")
  end

  defp applicable(value, _args), do: runtime("#{inspect(value, limit: 5)} is not a function")

  # A closure points into the module that made it: an image's, which
  # `unload/1` may have purged, or the runtime's (`:erl_eval`, `Nobi.Lang.Rt`).
  defp fun_loaded(fun) do
    {:module, module} = Function.info(fun, :module)
    if :code.is_loaded(module), do: :ok, else: Worker.unloaded_error()
  end

  @doc """
  The image's route tables (`__nobi__(:routes)`, see `Nobi.Lang.Codegen`):
  `{:ok, %{routes_name => [%{segments, app, params}]}}` (empty when the code
  declares none), or `{:error, %{code, message}}` (the image does not load,
  or was unloaded meanwhile: `"unloaded"`).
  """
  @spec routes(Lang.snapshot() | image | %{image: image, signatures: map()}, keyword()) ::
          {:ok, map()} | {:error, error}
  def routes(snapshot_or_image, opts \\ []) do
    with {:ok, image} <- image(snapshot_or_image, opts) do
      try do
        {:ok, image.module.__nobi__(:routes)}
      rescue
        UndefinedFunctionError -> Worker.unloaded_error()
      end
    end
  end

  defp image(%{module: _, binary: _} = image, _opts), do: ensure_loaded(image)
  defp image(%{image: image, signatures: _}, _opts), do: ensure_loaded(image)

  defp image(snapshot, opts) when is_map_key(snapshot, :committed) and not is_struct(snapshot),
    do: load(snapshot, opts)

  defp runtime(message), do: {:error, %{code: "runtime", message: message}}

  @doc """
  The expression `source`, checked against the snapshot's signatures and
  evaluated with it: `{:ok, value, type}` or `{:error, %{code, message}}`.
  In place of a snapshot, `%{image: image, signatures: sigs}` (a loaded
  image and the signatures of the code it was made from) evaluates without
  the committed code.
  An expression that does not parse or check is refused with its first
  reason's code and message (`reasons:` holds them all) before anything
  runs. `always` and `sometimes` in it are evaluated, never scored.
  """
  @spec eval(Lang.snapshot() | %{image: image, signatures: map()}, String.t(), keyword()) ::
          {:ok, term(), term()} | {:error, error}
  def eval(target, source, opts \\ [])
      when (is_map_key(target, :committed) or is_map_key(target, :image)) and
             not is_struct(target) and is_binary(source) do
    case Lang.check_expr(target, source) do
      {:ok, typed, type} ->
        with {:ok, image} <- image(target, opts),
             {:ok, forms} <- expr_forms(typed, image),
             {:ok, value} <- run(image, fn -> erl_eval(forms) end, opts) do
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
  catch
    :throw, {:codegen_limit, message} -> {:error, %{code: "compile", message: message}}
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

  At most #{Hooks.max_failures()} failed `always`s are listed; past that
  the last entry is `"…and K more"` (K the failures not listed). `message`
  is the failures joined by newlines. A name that is no test is
  `{:error, %{code: "runtime", message: "no test named `X`"}}`; a test
  that hits a limit is the worker's `"timeout"` or `"heap"` error, with no
  failures (they died with the worker).
  """
  @spec test(Lang.snapshot() | image, String.t(), keyword()) :: :ok | {:error, error}
  def test(snapshot_or_image, name, opts \\ []) when is_binary(name) do
    with {:ok, image} <- image(snapshot_or_image, opts) do
      case image.tests do
        %{^name => f} -> score(image, name, run_test(image, f, opts))
        _ -> runtime("no test named `#{name}`")
      end
    end
  end

  defp run_test(image, f, opts) do
    module = image.module

    run(
      image,
      fn ->
        outcome =
          try do
            apply(module, f, [])
            :ok
          catch
            :throw, {:nobi_error, message} -> {:crashed, message}
          end

        {Hooks.take_failures(), Hooks.take_reached(), outcome}
      end,
      # Weighed as any answer: the failures are capped (`Nobi.Exec.Hooks`)
      # and the sites are the program's own.
      opts
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
  `value` as Nobi source (`Nobi.Exec.Show`): what `eval/3` reads back as
  `value`, where source can write it.
  """
  @spec show(term(), term()) :: String.t()
  defdelegate show(value, type), to: Show
end
