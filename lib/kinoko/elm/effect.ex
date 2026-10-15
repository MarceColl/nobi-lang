defmodule Kinoko.Elm.Effect do
  @moduledoc """
  Effects as data. `init`/`update` return these; `Kinoko.Elm.Runtime` performs them.

  `effects` is a single effect or a (possibly nested) list of them; `[]` is no effect.

  ## Async — the result comes back as a msg

  Each takes a pure `to_msg` closure that turns the result into the msg routed
  back to `update/2`. Results arrive in completion order.

    * `http(req_options, to_msg)` — `to_msg.({:ok, %Req.Response{}} | {:error, exception})`
    * `now(to_msg)` — `to_msg.(%DateTime{})` in UTC
    * `random(range, to_msg)` — `to_msg.(integer)`
    * `task(fun, to_msg)` — escape hatch; `to_msg.({:ok, result} | {:error, reason})`

  ## Commands — no response

    * `reply/2`, `send_to/2`, `dispatch/1`, `after_ms/2`, `broadcast/3` — any host
    * `stop/1` — `Kinoko.ElmGenServer` only
    * `navigate/1`, `patch/1`, `redirect/1`, `push_event/2`, `flash/2` —
      `KinokoWeb.ElmLiveView` only
  """

  @type to_msg :: (term() -> term())
  @type request ::
          {:http, keyword()}
          | :now
          | {:random, Range.t()}
          | {:task, (-> term())}
  @type t ::
          {:async, request(), to_msg()}
          | {:reply, GenServer.from(), term()}
          | {:send, Process.dest() | :self, term()}
          | {:broadcast, atom(), String.t(), term()}
          | {:after_ms, non_neg_integer(), term()}
          | {:stop, term()}
          | {:navigate, String.t()}
          | {:patch, String.t()}
          | {:redirect, String.t()}
          | {:push_event, String.t(), map()}
          | {:flash, atom(), String.t()}
  @type effects :: t() | [effects()]

  def none, do: []

  def batch(effects) when is_list(effects), do: effects

  ## Async

  @doc "Performs an HTTP request with `Req.request/1` options."
  def http(req_options, to_msg) when is_list(req_options) and is_function(to_msg, 1),
    do: {:async, {:http, req_options}, to_msg}

  def now(to_msg) when is_function(to_msg, 1), do: {:async, :now, to_msg}

  def random(%Range{} = range, to_msg) when is_function(to_msg, 1),
    do: {:async, {:random, range}, to_msg}

  def task(fun, to_msg) when is_function(fun, 0) and is_function(to_msg, 1),
    do: {:async, {:task, fun}, to_msg}

  ## Commands

  @doc "Answers a `{:call, from, request}`."
  def reply(from, value), do: {:reply, from, value}

  @doc "Sends `msg` to `dest`; `:self` routes it back into `update/2`."
  def send_to(dest, msg), do: {:send, dest, msg}

  @doc """
  Broadcasts `msg` on `topic` of the `Phoenix.PubSub` named `pubsub`. Performed
  in order with the step's other effects (no task), so two steps' broadcasts
  reach a subscriber in the order the steps ran.
  """
  def broadcast(pubsub, topic, msg) when is_atom(pubsub) and is_binary(topic),
    do: {:broadcast, pubsub, topic, msg}

  @doc "Routes `msg` back into `update/2` after the current update."
  def dispatch(msg), do: {:send, :self, msg}

  @doc "Routes `msg` back into `update/2` after `ms` milliseconds."
  def after_ms(ms, msg) when is_integer(ms) and ms >= 0, do: {:after_ms, ms, msg}

  def stop(reason \\ :normal), do: {:stop, reason}

  def navigate(to) when is_binary(to), do: {:navigate, to}

  def patch(to) when is_binary(to), do: {:patch, to}

  def redirect(to) when is_binary(to), do: {:redirect, to}

  def push_event(event, payload \\ %{}) when is_binary(event) and is_map(payload),
    do: {:push_event, event, payload}

  def flash(kind, message) when kind in [:info, :error], do: {:flash, kind, message}
end
