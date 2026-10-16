defmodule KinokoWeb.Console.DeploymentLive do
  @moduledoc """
  `/_/d/:name`, ported from the Vellum prototype's `deploymentStage()`: the
  header (name, follow/pinned chip, URL, serving line, Open, Promote), the
  promote callout (pinned behind head), the deployed versions (history, newest
  first, with roll back / follow head), the route table and the stored models
  (`Kinoko.Data.stats/1`). Refreshes on commits of its universe and on
  `{:deployment_changed, name}`.
  """

  use KinokoWeb, :live_view

  import KinokoWeb.Console.Components

  alias Kinoko.{Data, Deployment, Universe}
  alias KinokoWeb.Console.Live, as: Console

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Deployment.get(name) do
      {:ok, d} ->
        if connected?(socket) do
          Universe.subscribe(d.universe)
          Phoenix.PubSub.subscribe(Kinoko.PubSub, Deployment.topic(name))
        end

        {:ok, socket |> assign(name: name, page_title: name) |> load()}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "No deployment named #{name}")
         |> push_navigate(to: ~p"/_")}
    end
  end

  @impl true
  def handle_info({:committed, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:deployment_changed, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("roll_back", %{"n" => n}, socket) do
    with {n, ""} <- Integer.parse(n),
         :ok <- Deployment.pin(socket.assigns.name, n) do
      {:noreply, socket |> load() |> Console.refresh_sidebar()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not roll back")}
    end
  end

  def handle_event("follow", _params, socket) do
    case Deployment.follow(socket.assigns.name) do
      :ok -> {:noreply, socket |> load() |> Console.refresh_sidebar()}
      _ -> {:noreply, put_flash(socket, :error, "Could not follow head")}
    end
  end

  defp load(socket) do
    case Deployment.get(socket.assigns.name) do
      {:ok, d} ->
        rounds = listed(Universe.history(d.universe))

        head = length(rounds)
        current = d.commit || head

        entries =
          with {:ok, target} <- Deployment.target(d),
               %{} = routes <- Universe.routes(target) do
            Map.get(routes, d.routes, [])
          else
            _ -> []
          end

        url_host = d.hosts |> List.first() |> Kernel.||("#{d.name}.localhost")

        routes =
          for {e, i} <- Enum.with_index(entries) do
            %{id: "dep-route-#{i}", pattern: pattern(e), app: e.app, path: static_path(e)}
          end

        hosts =
          ["#{d.name}.localhost" | d.hosts]
          |> Enum.uniq()
          |> Enum.map(&%{id: "dep-host-" <> &1, host: &1, url: host_url(&1)})

        models =
          for stat <- Data.stats(d.name) do
            %{
              id: "dep-model-" <> stat.model,
              model: stat.model,
              rows: stat.rows,
              # declared fields only: `id` and the internal `_seq` have no field
              columns: stat.columns |> Enum.filter(& &1.field) |> Enum.map_join(", ", & &1.name)
            }
          end

        versions =
          for {round, n} <- rounds |> Enum.with_index(1) |> Enum.reverse() do
            %{
              id: "dep-ver-#{n}",
              n: n,
              patches: Enum.join(round.ids, ", "),
              plus: Enum.count(round.entries, &match?({:live, _, _}, &1)),
              minus: Enum.count(round.entries, &match?({:gone, _}, &1)),
              current?: n == current,
              action: version_action(n, current, head, d.commit)
            }
          end

        ahead =
          if d.commit && d.commit < head do
            ids = rounds |> Enum.drop(d.commit) |> Enum.flat_map(& &1.ids)
            %{count: head - d.commit, ids: Enum.take(ids, 3)}
          end

        socket
        |> assign(
          deployment: d,
          url: host_url(url_host),
          current: current,
          ahead: ahead
        )
        |> stream(:versions, versions, reset: true, dom_id: & &1.id)
        |> stream(:routes, routes, reset: true, dom_id: & &1.id)
        |> stream(:hosts, hosts, reset: true, dom_id: & &1.id)
        |> stream(:models, models, reset: true, dom_id: & &1.id)

      :error ->
        push_navigate(socket, to: ~p"/_")
    end
  end

  defp version_action(n, current, _head, _commit) when n == current, do: :current
  defp version_action(n, _current, head, commit) when commit != nil and n == head, do: :follow
  defp version_action(n, current, _head, _commit) when n > current, do: :roll_forward
  defp version_action(_n, _current, _head, _commit), do: :roll_back

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      flash={@flash}
      console={@console}
      streams={@streams}
      title="Deployment"
      subtitle={@deployment.name}
      commit={"##{@current}"}
    >
      <.page>
        <div id="dep-header" class="flex items-start gap-[16px]">
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
                  pinned
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
            <a
              id="dep-url"
              href={@url <> "/"}
              target="_blank"
              rel="noopener"
              class="font-(family-name:--k-mono) text-[12.5px] text-(--k-violet) hover:text-(--k-violet-hover) truncate"
            >
              {@url}
            </a>
            <span id="dep-serving" class="text-[12.5px] text-(--k-dim)">
              serving
              <.link
                navigate={~p"/_/u/#{@deployment.universe}"}
                class="text-(--k-violet) hover:text-(--k-violet-hover)"
              >
                {@deployment.universe}
              </.link>
              · commit #{@current}
            </span>
          </div>
          <div class="flex-1"></div>
          <div class="flex gap-[8px] flex-none">
            <a
              id="dep-open"
              href={@url <> "/"}
              target="_blank"
              rel="noopener"
              class="h-[30px] px-[12px] rounded-[6px] text-[12.5px] flex items-center gap-[6px] border border-(--k-line) bg-(--k-card) text-(--k-body) transition-colors hover:bg-(--k-tint)"
            >
              <.icon name="ph-arrow-square-out" class="text-[13px]" /> Open
            </a>
            <button
              :if={@deployment.commit}
              id="dep-promote-btn"
              type="button"
              phx-click="follow"
              class="h-[30px] px-[12px] rounded-[6px] text-[12.5px] font-medium flex items-center gap-[6px] border border-(--k-violet-btn-border) bg-(--k-violet-chip) text-(--k-violet) cursor-pointer"
            >
              <.icon name="ph-arrow-fat-line-up" class="text-[13px]" /> Promote {@deployment.universe}
            </button>
          </div>
        </div>

        <div
          :if={@ahead}
          id="dep-promote"
          class="px-[13px] py-[11px] rounded-[9px] bg-(--k-violet-chip) border border-(--k-violet-chip-border) flex items-center gap-[12px]"
        >
          <.icon name="ph-arrow-fat-line-up" class="text-[15px] text-(--k-violet)" />
          <div class="flex flex-col gap-[2px] min-w-0">
            <span class="text-[12.5px] font-medium">
              {@deployment.universe} is {count(@ahead.count, "commit")} ahead of this deployment
            </span>
            <span class="text-[12px] text-(--k-dim) truncate">
              Promotes {Enum.join(@ahead.ids, ", ")}
            </span>
          </div>
        </div>

        <.section title="Deployed versions" id="dep-versions-section">
          <div class={table_class()}>
            <.thead cols={[
              {"version", 1, nil},
              {"patches", 4, nil},
              {"symbols changed", 2, nil},
              {"", 2, "right"}
            ]} />
            <div id="dep-versions" phx-update="stream">
              <div id="dep-versions-empty" class={empty_class()}>No versions yet.</div>
              <div
                :for={{dom_id, v} <- @streams.versions}
                id={dom_id}
                data-current={v.current? || nil}
                class={[
                  "dep-row flex items-center border-(--k-row-line-2) [.dep-row+&]:border-t",
                  if(v.current?, do: "bg-[#FAFAF7]", else: "bg-(--k-card)")
                ]}
              >
                <span class={[cell(), "flex-1 font-(family-name:--k-mono) text-[12px] font-medium"]}>
                  #{v.n}
                </span>
                <span class={[
                  cell(),
                  "flex-[4] font-(family-name:--k-mono) text-[11.5px] text-(--k-faint)"
                ]}>
                  {v.patches}
                </span>
                <span class={[cell(), "dep-symbols flex-[2] font-(family-name:--k-mono) text-[12px]"]}>
                  +{v.plus} −{v.minus}
                </span>
                <span class={[cell(), "flex-[2] text-right text-[11.5px] font-medium"]}>
                  <%= case v.action do %>
                    <% :current -> %>
                      <span class="dep-current text-(--k-mint)">current</span>
                    <% :follow -> %>
                      <button
                        type="button"
                        phx-click="follow"
                        class="text-(--k-violet) cursor-pointer hover:text-(--k-violet-hover)"
                      >
                        follow head
                      </button>
                    <% action when action in [:roll_back, :roll_forward] -> %>
                      <button
                        type="button"
                        phx-click="roll_back"
                        phx-value-n={v.n}
                        class="text-(--k-violet) cursor-pointer hover:text-(--k-violet-hover)"
                      >
                        {if(action == :roll_forward, do: "roll forward", else: "roll back")}
                      </button>
                  <% end %>
                </span>
              </div>
            </div>
          </div>
        </.section>

        <.section title="Routes" id="dep-routes-section">
          <div class={table_class()}>
            <.thead cols={[{"route", 3, nil}, {"app", 3, nil}, {"", 1, "right"}]} />
            <div id="dep-routes" phx-update="stream">
              <div id="dep-routes-empty" class={empty_class()}>No routes.</div>
              <div
                :for={{dom_id, r} <- @streams.routes}
                id={dom_id}
                data-pattern={r.pattern}
                class="dep-row flex items-center border-(--k-row-line-2) [.dep-row+&]:border-t"
              >
                <span class={[cell(), "flex-[3] font-(family-name:--k-mono) text-[12px] font-medium"]}>
                  {r.pattern}
                </span>
                <span class={[
                  cell(),
                  "dep-app flex-[3] font-(family-name:--k-mono) text-[11.5px] text-(--k-dim)"
                ]}>
                  {r.app}
                </span>
                <span class={[cell(), "flex-1 text-right text-[12.5px]"]}>
                  <a
                    :if={r.path}
                    href={@url <> r.path}
                    data-path={r.path}
                    target="_blank"
                    rel="noopener"
                    class="text-[11.5px] text-(--k-violet) hover:text-(--k-violet-hover)"
                  >
                    open
                  </a>
                </span>
              </div>
            </div>
          </div>
        </.section>

        <.section title="Hosts" id="dep-hosts-section">
          <div class={table_class()}>
            <.thead cols={[{"host", 5, nil}, {"", 1, "right"}]} />
            <div id="dep-hosts" phx-update="stream">
              <div
                :for={{dom_id, h} <- @streams.hosts}
                id={dom_id}
                data-host={h.host}
                class="dep-row flex items-center border-(--k-row-line-2) [.dep-row+&]:border-t"
              >
                <span class={[cell(), "flex-[5] font-(family-name:--k-mono) text-[12px] font-medium"]}>
                  {h.host}
                </span>
                <span class={[cell(), "flex-1 text-right text-[12.5px]"]}>
                  <a
                    href={h.url <> "/"}
                    target="_blank"
                    rel="noopener"
                    class="text-[11.5px] text-(--k-violet) hover:text-(--k-violet-hover)"
                  >
                    open
                  </a>
                </span>
              </div>
            </div>
          </div>
        </.section>

        <.section title="Stored models" id="dep-models-section">
          <div class={table_class()}>
            <.thead cols={[{"model", 3, nil}, {"rows", 1, "right"}, {"columns", 5, nil}]} />
            <div id="dep-models" phx-update="stream">
              <div id="dep-models-empty" class={empty_class()}>
                Nothing stored yet: a table appears with the first
                <span class="font-(family-name:--k-mono)">Cmd.store</span>
                call.
              </div>
              <div
                :for={{dom_id, m} <- @streams.models}
                id={dom_id}
                data-model={m.model}
                class="dep-row flex items-center border-(--k-row-line-2) [.dep-row+&]:border-t"
              >
                <span class={[cell(), "flex-[3] font-(family-name:--k-mono) text-[12px] font-medium"]}>
                  {m.model}
                </span>
                <span
                  data-rows={m.rows}
                  class={[cell(), "flex-1 text-right font-(family-name:--k-mono) text-[12px]"]}
                >
                  {m.rows}
                </span>
                <span class={[
                  cell(),
                  "dep-columns flex-[5] font-(family-name:--k-mono) text-[11.5px] text-(--k-faint)"
                ]}>
                  {m.columns}
                </span>
              </div>
            </div>
          </div>
        </.section>
      </.page>
    </.shell>
    """
  end

  # The prototype's `table()` cell: 9px 12px, one line, ellipsis. Size and
  # colour are per column (12.5px ink by default), never stacked on this.
  defp cell, do: "min-w-0 px-[12px] py-[9px] truncate"

  # The prototype's `table()` head: uppercase 11px, .05em, on the tint.
  attr :cols, :list, required: true

  defp thead(assigns) do
    ~H"""
    <div class="flex bg-(--k-tint) border-b border-(--k-line)">
      <span
        :for={{label, flex, align} <- @cols}
        class={[
          "px-[12px] py-[7px] text-[11px] tracking-[.05em] uppercase text-(--k-faint) whitespace-nowrap",
          if(align == "right", do: "text-right", else: "text-left")
        ]}
        style={"flex: #{flex}"}
      >
        {label}
      </span>
    </div>
    """
  end
end
