defmodule Nobi.PersistentTraced do
  @moduledoc """
  A `Nobi.PersistentElmGenServer` whose `encode/1` tells the pid in
  `:notify` `{:encoding, count, boots}`, so a test can see in its mailbox
  whether a state was encoded before or after the step's effects.
  `init/1` takes that pid and tells it `:init_ran`; `resume/1` bumps `:boots`
  and tells it `:resumed`.
  """

  use Nobi.PersistentElmGenServer
  alias Nobi.Elm.Effect, as: Fx

  @impl true
  def init(notify), do: {%{count: 0, boots: 0, notify: notify}, Fx.send_to(notify, :init_ran)}

  @impl true
  def resume(s), do: {%{s | boots: s.boots + 1}, Fx.send_to(s.notify, :resumed)}

  @impl true
  def encode(s) do
    send(s.notify, {:encoding, s.count, s.boots})
    :erlang.term_to_binary(s)
  end

  @impl true
  def update({:inc_then_send, pid}, s) do
    s = %{s | count: s.count + 1}
    {s, Fx.send_to(pid, {:sent, s.count})}
  end
end
