defmodule KinokoWeb.Console.Components do
  @moduledoc """
  The console's frame, ported from the Kinoko Vellum prototype
  (`docs/design/kinoko-vellum/Kinoko Vellum.dc.html`): `shell/1` (top bar,
  sidebar, title bar, stage, inspector, REPL bar, ⌘K palette and intro
  dialog), plus the route-table / URL formatting the console LiveViews
  share. The shell's state and events live in `KinokoWeb.Console.Live`.
  """

  use KinokoWeb, :html

  alias Kinoko.Lang.Graph

  @doc """
  The console frame. Every console page renders its stage inside it:

      <.shell flash={@flash} console={@console} streams={@streams}
              view={:graph} title="System" subtitle="1 app · 2 stores">
        stage content
        <:inspector>panel content</:inspector>
      </.shell>

  `console` and `streams` come from `KinokoWeb.Console.Live`. `view`
  (`:graph`, `:code` or `:data`) marks a universe page: it shows the views
  control and the REPL bar, and `nil` hides both. `commit` overrides the
  current universe's head label. The `:inspector` slot, when given, is the
  326px panel over the stage's right edge.
  """
  attr :flash, :map, required: true
  attr :console, :map, required: true
  attr :streams, :any, required: true
  attr :view, :atom, default: nil, values: [nil, :graph, :code, :data]
  attr :title, :string, required: true
  attr :subtitle, :string, default: ""
  attr :commit, :string, default: nil
  slot :inner_block, required: true
  slot :inspector

  def shell(assigns) do
    assigns =
      assign(assigns,
        universe: assigns.console.universe,
        commit: assigns.commit || assigns.console.commit
      )

    ~H"""
    <Layouts.app flash={@flash} bare>
      <div
        id="console"
        phx-hook="ConsoleKeys"
        data-universe={@universe}
        data-remember={to_string(@console.page == :universe)}
        class="k-console h-screen flex flex-col font-(family-name:--k-sans) leading-[normal] text-(--k-ink) bg-(--k-paper) overflow-hidden [color-scheme:light]"
      >
        <div
          id="console-topbar"
          class="h-[46px] flex-none flex items-center gap-[13px] px-[14px] bg-white border-b border-(--k-line)"
        >
          <.link navigate={~p"/_"} class="flex items-center gap-[8px] cursor-pointer">
            <.logo size="17" />
            <span class="text-[14px] font-bold tracking-[-.01em]">kinoko</span>
          </.link>
          <div class="w-px h-[18px] bg-(--k-line)"></div>
          <div class="flex items-center gap-[7px] text-[13px]">
            <.link id="crumb-root" navigate={~p"/_"} class="text-(--k-dim) cursor-pointer">
              kinoko
            </.link>
            <span class="text-(--k-placeholder)">/</span>
            <span
              id="crumb-universe"
              class="font-(family-name:--k-mono) text-[12.5px] font-medium"
            >
              {@universe}
            </span>
          </div>
          <div class="flex-1"></div>
          <button
            id="cmd-open"
            type="button"
            phx-click="console:palette-open"
            class="flex items-center gap-[9px] h-[28px] pr-[10px] pl-[9px] rounded-[6px] bg-(--k-paper) border border-(--k-line) text-(--k-faint) text-[12.5px] w-[250px] cursor-pointer hover:border-[#C4BEAE]"
          >
            <.icon name="ph-magnifying-glass" class="text-[13px]" />
            <span>Jump to…</span>
            <span class="flex-1"></span>
            <span class="font-(family-name:--k-mono) text-[10.5px] border border-(--k-line) rounded-[3px] px-[4px] py-px bg-white">
              ⌘K
            </span>
          </button>
          <button
            id="intro-open"
            type="button"
            phx-click="console:intro-open"
            title="What is this?"
            class="flex-none w-[28px] h-[28px] flex items-center justify-center rounded-[6px] text-(--k-faint) cursor-pointer hover:bg-(--k-paper) hover:text-(--k-violet)"
          >
            <.icon name="ph-question" class="text-[15px]" />
          </button>
        </div>

        <div class="flex-1 min-h-0 flex">
          <.sidebar console={@console} streams={@streams} universe={@universe} />

          <div class="flex-1 min-w-0 flex flex-col">
            <div
              id="console-titlebar"
              class="h-[42px] flex-none flex items-center gap-[12px] px-[14px] border-b border-(--k-line) bg-(--k-tint)"
            >
              <%= if @view do %>
                <div
                  id="views"
                  class="flex items-center gap-[2px] p-[2px] rounded-[7px] bg-(--k-segmented)"
                >
                  <.link
                    :for={{id, name} <- [graph: "Graph", code: "Code", data: "Data"]}
                    id={"view-#{id}"}
                    patch={view_path(@universe, id)}
                    class={[
                      "text-[12.5px] px-[12px] py-[4px] rounded-[5px] cursor-pointer flex-none whitespace-nowrap",
                      if(@view == id,
                        do:
                          "bg-white text-(--k-ink) font-medium shadow-[0_1px_2px_rgba(27,26,23,.08)]",
                        else: "text-(--k-dim)"
                      )
                    ]}
                  >
                    {name}
                  </.link>
                </div>
                <div class="w-px h-[16px] bg-(--k-line)"></div>
              <% end %>
              <span id="console-title" class="text-[13px] font-semibold whitespace-nowrap">
                {@title}
              </span>
              <span
                id="console-subtitle"
                class="text-[12.5px] text-(--k-dim) min-w-0 overflow-hidden text-ellipsis whitespace-nowrap"
              >
                {@subtitle}
              </span>
              <div class="flex-1 min-w-[8px]"></div>
              <span
                id="sandbox-chip"
                title="Generated code runs in an isolate whose bindings are its whole capability set. It has no network egress, so it can only reach the stores and services this environment granted it."
                class="flex-none whitespace-nowrap flex items-center gap-[6px] text-[12px] text-(--k-mint) bg-(--k-mint-chip) border border-(--k-mint-chip-border) px-[9px] py-[3px] rounded-[5px] cursor-help"
              >
                <.icon name="ph-shield-check" class="text-[12px]" />sandboxed · no egress
              </span>
              <span
                :if={@commit}
                id="commit-label"
                class="flex-none font-(family-name:--k-mono) text-[11.5px] text-(--k-faint)"
              >
                {@commit}
              </span>
            </div>

            <div class="flex-1 min-h-0 flex relative">
              <div id="console-stage" class="flex-1 min-w-0 flex min-h-0">
                {render_slot(@inner_block)}
              </div>
              <div
                :if={@inspector != []}
                id="console-inspector"
                class="absolute right-0 top-0 bottom-0 w-[326px] border-l border-(--k-line) bg-(--k-tint) shadow-[-8px_0_24px_rgba(27,26,23,.07)] flex flex-col overflow-y-auto"
              >
                {render_slot(@inspector)}
              </div>
            </div>

            <.repl :if={@view} console={@console} universe={@universe} />
          </div>
        </div>

        <.intro :if={@console.intro} page={@console.intro} />
        <.palette :if={@console.cmd_open} console={@console} streams={@streams} />
      </div>
    </Layouts.app>
    """
  end

  attr :size, :string, required: true

  defp logo(assigns) do
    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="#5B4B96"
      stroke-width="1.5"
    >
      <path d="M12 13v8"></path>
      <path d="M12 21c-3 0-5-1.5-7-3"></path>
      <path d="M12 21c3 0 5-1.5 7-3"></path>
      <path d="M3.5 10a8.5 5.5 0 0 1 17 0c0 1.6-3.8 2.6-8.5 2.6S3.5 11.6 3.5 10z" fill="#E4DFF3">
      </path>
    </svg>
    """
  end

  defp view_path(universe, :graph), do: ~p"/_/u/#{universe}"
  defp view_path(universe, view), do: ~p"/_/u/#{universe}?#{[view: view]}"

  ## Sidebar

  attr :console, :map, required: true
  attr :streams, :any, required: true
  attr :universe, :string, required: true

  defp sidebar(assigns) do
    ~H"""
    <div
      id="console-sidebar"
      class="w-[230px] flex-none bg-(--k-sand) border-r border-(--k-line) flex flex-col overflow-y-auto"
    >
      <div class="pt-[13px] px-[12px] pb-[6px] text-[10.5px] tracking-[.11em] uppercase text-(--k-faint)">
        Deployments
      </div>
      <div id="sidebar-deployments" phx-update="stream" class="px-[8px] flex flex-col gap-px">
        <.link
          :for={{dom_id, d} <- @streams.console_deployments}
          id={dom_id}
          navigate={~p"/_/d/#{d.name}"}
          class={[row_class(), if(d.on, do: "bg-white " <> on_shadow(d.hue), else: "bg-transparent")]}
        >
          <span class={["w-[6px] h-[6px] rounded-full flex-none", dot(d.hue)]}></span>
          <span class={row_name_class(d.on)}>{d.name}</span>
          <div class="flex-1"></div>
          <span class="text-[10.5px] text-(--k-faint)">{d.tag}</span>
        </.link>
      </div>

      <div class="h-px bg-(--k-line) mt-[13px] mx-[12px]"></div>

      <div class="pt-[13px] px-[12px] pb-[6px] flex items-center">
        <span class="text-[10.5px] tracking-[.11em] uppercase text-(--k-faint)">Environments</span>
        <div class="flex-1"></div>
        <span class="text-[10.5px] text-(--k-faint)">recent</span>
      </div>
      <div class="px-[8px] flex flex-col gap-px">
        <div id="sidebar-envs" phx-update="stream" class="flex flex-col gap-px">
          <.link
            :for={{dom_id, e} <- @streams.console_envs}
            id={dom_id}
            navigate={~p"/_/u/#{e.name}"}
            class={[
              row_class(),
              if(e.on, do: "bg-white " <> on_shadow(e.hue), else: "bg-transparent")
            ]}
          >
            <span class={["w-[6px] h-[6px] rounded-full flex-none", dot(e.hue)]}></span>
            <span class={row_name_class(e.on)}>{e.name}</span>
            <div class="flex-1"></div>
            <span class={["text-[10.5px]", if(e.on, do: tag_on(e.hue), else: "text-(--k-faint)")]}>
              {e.tag}
            </span>
          </.link>
        </div>
        <.link
          id="sidebar-all-envs"
          navigate={~p"/_"}
          class="flex items-center gap-[7px] px-[8px] py-[6px] text-(--k-violet) text-[12px] cursor-pointer hover:text-(--k-violet-hover)"
        >
          <.icon name="ph-list" class="text-[12px]" />
          <span>All {count(@console.universe_count, "environment")}</span>
        </.link>
      </div>

      <div class="h-px bg-(--k-line) m-[13px_12px]"></div>

      <div class="px-[8px] flex flex-col gap-px">
        <.link
          id="nav-system"
          navigate={~p"/_/u/#{@universe}"}
          class={[
            row_class(),
            if(@console.page == :universe, do: "bg-(--k-sel-row)", else: "bg-transparent")
          ]}
        >
          <.icon
            name="ph-graph"
            class={
              "text-[14px] " <>
                if(@console.page == :universe, do: "text-(--k-violet)", else: "text-(--k-faint)")
            }
          />
          <span class={[
            "text-[13px]",
            if(@console.page == :universe,
              do: "font-semibold text-(--k-ink)",
              else: "font-normal text-(--k-body)"
            )
          ]}>
            System
          </span>
          <div class="flex-1"></div>
          <span class="text-[11px] text-(--k-faint)"></span>
        </.link>
      </div>

      <div class="flex-1 min-h-[14px]"></div>

      <div
        id="account-row"
        class="m-[8px] px-[8px] py-[7px] rounded-[8px] flex items-center gap-[9px] bg-transparent hover:bg-[#E5E2D8]"
      >
        <div class="w-[26px] h-[26px] rounded-full flex-none bg-[linear-gradient(135deg,#5B4B96,#0F7A66)]">
        </div>
        <div class="flex flex-col gap-px min-w-0">
          <span class="text-[12.5px] font-medium">mcoll</span>
          <span class="text-[11px] text-(--k-faint)">Workspace, keys, billing</span>
        </div>
        <div class="flex-1"></div>
        <.icon name="ph-caret-up-down" class="text-[12px] text-(--k-faint)" />
      </div>
    </div>
    """
  end

  defp row_class,
    do: "flex items-center gap-[8px] px-[8px] py-[6px] rounded-[6px] cursor-pointer"

  defp row_name_class(true),
    do: "font-(family-name:--k-mono) text-[12px] font-medium text-(--k-ink)"

  defp row_name_class(false),
    do: "font-(family-name:--k-mono) text-[12px] font-normal text-(--k-body)"

  # Literal class names per hue, so Tailwind sees each one.
  defp dot(:violet), do: "bg-(--k-violet)"
  defp dot(:amber), do: "bg-(--k-amber)"
  defp dot(:mint), do: "bg-(--k-mint)"
  defp dot(:grey), do: "bg-[#C7C2B5]"

  defp on_shadow(:violet), do: "shadow-[inset_2px_0_0_#5B4B96,0_1px_2px_rgba(27,26,23,.05)]"
  defp on_shadow(:amber), do: "shadow-[inset_2px_0_0_#A9740B,0_1px_2px_rgba(27,26,23,.05)]"
  defp on_shadow(:mint), do: "shadow-[inset_2px_0_0_#0F7A66,0_1px_2px_rgba(27,26,23,.05)]"
  defp on_shadow(:grey), do: "shadow-[inset_2px_0_0_#C7C2B5,0_1px_2px_rgba(27,26,23,.05)]"

  defp tag_on(:violet), do: "text-(--k-violet)"
  defp tag_on(:amber), do: "text-(--k-amber)"
  defp tag_on(:mint), do: "text-(--k-mint)"
  defp tag_on(:grey), do: "text-[#C7C2B5]"

  ## REPL bar

  attr :console, :map, required: true
  attr :universe, :string, required: true

  defp repl(assigns) do
    ~H"""
    <div id="repl" class="flex-none border-t border-(--k-line) bg-(--k-tint)">
      <div
        :if={@console.repl}
        id="repl-echo"
        class="flex items-center gap-[10px] pt-[5px] px-[14px] pb-[4px] font-(family-name:--k-mono) text-[11.5px] text-(--k-faint)"
      >
        <span class="text-(--k-violet)">›</span>
        <span class="text-(--k-body) whitespace-nowrap overflow-hidden text-ellipsis">
          {@console.repl.expr}
        </span>
        <div class="flex-1 min-w-[8px]"></div>
        <span :if={@console.repl.ok} data-ok class="text-(--k-mint)">{@console.repl.text}</span>
        <span :if={!@console.repl.ok} data-error class="text-(--k-red)">
          {@console.repl.text}
        </span>
      </div>
      <.form
        for={@console.repl_form}
        id="repl-form"
        phx-submit="console:eval"
        class="h-[38px] flex items-center gap-[10px] px-[14px] border-t border-(--k-row-line) bg-white"
      >
        <span class="font-(family-name:--k-mono) text-[13px] text-(--k-violet)">›</span>
        <input
          id="repl-input"
          type="text"
          name={@console.repl_form[:expr].name}
          value={@console.repl_form[:expr].value}
          autocomplete="off"
          spellcheck="false"
          placeholder="Evaluate an expression, or send a Msg…"
          class="flex-1 min-w-0 font-(family-name:--k-mono) text-[12.5px] text-(--k-ink) placeholder:text-(--k-placeholder) whitespace-nowrap overflow-hidden text-ellipsis bg-transparent border-0 p-0 outline-none"
        />
        <span class="text-[11.5px] text-(--k-faint)">sends to</span>
        <span class="font-(family-name:--k-mono) text-[11.5px] text-(--k-body) bg-(--k-paper) border border-(--k-line) px-[7px] py-px rounded-[4px]">
          {@universe}
        </span>
        <span class="font-(family-name:--k-mono) text-[10.5px] text-(--k-faint) border border-(--k-line) rounded-[3px] px-[4px] py-px">
          ⌃↑ history
        </span>
        <span id="repl-history" class="flex cursor-pointer">
          <.icon name="ph-caret-up" class="text-[12px] text-(--k-faint)" />
        </span>
      </.form>
    </div>
    """
  end

  ## ⌘K palette

  attr :console, :map, required: true
  attr :streams, :any, required: true

  defp palette(assigns) do
    ~H"""
    <div
      id="cmd-palette"
      class="fixed inset-0 bg-[rgba(27,26,23,.28)] flex items-start justify-center pt-[14vh]"
    >
      <div
        phx-click-away="console:palette-close"
        class="w-[520px] rounded-[11px] bg-white border border-(--k-line) shadow-[0_20px_50px_rgba(27,26,23,.24)] overflow-hidden"
      >
        <.form
          for={@console.cmd_form}
          id="cmd-form"
          phx-change="console:palette-filter"
          phx-submit="console:palette-go"
          class="flex items-center gap-[10px] px-[15px] py-[13px] border-b border-(--k-line)"
        >
          <.icon name="ph-magnifying-glass" class="text-[15px] text-(--k-faint)" />
          <input
            id="cmd-input"
            type="text"
            name={@console.cmd_form[:q].name}
            value={@console.cmd_form[:q].value}
            phx-mounted={JS.focus()}
            phx-debounce="100"
            autocomplete="off"
            spellcheck="false"
            placeholder="Jump to an app, store, symbol…"
            class="flex-1 min-w-0 text-[14px] text-(--k-ink) placeholder:text-(--k-placeholder) bg-transparent border-0 p-0 outline-none"
          />
        </.form>
        <div id="cmd-items" phx-update="stream" class="p-[7px]">
          <.link
            :for={{dom_id, c} <- @streams.cmd_items}
            id={dom_id}
            navigate={c.href}
            class={[
              "flex items-center gap-[10px] px-[9px] py-[8px] rounded-[7px] cursor-pointer",
              if(c.first, do: "bg-(--k-violet-chip)", else: "bg-transparent")
            ]}
          >
            <span class="w-[16px] flex text-[14px] text-(--k-violet)">
              <.icon name={cmd_icon(c.kind)} />
            </span>
            <span class="font-(family-name:--k-mono) text-[12.5px] text-(--k-ink)">{c.name}</span>
            <div class="flex-1"></div>
            <span class="text-[11.5px] text-(--k-faint)">{cmd_hint(c.kind)}</span>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp cmd_icon(:app), do: "ph-app-window"
  defp cmd_icon(:store), do: "ph-database"
  defp cmd_icon(:symbol), do: "ph-function"
  defp cmd_icon(:deployment), do: "ph-rocket-launch"
  defp cmd_icon(:environment), do: "ph-cube"

  defp cmd_hint(:app), do: "screen"
  defp cmd_hint(:store), do: "store"
  defp cmd_hint(:symbol), do: "symbol"
  defp cmd_hint(:deployment), do: "deployment"
  defp cmd_hint(:environment), do: "environment"

  ## Intro dialog

  attr :page, :integer, required: true

  defp intro(assigns) do
    assigns = assign(assigns, :last, length(intro_pages()) - 1)

    ~H"""
    <div
      id="intro"
      data-page={@page}
      class="fixed inset-0 bg-[rgba(27,26,23,.34)] flex items-center justify-center p-[24px]"
    >
      <div class="w-[640px] max-h-full rounded-[12px] bg-(--k-tint) border border-(--k-line) shadow-[0_24px_60px_rgba(27,26,23,.26)] flex flex-col overflow-hidden">
        <div class="flex-none flex items-center gap-[9px] px-[16px] py-[13px] bg-white border-b border-(--k-line)">
          <.logo size="16" />
          <span class="text-[13px] font-semibold">Welcome to kinoko</span>
          <div class="flex-1 min-w-[8px]"></div>
          <button
            id="intro-skip"
            type="button"
            phx-click="console:intro-close"
            class="flex-none text-[12px] text-(--k-faint) cursor-pointer hover:text-(--k-violet)"
          >
            Skip
          </button>
        </div>

        <.intro_page page={Enum.at(intro_pages(), @page)} />

        <div class="flex-none flex items-center gap-[10px] px-[16px] py-[12px] bg-white border-t border-(--k-line)">
          <div class="flex items-center gap-[5px]">
            <span
              :for={i <- 0..@last}
              id={"intro-dot-#{i}"}
              phx-click="console:intro-page"
              phx-value-page={i}
              class={[
                "h-[6px] rounded-[3px] cursor-pointer",
                if(i == @page, do: "w-[16px] bg-(--k-violet)", else: "w-[6px] bg-(--k-grid-dots)")
              ]}
            >
            </span>
          </div>
          <div class="flex-1 min-w-[8px]"></div>
          <button
            id="intro-back"
            type="button"
            phx-click="console:intro-back"
            class={[
              "h-[30px] px-[12px] rounded-[6px] text-[12.5px] cursor-pointer flex-none whitespace-nowrap border border-(--k-line) bg-(--k-card) text-(--k-body)",
              if(@page == 0, do: "invisible", else: "visible")
            ]}
          >
            Back
          </button>
          <button
            id="intro-next"
            type="button"
            phx-click="console:intro-next"
            class="flex-none whitespace-nowrap h-[30px] px-[14px] rounded-[6px] border border-(--k-violet-btn-border) bg-(--k-violet-chip) text-(--k-violet) text-[12.5px] font-medium cursor-pointer"
          >
            {if(@page == @last, do: "Start exploring", else: "Next")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp intro_pages do
    [
      %{
        kicker: "01 · Environments",
        title: "Try anything, break nothing",
        text:
          "Every environment is its own universe: code, history and staged work. A fork starts from its parent's commit, and nothing it does touches its parent.",
        figure: :environments,
        try_it: "Switch environments in the sidebar."
      },
      %{
        kicker: "02 · The graph",
        title: "See what talks to what, always",
        text:
          "Apps and stores show up here, joined by what they actually do to each other: read and write. It comes from the code, so it is never out of date.",
        figure: :graph,
        try_it: "Click any node to inspect it."
      }
    ]
  end

  attr :page, :map, required: true

  defp intro_page(assigns) do
    ~H"""
    <div class="flex-1 min-h-0 overflow-y-auto pt-[20px] px-[22px] pb-[22px] flex flex-col gap-[14px]">
      <span class="font-(family-name:--k-mono) text-[11px] tracking-[.05em] text-(--k-faint)">
        {@page.kicker}
      </span>
      <span class="font-(family-name:--k-display) text-[23px] font-medium leading-[1.2] max-w-[520px]">
        {@page.title}
      </span>
      <span class="text-[13.5px] leading-[1.65] text-(--k-body) max-w-[560px] [text-wrap:pretty]">
        {@page.text}
      </span>
      <div
        id="intro-figure"
        class="p-[14px] rounded-[10px] bg-(--k-paper) border border-(--k-line) overflow-hidden"
      >
        <.intro_figure figure={@page.figure} />
      </div>
      <div class="flex items-center gap-[7px]">
        <.icon name="ph-cursor-click" class="flex-none text-[13px] text-(--k-faint)" />
        <span class="text-[12.5px] text-(--k-dim)">{@page.try_it}</span>
      </div>
    </div>
    """
  end

  attr :figure, :atom, required: true

  defp intro_figure(%{figure: :environments} = assigns) do
    ~H"""
    <div class="flex flex-col gap-[8px]">
      <div class="p-[6px] rounded-[9px] bg-(--k-sand) border border-(--k-line) flex flex-col gap-px">
        <.env_row name="main" tag="base" on />
        <.env_row name="fix-rounding" tag="fork of main" />
        <.env_row name="shares-v2" tag="fork of main" />
      </div>
      <div class="flex gap-[7px]">
        <.chip class="text-(--k-violet) bg-(--k-violet-chip) border-(--k-violet-chip-border)">
          own history
        </.chip>
        <.chip class="text-(--k-dim) bg-(--k-card) border-(--k-line)">
          starts at its parent's commit
        </.chip>
      </div>
    </div>
    """
  end

  # The prototype's third node is a workflow; workflows are hidden in v1,
  # so the figure stops at the store.
  defp intro_figure(%{figure: :graph} = assigns) do
    ~H"""
    <div class="flex items-center gap-[6px]">
      <.mini icon="ph-app-window" name="Split" kind="app" meta="2 screens · 4 msgs" />
      <.arrow label="writes" />
      <.mini icon="ph-database" name="Split.Expense" kind="store" meta="5 rows" />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :tag, :string, required: true
  attr :on, :boolean, default: false

  defp env_row(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-[8px] px-[9px] py-[6px] rounded-[6px]",
      if(@on,
        do: "bg-(--k-card) shadow-[inset_2px_0_0_#5B4B96,0_1px_2px_rgba(27,26,23,.05)]",
        else: "bg-transparent shadow-none"
      )
    ]}>
      <span class={[
        "w-[6px] h-[6px] rounded-full flex-none",
        if(@on, do: "bg-(--k-violet)", else: "bg-[#C7C2B5]")
      ]}>
      </span>
      <span class={[
        "font-(family-name:--k-mono) text-[12px]",
        if(@on, do: "font-medium", else: "font-normal")
      ]}>
        {@name}
      </span>
      <div class="flex-1 min-w-[8px]"></div>
      <span class="flex-none text-[10.5px] text-(--k-faint) whitespace-nowrap">{@tag}</span>
    </div>
    """
  end

  attr :class, :string, required: true
  slot :inner_block, required: true

  defp chip(assigns) do
    ~H"""
    <span class={[
      "flex-none whitespace-nowrap text-[11.5px] border px-[8px] py-[2px] rounded-[5px]",
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :icon, :string, required: true
  attr :name, :string, required: true
  attr :kind, :string, required: true
  attr :meta, :string, required: true

  defp mini(assigns) do
    ~H"""
    <div class="w-[146px] flex-none rounded-[8px] bg-(--k-card) border border-(--k-line) overflow-hidden">
      <div class="flex items-center gap-[7px] px-[9px] py-[6px] bg-(--k-tint) border-b border-(--k-line)">
        <.icon name={@icon} class="flex-none text-[12px] text-(--k-violet)" />
        <span class="font-(family-name:--k-mono) text-[11.5px] font-medium whitespace-nowrap">
          {@name}
        </span>
      </div>
      <div class="px-[9px] py-[7px] flex flex-col gap-[3px]">
        <span class="text-[10px] tracking-[.07em] uppercase text-(--k-faint)">{@kind}</span>
        <span class="text-[11px] text-(--k-dim) whitespace-nowrap overflow-hidden text-ellipsis">
          {@meta}
        </span>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true

  defp arrow(assigns) do
    ~H"""
    <div class="flex-none min-w-[34px] flex flex-col items-stretch gap-[4px]">
      <span class="text-[10px] text-(--k-violet) whitespace-nowrap text-center">{@label}</span>
      <span class="w-full border-t-[1.5px] border-solid border-(--k-violet)"></span>
    </div>
    """
  end

  ## Stage helpers

  @doc """
  The tag a universe carries (IMPLEMENTATION-MAP §1): `base` with no
  parent, `fork of <parent>` otherwise.
  """
  @spec universe_tag(map()) :: String.t()
  def universe_tag(%{parent: nil}), do: "base"
  def universe_tag(%{parent: parent}), do: "fork of " <> parent

  @doc "`count(2, \"app\")` is `\"2 apps\"`, `count(1, \"app\")` `\"1 app\"`."
  @spec count(non_neg_integer(), String.t()) :: String.t()
  def count(1, noun), do: "1 " <> noun
  def count(n, noun), do: "#{n} #{noun}s"

  @doc """
  A scrolling stage page in the prototype's `deploymentStage` frame
  (paper, 20/24/40 padding, 860px column, 22px gap).
  """
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def page(assigns) do
    ~H"""
    <div class="flex-1 min-w-0 overflow-y-auto pt-[20px] px-[24px] pb-[40px] bg-(--k-paper)">
      <div id={@id} class="max-w-[860px] flex flex-col gap-[22px]">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc "The prototype's `sect`: a Newsreader 16/500 label over its content, 9px apart."
  attr :title, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-[9px]">
      <div class="flex items-baseline gap-[10px]">
        <span class="font-(family-name:--k-display) text-[16px] font-medium">{@title}</span>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The prototype's table card: white, 1px line, 9px radius."
  def table_class, do: "rounded-[9px] bg-(--k-card) border border-(--k-line) overflow-hidden"

  @doc "A row of a table card: 12.5px cells, a #EFECE4 rule between rows."
  def row_rule_class,
    do:
      "flex items-baseline gap-[10px] px-[12px] py-[9px] text-[12.5px] border-t border-(--k-row-line-2) first:border-t-0"

  @doc "The empty state of a table card, in its row style."
  def empty_class, do: "hidden only:block px-[12px] py-[9px] text-[12.5px] text-(--k-dim)"

  @doc "A route entry's pattern, `/post/:id`."
  @spec pattern(map()) :: String.t()
  def pattern(%{segments: segments}), do: Graph.pattern(segments)

  @doc "The entry's path when it has no params (a link target), else `nil`."
  @spec static_path(map()) :: String.t() | nil
  def static_path(%{segments: segments}) do
    if Enum.all?(segments, &match?({:lit, _}, &1)) do
      case segments do
        [] -> "/"
        _ -> "/" <> Enum.map_join(segments, "/", fn {:lit, s} -> URI.encode(s) end)
      end
    end
  end

  @doc "`http://host:port` for a served host, at the endpoint's HTTP port."
  @spec host_url(String.t()) :: String.t()
  def host_url(host) do
    case KinokoWeb.Endpoint.config(:http) |> port() do
      nil -> "http://#{host}"
      80 -> "http://#{host}"
      port -> "http://#{host}:#{port}"
    end
  end

  defp port(http) when is_list(http), do: Keyword.get(http, :port)
  defp port(_), do: nil

  @doc "A reason's `code` and `message` as one line."
  def reason_text(%{message: m}), do: m
  def reason_text(other), do: inspect(other)
end
