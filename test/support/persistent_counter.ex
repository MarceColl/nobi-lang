defmodule Kinoko.PersistentCounter do
  @moduledoc """
  A `Kinoko.PersistentElmGenServer` counter used in tests.

  `init/1` takes keyword options: `:count` to start from and `:notify`, a pid
  told `:init_ran` (as an effect) so tests can see whether `init/1` ran.
  `resume/1` bumps `:resumed` and tells `:resumed` to whoever is in `:notify`
  of the state, so a reboot is observable in both the state and the mailbox.
  """

  use Kinoko.PersistentElmGenServer
  alias Kinoko.Elm.Effect, as: Fx

  @impl true
  def init(nil), do: init([])

  def init(opts) do
    notify = Keyword.get(opts, :notify)
    state = %{count: Keyword.get(opts, :count, 0), resumed: 0, notify: notify, extra: nil}
    {state, if(notify, do: Fx.send_to(notify, :init_ran), else: Fx.none())}
  end

  @impl true
  def resume(state) do
    state = %{state | resumed: state.resumed + 1}

    {state, if(is_pid(state.notify), do: Fx.send_to(state.notify, :resumed), else: Fx.none())}
  end

  @impl true
  def update({:call, from, :count}, s), do: {s, Fx.reply(from, s.count)}
  def update({:call, from, :state}, s), do: {s, Fx.reply(from, s)}

  def update({:call, from, :inc}, s) do
    s = %{s | count: s.count + 1}
    {s, Fx.reply(from, s.count)}
  end

  def update(:inc, s), do: {%{s | count: s.count + 1}, Fx.none()}
  def update(:noop, s), do: {s, Fx.none()}
  def update({:put_extra, extra}, s), do: {%{s | extra: extra}, Fx.none()}

  def update({:inc_then_send, pid}, s) do
    s = %{s | count: s.count + 1}
    {s, Fx.send_to(pid, {:sent, s.count})}
  end
end
