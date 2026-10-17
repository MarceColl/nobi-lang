defmodule Nobi.Deployment.Effects do
  @moduledoc """
  How a deployment runs an app's `Cmd`: the one interpreter both hosts
  share. `NobiWeb.DeploymentLive` lowers each effect to a LiveView effect
  (a task, a timer, a patch); `Nobi.Deployment.Runner` (the MCP `send`
  tool) performs them in the caller, one after another. Either way the
  Cmd is read by `flatten/1` and a store operation runs through
  `run_store/5`, so the two can never disagree on what an effect does.

  `flatten/1` turns a `{:cmd, cmd}` value (`Nobi.Lang.Rt`) into its
  effects, in order (a batch's in its order):

    * `{:now, cb}`: `Cmd.time.now(cb)`, `cb` applied to Unix milliseconds;
    * `{:random, lo, hi, cb}`: `Cmd.random.int(lo, hi, cb)`, `lo ≤ hi`;
    * `{:navigate, app, args}`: `Cmd.navigate(App, args…)`; `path/3` gives
      its URL in a route table;
    * `{:store, op, model, args}`: `Cmd.store.<op>` (`insert`, `list`,
      `get`, `update`, `delete`, `tx`), `model` the stored model it works
      on (`nil` for `tx`);
    * `{:unavailable, name}`: an effect no host runs yet (`Cmd.blob.*`,
      `Cmd.ai.*`);
    * `{:error, message}`: an effect that cannot run (`Cmd.random.int` with
      `lo > hi`, a store effect whose model never settled), or
      `{:error, :unknown}` for a value that is no command.

  A store operation's writes are `writes/0`.
  """

  require Logger

  alias Nobi.{Data, Universe}
  alias Nobi.Lang.Routes

  @store_ops ~w(insert list get update delete tx)
  @store_writes ~w(insert update delete tx)

  @none {:var, "Option", "None", []}

  @type effect ::
          {:now, term()}
          | {:random, integer(), integer(), term()}
          | {:navigate, String.t(), [term()]}
          | {:store, String.t(), String.t() | nil, [term()]}
          | {:unavailable, String.t()}
          | {:error, String.t() | :unknown}

  @doc "The store operations that write: run once, never in a static render."
  @spec writes() :: [String.t()]
  def writes, do: @store_writes

  @doc "A Cmd value's effects in order, or `:error` for a value that is no Cmd."
  @spec flatten(term()) :: {:ok, [effect()]} | :error
  def flatten({:cmd, cmd}), do: {:ok, bare(cmd)}
  def flatten(_other), do: :error

  defp bare(:none), do: []
  defp bare({:batch, cmds}) when is_list(cmds), do: Enum.flat_map(cmds, &bare/1)
  defp bare({:effect, "Cmd.time.now", _, [cb]}), do: [{:now, cb}]

  defp bare({:effect, "Cmd.random.int", _, [lo, hi, cb]})
       when is_integer(lo) and is_integer(hi) and lo <= hi,
       do: [{:random, lo, hi, cb}]

  defp bare({:effect, "Cmd.random.int", _, _}), do: [{:error, "Cmd.random.int needs lo ≤ hi"}]

  defp bare({:effect, "Cmd.navigate", _, [app | args]}) when is_binary(app),
    do: [{:navigate, app, args}]

  defp bare({:effect, "Cmd.store." <> op = name, model, args}) when op in @store_ops do
    if model == nil and op != "tx",
      do: [{:error, "#{name}: the stored model it works on never settled, so nothing was run"}],
      else: [{:store, op, model, args}]
  end

  defp bare({:effect, name, _, _}) when is_binary(name), do: [{:unavailable, name}]
  defp bare(_other), do: [{:error, :unknown}]

  @doc "An effect as its call names it: `Cmd.store.insert(Forum.Topic)`, `Cmd.time.now`."
  @spec describe(effect()) :: String.t()
  def describe({:now, _}), do: "Cmd.time.now"
  def describe({:random, lo, hi, _}), do: "Cmd.random.int(#{lo}, #{hi})"
  def describe({:navigate, app, _}), do: "Cmd.navigate(#{app})"
  def describe({:store, "tx", _, _}), do: "Cmd.store.tx"
  def describe({:store, op, model, _}), do: "Cmd.store.#{op}(#{model})"
  def describe({:unavailable, name}), do: name
  def describe({:error, _}), do: "(an effect that cannot run)"

  @doc "Now, in Unix milliseconds: what `Cmd.time.now`'s callback gets."
  @spec now() :: integer()
  def now, do: System.system_time(:millisecond)

  @doc """
  The URL path of the route in `entries` that opens `app` with `args`, or
  `:error` when none does (`Nobi.Lang.Routes.path/3`).
  """
  @spec path([Routes.entry()], String.t(), [term()]) :: {:ok, String.t()} | :error
  def path(entries, app, args) do
    Routes.path(entries, app, args)
  rescue
    # Raised when the args do not fit the route's params.
    ArgumentError -> :error
  end

  @doc """
  Runs store operation `op` on deployment `name`'s own data (`Nobi.Data`,
  its file opened by the deployment's name, whatever commit it serves),
  typing rows by the models of `origin` (the image the effect came from):
  `{:ok, value, cb}`, `cb` to apply to `value`, or `{:error, e}` (a
  `%{code, message}` or a message). A failed `tx` is no error: its value is
  `Result.Err(message)`.
  """
  @spec run_store(String.t(), term(), String.t(), String.t() | nil, [term()]) ::
          {:ok, term(), term()} | {:error, term()}
  def run_store(name, origin, op, model, args) do
    with {:ok, repo} <- open_data(name),
         {:ok, image} <- Universe.image(origin),
         {:ok, models} <- models(image) do
      store_op(op, repo, image, model, models, args)
    end
  end

  defp open_data(name) do
    case Data.open(name) do
      {:ok, repo} ->
        {:ok, repo}

      {:error, reason} ->
        Logger.error(
          "Nobi.Deployment.Effects: cannot open the data of #{name}: #{inspect(reason)}"
        )

        {:error, %{code: "unavailable", message: "this deployment's data cannot be opened"}}
    end
  end

  # What the store types rows by: the image's models and deftypes.
  defp models(image) do
    {:ok, %{models: image.module.__nobi__(:models), types: image.module.__nobi__(:types)}}
  rescue
    UndefinedFunctionError ->
      {:error, %{code: "unloaded", message: "the code this effect came from was unloaded"}}
  end

  defp store_op("insert", repo, _image, model, models, [row, cb]),
    do: with({:ok, id} <- Data.insert(repo, model, models, row), do: {:ok, id, cb})

  defp store_op("list", repo, _image, model, models, [cb]),
    do: with({:ok, rows} <- Data.list(repo, model, models), do: {:ok, rows, cb})

  defp store_op("get", repo, _image, model, models, [id, cb]),
    do: with({:ok, row} <- Data.get(repo, model, models, id), do: {:ok, option(row), cb})

  defp store_op("update", repo, _image, model, models, [id, row, cb]),
    do: with({:ok, id} <- Data.update(repo, model, models, id, row), do: {:ok, id, cb})

  defp store_op("delete", repo, _image, model, models, [id, cb]),
    do: with({:ok, row} <- Data.delete(repo, model, models, id), do: {:ok, option(row), cb})

  defp store_op("tx", repo, image, _model, _models, [body, cb]) do
    case Data.Tx.run(repo, image, body) do
      {:ok, {ids, r}} -> {:ok, {:var, "Result", "Ok", [{ids, r}]}, cb}
      {:error, message} -> {:ok, {:var, "Result", "Err", [message]}, cb}
    end
  end

  defp store_op(op, _repo, _image, _model, _models, _args),
    do: {:error, "Cmd.store.#{op} got arguments of the wrong shape"}

  defp option(nil), do: @none
  defp option(row), do: {:var, "Option", "Some", [row]}
end
