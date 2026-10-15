defmodule Kinoko.Elm.Host do
  @moduledoc """
  The GenServer side shared by `Kinoko.ElmGenServer` and
  `Kinoko.PersistentElmGenServer`: the server state is a `Kinoko.Elm.Runtime`,
  every call, cast and process message goes through it, and the host effects
  it hands back are folded into the GenServer reply. The only host effect a
  GenServer understands is `stop`.
  """

  alias Kinoko.Elm.Runtime

  @doc "Turns the result of `Runtime.init/4` into a `GenServer.init/1` reply."
  def init(result) do
    case host(result) do
      {:noreply, runtime} -> {:ok, runtime}
      {:stop, reason, _runtime} -> {:stop, reason}
    end
  end

  def handle_call(request, from, runtime),
    do: runtime |> Runtime.step({:call, from, request}) |> host()

  def handle_cast(msg, runtime), do: runtime |> Runtime.step(msg) |> host()

  def handle_info(msg, runtime), do: runtime |> Runtime.info(msg) |> host()

  defp host({runtime, effects}) do
    Enum.reduce(effects, {:noreply, runtime}, fn
      {:stop, reason}, {:noreply, runtime} -> {:stop, reason, runtime}
      {:stop, _reason}, stopping -> stopping
      other, _ -> raise ArgumentError, "#{inspect(other)} is not supported in an ElmGenServer"
    end)
  end
end
