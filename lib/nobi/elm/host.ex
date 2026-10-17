defmodule Nobi.Elm.Host do
  @moduledoc """
  The GenServer side shared by `Nobi.ElmGenServer` and
  `Nobi.PersistentElmGenServer`: the server state is a `Nobi.Elm.Runtime`,
  every call, cast and process message goes through it, and the host effects
  it hands back are folded into the GenServer reply. The only host effect a
  GenServer understands is `stop`.

  Every function takes an optional last argument, the host's name with its
  article (default `"an ElmGenServer"`), used in the error for an unsupported
  host effect.
  """

  alias Nobi.Elm.Runtime

  @default_name "an ElmGenServer"

  @doc "Turns the result of `Runtime.init/4` into a `GenServer.init/1` reply."
  def init(result, name \\ @default_name) do
    case host(result, name) do
      {:noreply, runtime} -> {:ok, runtime}
      {:stop, reason, _runtime} -> {:stop, reason}
    end
  end

  def handle_call(request, from, runtime, name \\ @default_name),
    do: runtime |> Runtime.step({:call, from, request}) |> host(name)

  def handle_cast(msg, runtime, name \\ @default_name),
    do: runtime |> Runtime.step(msg) |> host(name)

  def handle_info(msg, runtime, name \\ @default_name),
    do: runtime |> Runtime.info(msg) |> host(name)

  defp host({runtime, effects}, name) do
    Enum.reduce(effects, {:noreply, runtime}, fn
      {:stop, reason}, {:noreply, runtime} -> {:stop, reason, runtime}
      {:stop, _reason}, stopping -> stopping
      other, _ -> raise ArgumentError, "#{inspect(other)} is not supported in #{name}"
    end)
  end
end
