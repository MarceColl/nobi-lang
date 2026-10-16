defmodule KinokoWeb.Console.Live do
  @moduledoc """
  The console shell's shared state and events, mounted on every `/_`
  LiveView by the router's `live_session :console`
  (`on_mount: KinokoWeb.Console.Live`).

  It assigns `@console` (what `KinokoWeb.Console.Components.shell/1`
  reads: the current universe, the page, the palette, intro and REPL
  state), the sidebar streams `:console_deployments` and `:console_envs`,
  and the palette stream `:cmd_items`, and attaches a `handle_event` hook
  that answers every `"console:*"` event so no LiveView handles them itself.

  The current universe is the route's `:universe`; elsewhere it is the one
  the browser tab last visited (the `console_universe` connect param, kept
  in `sessionStorage` by the `ConsoleKeys` hook), else `"main"`.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2, update: 3]
  import Phoenix.LiveView

  alias Kinoko.{Deployment, Universe}
  alias KinokoWeb.Console.Components

  @env_cap 5
  @symbol_cap 50
  @intro_pages 2
  @echo_cap 160

  def on_mount(:default, params, _session, socket) do
    universes = listed(Universe.list())
    deployments = Deployment.list()
    names = MapSet.new(universes, & &1.name)
    route_universe = params["universe"]
    universe = route_universe || remembered(socket, names) || "main"

    page =
      cond do
        route_universe -> :universe
        params["name"] -> :deployment
        true -> :home
      end

    console = %{
      universe: universe,
      page: page,
      deployment: params["name"],
      universe_count: length(universes),
      deployment_count: length(deployments),
      commit: commit_label(universe),
      cmd_open: false,
      cmd_form: to_form(%{"q" => ""}, as: :cmd),
      intro: nil,
      repl: nil,
      repl_form: to_form(%{"expr" => ""}, as: :repl)
    }

    {:cont,
     socket
     |> assign(:console, console)
     |> stream_configure(:console_deployments, dom_id: &("sidebar-dep-" <> &1.name))
     |> stream_configure(:console_envs, dom_id: &("sidebar-env-" <> &1.name))
     |> stream_configure(:cmd_items, dom_id: & &1.id)
     |> stream(:console_deployments, Enum.map(deployments, &deployment_row(&1, console)))
     |> stream(
       :console_envs,
       universes |> Enum.take(@env_cap) |> Enum.map(&env_row(&1, universe))
     )
     |> stream(:cmd_items, [])
     |> attach_hook(:console, :handle_event, &handle_event/3)}
  end

  defp remembered(socket, names) do
    with true <- connected?(socket),
         %{"console_universe" => name} when is_binary(name) <- get_connect_params(socket),
         true <- MapSet.member?(names, name) do
      name
    else
      _ -> nil
    end
  end

  @doc "The head commit's label, `#<history length>`, or `nil` when it cannot be read."
  @spec commit_label(String.t()) :: String.t() | nil
  def commit_label(universe) do
    case Universe.history(universe) do
      list when is_list(list) -> "##{length(list)}"
      _ -> nil
    end
  end

  defp deployment_row(d, console) do
    %{
      name: d.name,
      tag: "serving " <> d.universe,
      hue: if(d.commit, do: :grey, else: :mint),
      on: console.page == :deployment and console.deployment == d.name
    }
  end

  defp env_row(u, current) do
    %{
      name: u.name,
      tag: Components.universe_tag(u),
      hue: if(u.parent, do: :amber, else: :violet),
      on: u.name == current
    }
  end

  ## Events

  defp handle_event("console:palette-open", _, socket), do: {:halt, open_palette(socket)}
  defp handle_event("console:palette-close", _, socket), do: {:halt, close_palette(socket)}

  defp handle_event("console:palette-toggle", _, socket) do
    if socket.assigns.console.cmd_open,
      do: {:halt, close_palette(socket)},
      else: {:halt, open_palette(socket)}
  end

  defp handle_event("console:palette-filter", %{"cmd" => %{"q" => q}}, socket)
       when is_binary(q),
       do: {:halt, filter_palette(socket, q)}

  defp handle_event("console:palette-go", %{"cmd" => %{"q" => q}}, socket) when is_binary(q) do
    case palette_items(socket.assigns.console.universe, q) do
      [first | _] -> {:halt, push_navigate(socket, to: first.href)}
      [] -> {:halt, socket}
    end
  end

  defp handle_event("console:intro-open", _, socket), do: {:halt, set(socket, :intro, 0)}
  defp handle_event("console:intro-close", _, socket), do: {:halt, set(socket, :intro, nil)}

  defp handle_event("console:intro-next", _, socket) do
    case socket.assigns.console.intro do
      page when is_integer(page) and page < @intro_pages - 1 ->
        {:halt, set(socket, :intro, page + 1)}

      _ ->
        {:halt, set(socket, :intro, nil)}
    end
  end

  defp handle_event("console:intro-back", _, socket) do
    case socket.assigns.console.intro do
      page when is_integer(page) -> {:halt, set(socket, :intro, max(page - 1, 0))}
      nil -> {:halt, socket}
    end
  end

  defp handle_event("console:intro-page", %{"page" => page}, socket) do
    case Integer.parse(to_string(page)) do
      {n, ""} when n >= 0 and n < @intro_pages -> {:halt, set(socket, :intro, n)}
      _ -> {:halt, socket}
    end
  end

  defp handle_event("console:eval", %{"repl" => %{"expr" => expr}}, socket)
       when is_binary(expr) do
    case String.trim(expr) do
      "" ->
        {:halt, socket}

      expr ->
        {:halt,
         socket
         |> set(:repl, evaluate(socket.assigns.console.universe, expr))
         |> push_event("console:repl-done", %{})}
    end
  end

  defp handle_event("console:" <> _, _, socket), do: {:halt, socket}
  defp handle_event(_, _, socket), do: {:cont, socket}

  defp set(socket, key, value), do: update(socket, :console, &Map.put(&1, key, value))

  defp open_palette(socket) do
    socket
    |> set(:cmd_open, true)
    |> filter_palette("")
  end

  defp close_palette(socket) do
    socket
    |> set(:cmd_open, false)
    |> stream(:cmd_items, [], reset: true)
  end

  defp filter_palette(socket, q) do
    socket
    |> set(:cmd_form, to_form(%{"q" => q}, as: :cmd))
    |> stream(:cmd_items, palette_items(socket.assigns.console.universe, q), reset: true)
  end

  ## Palette

  @doc """
  The palette's items for `universe`, filtered by `q` (a case-insensitive
  substring of the name): its apps, stores and first #{@symbol_cap} symbols,
  then every deployment and universe. The first item is marked `first`.
  """
  @spec palette_items(String.t(), String.t()) :: [map()]
  def palette_items(universe, q) do
    needle = q |> String.trim() |> String.downcase()
    hit? = fn name -> needle == "" or String.contains?(String.downcase(name), needle) end
    u = URI.encode(universe)

    {apps, stores} =
      case Universe.graph(universe) do
        %{apps: apps, stores: stores} -> {apps, stores}
        _ -> {[], []}
      end

    symbols =
      universe
      |> Universe.symbols()
      |> listed()
      |> Enum.filter(&hit?.(&1.symbol))
      |> Enum.take(@symbol_cap)

    items =
      for(a <- apps, hit?.(a.symbol), do: item(:app, a.symbol, "/_/u/#{u}?sel=#{enc(a.symbol)}")) ++
        for(
          s <- stores,
          hit?.(s.symbol),
          do: item(:store, s.symbol, "/_/u/#{u}?view=data&store=#{enc(s.symbol)}")
        ) ++
        for(
          s <- symbols,
          do: item(:symbol, s.symbol, "/_/u/#{u}?view=code&sym=#{enc(s.symbol)}")
        ) ++
        for(
          d <- Deployment.list(),
          hit?.(d.name),
          do: item(:deployment, d.name, "/_/d/#{URI.encode(d.name)}")
        ) ++
        for(
          e <- listed(Universe.list()),
          hit?.(e.name),
          do: item(:environment, e.name, "/_/u/#{URI.encode(e.name)}")
        )

    case items do
      [first | rest] -> [%{first | first: true} | rest]
      [] -> []
    end
  end

  defp enc(value), do: URI.encode_www_form(value)

  defp item(kind, name, href),
    do: %{id: "cmd-#{kind}-#{name}", kind: kind, name: name, href: href, first: false}

  ## REPL

  defp evaluate(universe, expr) do
    case Universe.eval(universe, expr) do
      {:ok, value, _type} ->
        %{expr: expr, ok: true, text: truncate("ok · " <> inspect(value))}

      {:error, %{message: _} = reason} ->
        %{expr: expr, ok: false, text: truncate(Components.reason_text(reason))}

      {:error, :no_such_universe} ->
        %{expr: expr, ok: false, text: "no universe named #{universe}"}

      {:error, other} ->
        %{expr: expr, ok: false, text: truncate(inspect(other))}
    end
  end

  defp truncate(text) do
    if String.length(text) > @echo_cap,
      do: String.slice(text, 0, @echo_cap - 1) <> "…",
      else: text
  end

  defp listed(list) when is_list(list), do: list
  defp listed(_), do: []
end
