defmodule NobiWeb.Console.IndexLive do
  @moduledoc """
  `/_`, Home: every universe and every deployment as cards, ported from the
  Vellum prototype's `homeStage()`.
  """

  use NobiWeb, :live_view

  import NobiWeb.Console.Components

  alias Nobi.{Deployment, Universe}

  @impl true
  def mount(_params, _session, socket) do
    universes = universes()

    deployments = Deployment.list()

    {:ok,
     socket
     |> assign(page_title: "Workspace", env_count: length(universes))
     |> assign(dep_count: length(deployments))
     |> stream_configure(:home_envs, dom_id: &("env-" <> &1.name))
     |> stream_configure(:home_deps, dom_id: &("dep-" <> &1.name))
     |> stream(:home_envs, Enum.map(universes, &env_card/1))
     |> stream(:home_deps, Enum.map(deployments, &dep_card/1))}
  end

  defp env_card(u) do
    %{
      name: u.name,
      fork: u.parent != nil,
      tag: universe_tag(u),
      meta: env_meta(u.name)
    }
  end

  # IMPLEMENTATION-MAP §2: a universe card's meta is symbols · apps · stores.
  defp env_meta(name) do
    symbols =
      case Universe.symbols(name) do
        list when is_list(list) -> count(length(list), "symbol")
        _ -> nil
      end

    graph =
      case Universe.graph(name) do
        %{apps: apps, stores: stores} ->
          [count(length(apps), "app"), count(length(stores), "store")]

        _ ->
          []
      end

    Enum.join(Enum.reject([symbols | graph], &is_nil/1), " · ")
  end

  defp dep_card(d) do
    %{
      name: d.name,
      following: d.commit == nil,
      meta:
        if(d.commit,
          do: "#{d.universe} · pinned @ ##{d.commit}",
          else: "#{d.universe} · following head"
        )
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      flash={@flash}
      console={@console}
      streams={@streams}
      title="Workspace"
      subtitle={"#{count(@env_count, "environment")} · #{count(@dep_count, "deployment")}"}
    >
      <div
        id="console-index"
        class="flex-1 min-w-0 overflow-y-auto py-[24px] px-[26px] bg-(--k-paper) flex flex-col gap-[22px]"
      >
        <div class="flex flex-col gap-[6px] max-w-[560px]">
          <span
            id="home-title"
            class="font-(family-name:--k-display) text-[25px] font-medium tracking-normal"
          >
            Workspace
          </span>
          <span class="text-[13px] leading-[1.6] text-(--k-dim) [text-wrap:pretty]">
            {count(@env_count, "environment")}, each its own code image and history.
          </span>
        </div>

        <div id="home-envs" phx-update="stream" class="flex gap-[12px] flex-wrap">
          <.link
            :for={{dom_id, e} <- @streams.home_envs}
            id={dom_id}
            navigate={~p"/_/u/#{e.name}"}
            class="w-[250px] py-[14px] px-[15px] rounded-[10px] bg-(--k-card) border border-(--k-line) cursor-pointer flex flex-col gap-[9px] shadow-[0_1px_3px_rgba(27,26,23,.05)]"
          >
            <div class={[
              "w-[30px] h-[30px] rounded-[7px] flex items-center justify-center",
              if(e.fork, do: "bg-(--k-amber-chip)", else: "bg-[#EDE8F8]")
            ]}>
              <.icon :if={!e.fork} name="ph-cube" class="text-[15px] text-(--k-violet)" />
              <.icon :if={e.fork} name="ph-git-fork" class="text-[15px] text-(--k-violet)" />
            </div>
            <div class="flex flex-col gap-[2px]">
              <span class="text-[14px] font-semibold">{e.name}</span>
              <span class="font-(family-name:--k-mono) text-[11px] text-(--k-faint)">{e.tag}</span>
            </div>
            <span class="text-[12px] text-(--k-dim)">{e.meta}</span>
          </.link>
        </div>

        <div class="max-w-[560px] h-px bg-(--k-line)"></div>

        <div class="flex flex-col gap-[8px] max-w-[560px]">
          <span class="font-(family-name:--k-display) text-[18px] font-medium">Deployments</span>
          <span class="text-[13px] leading-[1.6] text-(--k-dim) [text-wrap:pretty]">
            A deployment is a stable serving slot — its URL, data and history stay put while environments are promoted into it.
          </span>
          <div id="home-deps" phx-update="stream" class="flex gap-[12px] flex-wrap pt-[4px]">
            <.link
              :for={{dom_id, d} <- @streams.home_deps}
              id={dom_id}
              navigate={~p"/_/d/#{d.name}"}
              class="w-[250px] py-[14px] px-[15px] rounded-[10px] bg-(--k-card) border border-(--k-line) cursor-pointer flex flex-col gap-[9px]"
            >
              <div class={[
                "w-[30px] h-[30px] rounded-[7px] flex items-center justify-center",
                if(d.following, do: "bg-(--k-mint-chip)", else: "bg-(--k-sand)")
              ]}>
                <.icon
                  name="ph-rocket-launch"
                  class={
                    "text-[15px] " <>
                      if(d.following, do: "text-(--k-mint)", else: "text-(--k-faint)")
                  }
                />
              </div>
              <span class="text-[14px] font-semibold">{d.name}</span>
              <span class="text-[12px] text-(--k-dim)">{d.meta}</span>
            </.link>
          </div>
        </div>
      </div>
    </.shell>
    """
  end
end
