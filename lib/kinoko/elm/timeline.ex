defmodule Kinoko.Elm.Timeline do
  @moduledoc """
  Reads and formats the timeline of any process hosting a `Kinoko.Elm.Runtime`
  (an `ElmGenServer` or an `ElmLiveView`).

  Entries are maps with `:at` (µs since the process started) and a `:kind`:

    * `:msg` — msg number `:seq` went through `update/2`, producing `:state`;
      `:origin` is `nil` when it came from outside (cast, call, event, plain
      message) or `%{id, effect, took_us}` when an effect produced it
    * `:effect` — the runtime started effect `:id`
  """

  alias Kinoko.Elm.Runtime

  @doc "Fetches the timeline of a running ElmGenServer or ElmLiveView process."
  def fetch(server, timeout \\ 5000) do
    pid = GenServer.whereis(server)
    ref = Process.monitor(pid)
    send(pid, {Runtime, :timeline, self(), ref})

    receive do
      {^ref, entries} ->
        Process.demonitor(ref, [:flush])
        entries

      {:DOWN, ^ref, :process, _pid, reason} ->
        exit({reason, {__MODULE__, :fetch, [server]}})
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        exit({:timeout, {__MODULE__, :fetch, [server]}})
    end
  end

  @doc "Prints the timeline of a running process, e.g. from iex."
  def print(server), do: server |> fetch() |> lines() |> Enum.each(&IO.puts/1)

  @doc "Formats entries as one line each."
  def lines(entries), do: Enum.map(entries, &format_entry/1)

  @doc "Formats entries as `%{seq, text}`; `seq` is `nil` for effect lines."
  def rows(entries), do: Enum.map(entries, &%{seq: entry_seq(&1), text: format_entry(&1)})

  defp entry_seq(%{kind: :msg, seq: seq}), do: seq
  defp entry_seq(_entry), do: nil

  defp format_entry(%{kind: :msg, at: at, seq: seq, msg: msg, origin: origin}) do
    from =
      case origin do
        nil -> ""
        %{id: id, effect: effect, took_us: us} -> "   ← ##{id} #{effect} (#{ms(us)})"
      end

    "#{clock(at)}  #{String.pad_trailing("msg #{seq}", 8)}#{short_msg(msg)}#{from}"
  end

  defp format_entry(%{kind: :effect, at: at, id: id, effect: effect}),
    do: "#{clock(at)}    ↳ ##{id} #{effect}"

  defp short_msg({:call, {pid, _tag}, request}), do: "call #{short(request)} from #{inspect(pid)}"
  defp short_msg(msg), do: short(msg)

  defp clock(us), do: String.pad_leading("+" <> ms(us), 11)
  defp ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 1) <> "ms"

  @doc "One-line description of an effect."
  def describe({:async, {:http, opts}, _}),
    do:
      "http #{opts |> Keyword.get(:method, :get) |> to_string() |> String.upcase()} #{opts[:url]}"

  def describe({:async, :now, _}), do: "now"
  def describe({:async, {:random, range}, _}), do: "random #{inspect(range)}"
  def describe({:async, {:task, fun}, _}), do: "task #{inspect(fun)}"
  def describe({:reply, {pid, _}, value}), do: "reply #{short(value)} to #{inspect(pid)}"
  def describe({:send, :self, msg}), do: "dispatch #{short(msg)}"
  def describe({:send, dest, msg}), do: "send #{short(msg)} to #{inspect(dest)}"
  def describe({:broadcast, _pubsub, topic, msg}), do: "broadcast #{short(msg)} on #{topic}"
  def describe({:subscribe, _pubsub, topic, _msg}), do: "subscribe #{topic}"
  def describe({:unsubscribe, _pubsub, topic}), do: "unsubscribe #{topic}"
  def describe({:after_ms, ms, msg}), do: "after #{ms}ms #{short(msg)}"
  def describe({:stop, reason}), do: "stop #{inspect(reason)}"
  def describe({:navigate, to}), do: "navigate #{to}"
  def describe({:patch, to}), do: "patch #{to}"
  def describe({:redirect, to}), do: "redirect #{to}"
  def describe({:push_event, event, payload}), do: "push_event #{event} #{short(payload)}"
  def describe({:flash, kind, message}), do: "flash #{kind} #{short(message)}"
  def describe(other), do: short(other)

  defp short(term) do
    text = inspect(term, limit: 6, printable_limit: 60, width: :infinity)
    if String.length(text) > 110, do: String.slice(text, 0, 107) <> "...", else: text
  end
end
