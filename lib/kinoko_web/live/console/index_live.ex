defmodule KinokoWeb.Console.IndexLive do
  @moduledoc "`/_`: every universe and every deployment, with links in."

  use KinokoWeb, :live_view

  import KinokoWeb.Console.Components

  alias Kinoko.{Deployment, Universe}

  @impl true
  def mount(_params, _session, socket) do
    universes =
      case Universe.list() do
        list when is_list(list) -> list
        _ -> []
      end

    deployments = Deployment.list()

    serving =
      Enum.frequencies_by(deployments, & &1.universe)

    {:ok,
     socket
     |> assign(page_title: "Console")
     |> stream(
       :universes,
       for(u <- universes, do: Map.merge(u, %{id: u.name, serving: Map.get(serving, u.name, 0)}))
     )
     |> stream(:deployments, for(d <- deployments, do: Map.put(d, :id, d.name)))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell flash={@flash} crumbs={[]}>
      <div id="console-index" class="space-y-8">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Universes and deployments</h1>
          <p class="mt-1 text-sm text-zinc-500">
            A universe is a code database; a deployment serves one of its route tables.
          </p>
        </div>

        <.section title="Universes">
          <div id="universes" phx-update="stream" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <div id="empty-1" class="hidden only:block text-sm text-zinc-500">No universes yet.</div>
            <.link
              :for={{dom_id, u} <- @streams.universes}
              id={dom_id}
              navigate={~p"/_/u/#{u.name}"}
              class={[
                card_class(),
                "group block p-4 hover:-translate-y-0.5 hover:border-rose-300 hover:shadow-md dark:hover:border-rose-800"
              ]}
            >
              <div class="flex items-center justify-between">
                <span class="font-mono text-sm font-semibold">{u.name}</span>
                <.icon
                  name="hero-arrow-right"
                  class="size-4 text-zinc-300 transition group-hover:translate-x-0.5 group-hover:text-rose-500"
                />
              </div>
              <div class="mt-3 flex flex-wrap gap-1.5">
                <.badge :if={u.parent} tone={:info}>fork of {u.parent}</.badge>
                <.badge :if={u.serving > 0} tone={:ok}>serving ×{u.serving}</.badge>
              </div>
            </.link>
          </div>
        </.section>

        <.section title="Deployments">
          <div id="deployments" phx-update="stream" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <div id="empty-2" class="hidden only:block text-sm text-zinc-500">
              No deployments yet.
            </div>
            <.link
              :for={{dom_id, d} <- @streams.deployments}
              id={dom_id}
              navigate={~p"/_/d/#{d.name}"}
              class={[
                card_class(),
                "group block p-4 hover:-translate-y-0.5 hover:border-rose-300 hover:shadow-md dark:hover:border-rose-800"
              ]}
            >
              <div class="flex items-center justify-between">
                <span class="font-mono text-sm font-semibold">{d.name}</span>
                <.icon
                  name="hero-arrow-right"
                  class="size-4 text-zinc-300 transition group-hover:translate-x-0.5 group-hover:text-rose-500"
                />
              </div>
              <p class="mt-1 text-xs text-zinc-500">
                {d.universe} · routes {d.routes}
              </p>
              <div class="mt-3">
                <.badge :if={d.commit} tone={:warn}>pinned @ {d.commit}</.badge>
                <.badge :if={!d.commit} tone={:ok}>following head</.badge>
              </div>
            </.link>
          </div>
        </.section>
      </div>
    </.shell>
    """
  end
end
