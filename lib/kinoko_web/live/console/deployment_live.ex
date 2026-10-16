defmodule KinokoWeb.Console.DeploymentLive do
  @moduledoc """
  `/_/d/:name`: a deployment's universe, route table, whether it follows
  head or is pinned, its hosts (links to where it is served), its
  parameter-free paths as links, and its stored models (`Kinoko.Data.stats/1`:
  each model's table, row count and columns). Refreshes on commits of its
  universe.
  """

  use KinokoWeb, :live_view

  import KinokoWeb.Console.Components

  alias Kinoko.{Data, Deployment, Universe}

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

        models =
          for stat <- Data.stats(d.name) do
            Map.merge(stat, %{id: stat.model, columns: Enum.map(stat.columns, &column/1)})
          end

        socket
        |> assign(deployment: d, link_base: host_url(link_host), model_count: length(models))
        |> stream(:hosts, hosts, reset: reset?)
        |> stream(:routes, routes, reset: reset?)
        |> stream(:models, models, reset: reset?)

      :error ->
        push_navigate(socket, to: ~p"/_")
    end
  end

  # `id` and `_seq` are the store's own columns (no field).
  defp column(%{name: name, field: field, type: type}),
    do: %{name: name, field: field, type: type, own?: field == nil}

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      flash={@flash}
      console={@console}
      streams={@streams}
      title="Deployment"
      subtitle={@deployment.name}
    >
      <.page>
        <div class="flex flex-col gap-[6px] min-w-0">
          <div class="flex items-center gap-[9px]">
            <span
              id="deployment-name"
              class="font-(family-name:--k-display) text-[25px] font-medium tracking-normal"
            >
              {@deployment.name}
            </span>
            <%= if @deployment.commit do %>
              <span
                id="deployment-commit"
                data-mode="pinned"
                class="text-[11.5px] text-(--k-faint) bg-(--k-sand) border border-(--k-line) px-[8px] py-[2px] rounded-[5px]"
              >
                pinned @ #{@deployment.commit}
              </span>
            <% else %>
              <span
                id="deployment-commit"
                data-mode="following"
                class="text-[11.5px] text-(--k-mint) bg-(--k-mint-chip) border border-(--k-mint-chip-border) px-[8px] py-[2px] rounded-[5px]"
              >
                following head
              </span>
            <% end %>
          </div>
          <span class="text-[12.5px] text-(--k-dim)">
            serving
            <.link
              navigate={~p"/_/u/#{@deployment.universe}"}
              class="text-(--k-violet) hover:text-(--k-violet-hover)"
            >
              {@deployment.universe}
            </.link>
            · routes <span class="font-(family-name:--k-mono)">{@deployment.routes}</span>
          </span>
        </div>

        <.section title="Hosts" id="hosts-section">
          <div id="hosts" phx-update="stream" class={table_class()}>
            <div :for={{dom_id, h} <- @streams.hosts} id={dom_id} class={row_rule_class()}>
              <a
                href={host_url(h.host) <> "/"}
                target="_blank"
                rel="noopener"
                class="font-(family-name:--k-mono) text-(--k-violet) hover:text-(--k-violet-hover)"
              >
                {host_url(h.host)}/
              </a>
            </div>
          </div>
        </.section>

        <.section title="Routes" id="routes-section">
          <div id="routes" phx-update="stream" class={table_class()}>
            <div id="empty-1" class={empty_class()}>No routes.</div>
            <div
              :for={{dom_id, r} <- @streams.routes}
              id={dom_id}
              data-pattern={r.pattern}
              class={row_rule_class()}
            >
              <%= if r.path do %>
                <a
                  href={@link_base <> r.path}
                  data-path={r.path}
                  target="_blank"
                  rel="noopener"
                  class="font-(family-name:--k-mono) text-(--k-violet) hover:text-(--k-violet-hover)"
                >
                  {r.pattern}
                </a>
              <% else %>
                <span
                  class="font-(family-name:--k-mono) text-(--k-dim)"
                  title="has params: open it from the app"
                >
                  {r.pattern}
                </span>
              <% end %>
              <div class="flex-1"></div>
              <span class="font-(family-name:--k-mono) text-[11.5px] text-(--k-dim)">
                → {r.app}
              </span>
            </div>
          </div>
        </.section>

        <.section title={"Models · #{@model_count}"} id="models-section">
          <div id="models" phx-update="stream" class="flex flex-col gap-[9px]">
            <div id="models-empty" class={empty_class()}>
              Nothing stored yet: a table appears with the first
              <span class="font-(family-name:--k-mono)">Cmd.store</span>
              call.
            </div>
            <article :for={{dom_id, m} <- @streams.models} id={dom_id} class={table_class()}>
              <div class="flex items-baseline gap-[10px] px-[12px] py-[7px] bg-(--k-tint) border-b border-(--k-line)">
                <span class="font-(family-name:--k-mono) text-[12.5px] font-medium">{m.model}</span>
                <span
                  class="font-(family-name:--k-mono) text-[11px] text-(--k-faint)"
                  data-table={m.table}
                >
                  {m.table}
                </span>
                <div class="flex-1"></div>
                <span
                  class="font-(family-name:--k-mono) text-[11.5px] text-(--k-dim)"
                  data-rows={m.rows}
                >
                  {count(m.rows, "row")}
                </span>
              </div>
              <div
                :for={c <- m.columns}
                data-column={c.name}
                data-type={c.type}
                class={[row_rule_class(), c.own? && "text-(--k-faint)"]}
              >
                <span class="font-(family-name:--k-mono)">
                  {c.name}
                  <span :if={c.field && c.field != c.name} class="text-(--k-faint)">
                    ({c.field})
                  </span>
                </span>
                <div class="flex-1"></div>
                <span class="font-(family-name:--k-mono) text-(--k-dim)">{c.type}</span>
              </div>
            </article>
          </div>
        </.section>
      </.page>
    </.shell>
    """
  end
end
