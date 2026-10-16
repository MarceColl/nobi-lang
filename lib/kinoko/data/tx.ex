defmodule Kinoko.Data.Tx do
  @moduledoc """
  Closure transactions: what `Cmd.store.tx(body, cb)` runs. `run/4`
  answers `{:ok, {inserted_ids, r}}` or `{:error, message}`; the host
  turns that into the callback's `Result<(List<Uuid>, r), String>`.

  ## The coordinator

  Each `run/4` spawns a short-lived coordinator process, which:

  1. opens one `BEGIN IMMEDIATE` transaction on the deployment's file
     (`Kinoko.Data.transaction/2`): SQLite serializes writers, so two
     transactions never interleave and never lose an update;
  2. runs the body in an Exec worker (`Kinoko.Exec.apply/4`, from a
     runner process linked to the coordinator, so the coordinator stays
     free) with the handle `{:store, coordinator, ref}`;
  3. answers the body's `Store.get`/`Store.list` (`Kinoko.Data.Hooks`)
     inside the open transaction;
  4. once the body answers `{ops, r}`, applies the ops in order and
     commits.

  The caller waits for the coordinator's answer or its death. The
  coordinator watches the caller: a caller that dies rolls the
  transaction back and ends it.

  ## What the body sees

  The rows as they were when the transaction began. Its ops are applied
  only after it returns, so a read never sees the body's own ops (and,
  as the transaction holds the write lock, nothing else changes them).

  ## Ops

  - `Tx.insert(row)` inserts with a fresh id; the ids come back in the
    order of the inserts.
  - `Tx.update(id, row)` replaces the row; a missing id fails the
    transaction (`"… has no row with id …"`).
  - `Tx.delete(Model, id)` removes the row; a missing id is no op (as
    `Cmd.store.delete` of a missing id is `None`, not an error).

  An op or a read whose model never settled (a store form in a lone
  expression, `model` `nil`) is refused: the transaction does not run
  its ops. So is a body answering anything but `(List<Tx.Op>, r)`.

  ## Failures

  Every failure rolls the whole transaction back and answers
  `{:error, message}`, a message for the program's user:

  - the body's runtime error, its own message;
  - the body past the deadline: `"the transaction took more than N ms"`;
  - the body past its heap: the worker's message;
  - an op failing: the store's message (`"not-found"`, `"store"`,
    `"too-many-rows"` errors name the model and field);
  - the file busy (`SQLITE_BUSY`, past `busy_timeout`) on every try:
    `"the store is busy …"`. Busy is retried up to 3 times, the body
    run again each time, which is safe as the body is pure;
  - anything internal (a crash in the runtime, a dead repo): a generic
    message; the details are logged, not shown.

  ## One deadline

  `:timeout` (ms, default Exec's 5_000) bounds a try's body: the worker
  is killed at it (`Kinoko.Exec.Worker`), and the coordinator waits for
  the body at most that long plus a 1_000 ms grace for the worker's
  own answer to arrive, then kills it itself. A read has no deadline of
  its own (`Kinoko.Data.Hooks`): the worker's governs it, and the
  coordinator answers every read promptly. Waiting for the file's write
  lock is bounded by the repo's `busy_timeout`, so one try takes at most
  `busy_timeout + timeout + grace` and a run at most four tries.

  ## Late messages

  A read carrying another ref (a handle from another try, or leaked
  from another transaction) is answered `:closed`, as is any read still
  queued when the coordinator finishes; one sent after it exits ends on
  the reader's monitor. A body answer from an earlier try is ignored.
  """

  require Logger

  alias Kinoko.Data
  alias Kinoko.Exec

  @default_timeout 5_000
  @retries 3
  @grace 1_000

  @none {:var, "Option", "None", []}

  @doc """
  Runs the transaction `body` (a Yabu function of the `Store` handle,
  answering `(List<Tx.Op>, r)`) on `repo` (`Kinoko.Data.open/2`), against
  `target`: an image, `%{image: image, signatures: _}` or a snapshot, as
  `Kinoko.Exec.apply/4` takes. The stored models' signatures are the
  image's `__yabu__(:models)`.

  Options: `:timeout` (ms, default #{@default_timeout}) and
  `:max_heap_size`, the body's limits (see the moduledoc).
  """
  @spec run(pid(), term(), term(), keyword()) ::
          {:ok, {[{:uuid, String.t()}], term()}} | {:error, String.t()}
  def run(repo, target, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, image} <- image(target, opts),
         {:ok, models} <- models(image) do
      state = %{
        repo: repo,
        image: image,
        models: models,
        body: body,
        timeout: timeout,
        exec_opts: opts |> Keyword.take([:max_heap_size]) |> Keyword.put(:timeout, timeout)
      }

      coordinate(state)
    else
      {:error, reason} -> {:error, message(reason, timeout)}
    end
  end

  defp image(%{image: image}, _opts), do: loaded(image)
  defp image(%{module: _, hash: _} = image, _opts), do: loaded(image)
  defp image(%{committed: _} = snapshot, opts), do: wrap(Exec.load(snapshot, opts))
  defp image(other, _opts), do: {:error, {:internal, "not a target: #{inspect(other, limit: 3)}"}}

  defp loaded(%{hash: hash}) do
    case Exec.loaded(hash) do
      {:ok, image} -> {:ok, image}
      :error -> {:error, {:body, %{code: "unloaded", message: "the image is not loaded"}}}
    end
  end

  defp wrap({:ok, image}), do: {:ok, image}
  defp wrap({:error, error}), do: {:error, {:body, error}}

  defp models(image) do
    {:ok, image.module.__yabu__(:models)}
  rescue
    UndefinedFunctionError ->
      {:error, {:body, %{code: "unloaded", message: "the image was unloaded"}}}
  end

  # ---------- the caller ----------

  defp coordinate(state) do
    caller = self()
    reply = make_ref()

    {pid, mon} =
      spawn_monitor(fn ->
        state = Map.put(state, :caller, Process.monitor(caller))
        result = attempt(state, 0)
        drain()
        send(caller, {reply, result})
      end)

    receive do
      {^reply, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^pid, reason} ->
        {:error, message({:internal, "the coordinator stopped: #{inspect(reason)}"}, 0)}
    end
  end

  # ---------- the coordinator ----------

  defp attempt(state, tries) do
    case Data.transaction(state.repo, fn -> body_phase(state) end) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        if busy?(reason) and tries < @retries,
          do: attempt(state, tries + 1),
          else: {:error, message(reason, state.timeout)}
    end
  end

  defp busy?(%{code: "unavailable"}), do: true
  defp busy?({:data, %{code: "unavailable"}}), do: true
  defp busy?(_), do: false

  # Inside the transaction: run the body, serve its reads, apply its ops.
  defp body_phase(state) do
    ref = make_ref()
    coordinator = self()
    handle = {:store, coordinator, ref}

    runner =
      spawn_link(fn ->
        send(
          coordinator,
          {ref, :body, Exec.apply(state.image, state.body, [handle], state.exec_opts)}
        )
      end)

    deadline = System.monotonic_time(:millisecond) + state.timeout + @grace

    case serve(state, ref, runner, deadline, nil) do
      {_, "unavailable" = code} ->
        # A read found the file busy: the body's answer is not to be trusted.
        Data.rollback({:data, %{code: code, message: "a read found the store busy"}})

      {{:ok, {ops, r}}, _} when is_list(ops) ->
        with :ok <- check_ops(ops),
             {:ok, ids} <- apply_ops(state, ops) do
          {ids, r}
        else
          {:error, reason} -> Data.rollback(reason)
        end

      {{:ok, other}, _} ->
        Data.rollback(
          {:shape, "a transaction body answers (List<Tx.Op>, r), not #{shown(other)}"}
        )

      {{:error, error}, _} ->
        Data.rollback({:body, error})
    end
  end

  # Answers reads until the body answers: `{answer, failed read's code}`.
  defp serve(state, ref, runner, deadline, failed) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)
    caller = state.caller

    receive do
      {^ref, :body, answer} ->
        {answer, failed}

      {:kinoko_store_read, ^ref, from, op} ->
        {reply, code} = read(state, op)
        send(from, {:kinoko_store_reply, ref, reply})
        serve(state, ref, runner, deadline, failed || code)

      {:kinoko_store_read, other, from, _op} ->
        send(from, {:kinoko_store_reply, other, :closed})
        serve(state, ref, runner, deadline, failed)

      {:DOWN, ^caller, :process, _, _} ->
        stop(runner)
        Data.rollback(:caller_down)
    after
      left ->
        stop(runner)
        {{:error, %{code: "timeout", message: "the body outlived its deadline"}}, failed}
    end
  end

  # The runner is linked: unlinked first, so its death is not ours. Its
  # worker's guardian kills the worker when the runner dies.
  defp stop(runner) do
    Process.unlink(runner)
    Process.exit(runner, :kill)
  end

  defp read(state, {:get, model, id}) do
    case Data.get(state.repo, model, state.models, id) do
      {:ok, nil} -> {{:ok, @none}, nil}
      {:ok, row} -> {{:ok, {:var, "Option", "Some", [row]}}, nil}
      {:error, %{code: code, message: message}} -> {{:error, message}, code}
    end
  end

  defp read(state, {:list, model}) do
    case Data.list(state.repo, model, state.models) do
      {:ok, rows} -> {{:ok, rows}, nil}
      {:error, %{code: code, message: message}} -> {{:error, message}, code}
    end
  end

  defp read(_state, op), do: {{:error, "a store read of an unknown kind: #{inspect(op)}"}, nil}

  defp check_ops(ops) do
    Enum.find_value(ops, :ok, fn
      {:tx, :insert, model, _} when is_binary(model) -> nil
      {:tx, :update, model, _, _} when is_binary(model) -> nil
      {:tx, :delete, model, _} when is_binary(model) -> nil
      {:tx, kind, nil, _} -> unsettled(kind)
      {:tx, kind, nil, _, _} -> unsettled(kind)
      other -> {:error, {:shape, "a transaction op must be a Tx.Op, not #{shown(other)}"}}
    end)
  end

  defp unsettled(kind) do
    {:error,
     {:shape,
      "Tx.#{kind}'s model never settled (an expression evaluated alone), " <>
        "so the transaction does not run: give the op's row a type that names the model"}}
  end

  # A value's kind, for a message; a non-Yabu value (only a host's own
  # body makes one) is named as such.
  defp shown(value) do
    Kinoko.Lang.Rt.kind_name(value)
  rescue
    FunctionClauseError -> "a value that is no Yabu value"
  end

  defp apply_ops(state, ops) do
    Enum.reduce_while(ops, {:ok, []}, fn op, {:ok, ids} ->
      case apply_op(state, op) do
        {:inserted, id} -> {:cont, {:ok, [id | ids]}}
        :ok -> {:cont, {:ok, ids}}
        {:error, error} -> {:halt, {:error, {:data, error}}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp apply_op(state, {:tx, :insert, model, row}) do
    with {:ok, id} <- Data.insert(state.repo, model, state.models, row), do: {:inserted, id}
  end

  defp apply_op(state, {:tx, :update, model, id, row}) do
    with {:ok, _} <- Data.update(state.repo, model, state.models, id, row), do: :ok
  end

  defp apply_op(state, {:tx, :delete, model, id}) do
    with {:ok, _} <- Data.delete(state.repo, model, state.models, id), do: :ok
  end

  # Reads still queued when the coordinator is done: the transaction is over.
  defp drain do
    receive do
      {:kinoko_store_read, ref, from, _op} ->
        send(from, {:kinoko_store_reply, ref, :closed})
        drain()
    after
      0 -> :ok
    end
  end

  # ---------- messages ----------

  # What the program's user reads; internals go to the log.
  defp message({:body, %{code: "runtime", message: m}}, _timeout), do: m
  defp message({:body, %{code: "heap", message: m}}, _timeout), do: m

  defp message({:body, %{code: "timeout"}}, timeout),
    do: "the transaction took more than #{timeout} ms"

  defp message({:body, %{code: "unloaded"}}, _timeout),
    do: "the code this transaction runs was unloaded; try again"

  defp message({:data, %{code: code, message: m}}, _timeout)
       when code in ["store", "not-found", "too-many-rows"],
       do: m

  defp message({:shape, m}, _timeout), do: m
  defp message(:caller_down, _timeout), do: "the transaction's caller stopped"

  defp message(reason, _timeout) do
    if busy?(reason) do
      Logger.warning("Kinoko.Data.Tx: busy after #{@retries} retries: #{inspect(reason)}")
      "the store is busy; the transaction was not applied, try again"
    else
      Logger.error("Kinoko.Data.Tx failed: #{inspect(reason, limit: 20)}")
      "the transaction failed (an internal error); nothing was applied"
    end
  end
end
