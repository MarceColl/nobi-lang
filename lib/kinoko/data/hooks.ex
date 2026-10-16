defmodule Kinoko.Data.Hooks do
  @moduledoc """
  The store reads a transaction body makes: what compiled `Store.get` and
  `Store.list` call, outside the pure `Kinoko.Lang` (as `Kinoko.Exec.Hooks`
  is for `always`).

  ## The handle

  A `Store` value is `{:store, coordinator, ref}`: the pid of the
  transaction's coordinator and the reference naming that transaction.
  Only a running `Cmd.store.tx` makes one, and hands it to the body.

  ## The protocol

  A read sends the coordinator

      {:kinoko_store_read, ref, reader_pid, op}

  where `op` is `{:get, model, id}` or `{:list, model}` (`model` the stored
  model's name, a binary; `id` a `{:uuid, _}`), and waits for

      {:kinoko_store_reply, ref, reply}

  where `reply` is:

  - `{:ok, value}`: the Yabu value read (`Option<M>` for `get`, `List<M>`
    for `list`);
  - `{:error, message}`: a Yabu runtime error with that message;
  - `:closed`: the transaction is over (its body has returned).

  A coordinator that is gone, or answers `:closed`, means the handle
  outlived its transaction: the Yabu runtime error
  `"store handle used outside its transaction"`. An answer of any other
  shape is a Yabu runtime error too, never a crash.

  ## No deadline of its own

  A read waits for its answer without a timeout of its own
  (`read_timeout/0` is `:infinity`): the transaction's one deadline
  governs it. The body runs in an Exec worker bounded by the transaction
  timeout (`Kinoko.Data.Tx`), which kills the reader, waiting or not; and
  the coordinator answers every read promptly while it lives (`:closed`
  once the body has returned, including for a ref not its own), so a
  read on a live coordinator never hangs and one on a dead coordinator
  ends on the monitor. `request/3` takes an explicit timeout, for tests.

  The reader monitors the coordinator for the read's duration, and takes
  only a reply carrying the handle's `ref`.
  """

  import Kinoko.Lang.Rt, only: [error!: 1]

  @read_timeout :infinity
  @outside "store handle used outside its transaction"

  @doc "How long a read waits for the coordinator: `:infinity` (see \"No deadline of its own\")."
  @spec read_timeout() :: timeout()
  def read_timeout, do: @read_timeout

  @doc "`Store.get(s, id)` of `model`: `Option<M>`."
  @spec store_get(term(), String.t(), term()) :: term()
  def store_get(store, model, id), do: request(store, {:get, model, id}, @read_timeout)

  @doc "`Store.list(s)` of `model`: `List<M>`."
  @spec store_list(term(), String.t()) :: term()
  def store_list(store, model), do: request(store, {:list, model}, @read_timeout)

  @doc """
  Sends `op` to the handle's coordinator and returns the value it answers,
  waiting at most `timeout` ms; throws a Yabu runtime error otherwise (see
  the moduledoc).
  """
  @spec request(term(), tuple(), timeout()) :: term()
  def request({:store, coordinator, ref}, op, timeout)
      when is_pid(coordinator) and is_reference(ref) do
    mon = Process.monitor(coordinator)
    send(coordinator, {:kinoko_store_read, ref, self(), op})

    receive do
      {:kinoko_store_reply, ^ref, reply} ->
        Process.demonitor(mon, [:flush])
        answer(reply)

      {:DOWN, ^mon, :process, _, _} ->
        error!(@outside)
    after
      timeout ->
        Process.demonitor(mon, [:flush])
        error!("store read timed out after #{timeout} ms")
    end
  end

  def request(_store, _op, _timeout), do: error!("a store read of something not a Store")

  defp answer({:ok, value}), do: value
  defp answer({:error, message}) when is_binary(message), do: error!(message)
  defp answer(:closed), do: error!(@outside)
  defp answer(_), do: error!("the store answered a read with something not a reply")
end
