defmodule KinokoWeb.Console.DeploymentLive do
  @moduledoc """
  `/_/d/:name`: a deployment's universe, route table, whether it follows
  head or is pinned, its hosts (links to where it is served) and its
  parameter-free paths as links. Refreshes on commits of its universe.
  """

  use KinokoWeb, :live_view

  import KinokoWeb.Console.Components

  alias Kinoko.{Deployment, Universe}

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Deployment.get(name) do
      {:ok, d} ->
        if connected?(socket), do: Universe.subscribe(d.universe)
        {:ok, socket |> assign(name: name, page_title: name) |> load()}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "No deployment named #{name}")
         |> push_navigate(to: ~p"/_")}
    end
  end

  @impl true
  def handle_info({:committed, _, _}, socket), do: {:noreply, load(socket, true)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket, reset? \\ false) do
    case Deployment.get(socket.assigns.name) do
      {:ok, d} ->
        entries =
          with {:ok, target} <- Deployment.target(d),
               %{} = routes <- Universe.routes(target) do
            Map.get(routes, d.routes, [])
          else
            _ -> []
          end

        hosts =
          [{"#{d.name}.localhost", true} | Enum.map(d.hosts, &{&1, false})]
          |> Enum.uniq_by(&elem(&1, 0))
          |> Enum.map(fn {h, implicit} -> %{id: "host-" <> h, host: h, implicit: implicit} end)

        link_host = d.hosts |> List.first() |> Kernel.||("#{d.name}.localhost")

        routes =
          for {e, i} <- Enum.with_index(entries) do
            %{id: "route-#{i}", pattern: pattern(e), app: e.app, path: static_path(e)}
          end

        socket
        |> assign(deployment: d, link_base: host_url(link_host))
        |> stream(:hosts, hosts, reset: reset?)
        |> stream(:routes, routes, reset: reset?)

      :error ->
        push_navigate(socket, to: ~p"/_")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell flash={@flash} crumbs={[{@name, nil}]}>
      <div class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 id="deployment-name" class="font-mono text-2xl font-semibold tracking-tight">
            {@deployment.name}
          </h1>
          <p class="mt-1 text-sm text-zinc-500">
            serves routes <span class="font-mono">{@deployment.routes}</span>
            from universe
            <.link navigate={~p"/_/u/#{@deployment.universe}"} class={link_class()}>
              {@deployment.universe}
            </.link>
          </p>
        </div>
        <%= if @deployment.commit do %>
          <.badge id="deployment-commit" data-mode="pinned" tone={:warn}>
            <.icon name="hero-map-pin" class="size-4" /> pinned @ commit {@deployment.commit}
          </.badge>
        <% else %>
          <.badge id="deployment-commit" data-mode="following" tone={:ok}>
            <.icon name="hero-arrow-path" class="size-4" /> following head
          </.badge>
        <% end %>
      </div>

      <.section title="Hosts" id="hosts-section">
        <div id="hosts" phx-update="stream" class="flex flex-wrap gap-2">
          <div :for={{dom_id, h} <- @streams.hosts} id={dom_id}>
            <a
              href={host_url(h.host) <> "/"}
              target="_blank"
              rel="noopener"
              class="group inline-flex items-center gap-1.5 rounded-lg border border-zinc-200 bg-white px-3 py-1.5 font-mono text-sm shadow-sm transition hover:-translate-y-0.5 hover:border-rose-300 hover:shadow dark:border-zinc-800 dark:bg-zinc-900"
            >
              {host_url(h.host)}/
              <.icon
                name="hero-arrow-top-right-on-square"
                class="size-3.5 text-zinc-400 transition group-hover:text-rose-500"
              />
            </a>
          </div>
        </div>
      </.section>

      <.section title="Routes" id="routes-section">
        <div
          id="routes"
          phx-update="stream"
          class={[card_class(), "divide-y divide-zinc-100 overflow-hidden dark:divide-zinc-800"]}
        >
          <div id="empty-1" class="hidden only:block p-4 text-sm text-zinc-500">No routes.</div>
          <div
            :for={{dom_id, r} <- @streams.routes}
            id={dom_id}
            data-pattern={r.pattern}
            class="flex items-center justify-between gap-3 px-4 py-2.5 text-sm"
          >
            <%= if r.path do %>
              <a
                href={@link_base <> r.path}
                data-path={r.path}
                target="_blank"
                rel="noopener"
                class="font-mono text-rose-600 underline decoration-rose-200 underline-offset-4 transition hover:decoration-rose-500 dark:text-rose-400"
              >
                {r.pattern}
              </a>
            <% else %>
              <code class="text-zinc-500" title="has params: open it from the app">{r.pattern}</code>
            <% end %>
            <span class="flex items-center gap-1 font-mono text-xs text-zinc-500">
              <.icon name="hero-arrow-right" class="size-3" /> {r.app}
            </span>
          </div>
        </div>
      </.section>
    </.shell>
    """
  end
end
