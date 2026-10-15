defmodule KinokoWeb.Console.Components do
  @moduledoc """
  The console's shared chrome and small helpers: a page shell with a
  breadcrumb header, badges, and the route-table / URL formatting the three
  console LiveViews share. Plain function components; nothing here touches
  a universe.
  """

  use KinokoWeb, :html

  @doc "`/_/...`'s page shell: brand header, breadcrumbs, content slot."
  attr :flash, :map, required: true
  attr :crumbs, :list, default: [], doc: "`[{label, path}]`; the last is the current page"
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <Layouts.app flash={@flash} bare>
      <div class="min-h-screen bg-zinc-50 text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">
        <header class="sticky top-0 z-10 border-b border-zinc-200/80 bg-white/80 backdrop-blur dark:border-zinc-800 dark:bg-zinc-950/80">
          <nav
            id="console-nav"
            class="mx-auto flex max-w-6xl items-center gap-2 px-4 py-3 text-sm sm:px-6"
          >
            <.link
              navigate="/_"
              class="group flex items-center gap-2 font-semibold tracking-tight transition"
            >
              <span class="grid size-7 place-items-center rounded-lg bg-gradient-to-br from-rose-500 to-orange-400 text-white shadow-sm transition group-hover:rotate-6">
                <.icon name="hero-command-line" class="size-4" />
              </span>
              <span>kinoko</span>
              <span class="text-zinc-400 dark:text-zinc-500">console</span>
            </.link>
            <%= for {label, path} <- @crumbs do %>
              <.icon name="hero-chevron-right" class="size-3.5 text-zinc-300 dark:text-zinc-600" />
              <%= if path do %>
                <.link
                  navigate={path}
                  class="text-zinc-500 transition hover:text-zinc-900 dark:hover:text-white"
                >
                  {label}
                </.link>
              <% else %>
                <span class="font-medium">{label}</span>
              <% end %>
            <% end %>
          </nav>
        </header>
        <main class="mx-auto max-w-6xl space-y-8 px-4 py-8 sm:px-6">
          {render_slot(@inner_block)}
        </main>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :count, :integer, default: nil
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section id={@id} class="space-y-3">
      <h2 class="flex items-baseline gap-2 text-xs font-semibold uppercase tracking-wider text-zinc-500">
        {@title}
        <span :if={@count} class="rounded-full bg-zinc-200 px-2 py-0.5 text-[10px] dark:bg-zinc-800">
          {@count}
        </span>
      </h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :tone, :atom, default: :neutral, values: [:neutral, :ok, :warn, :info]
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset",
        @tone == :neutral &&
          "bg-zinc-100 text-zinc-600 ring-zinc-200 dark:bg-zinc-800 dark:text-zinc-300 dark:ring-zinc-700",
        @tone == :ok &&
          "bg-emerald-50 text-emerald-700 ring-emerald-200 dark:bg-emerald-950 dark:text-emerald-300 dark:ring-emerald-900",
        @tone == :warn &&
          "bg-amber-50 text-amber-800 ring-amber-200 dark:bg-amber-950 dark:text-amber-300 dark:ring-amber-900",
        @tone == :info &&
          "bg-sky-50 text-sky-700 ring-sky-200 dark:bg-sky-950 dark:text-sky-300 dark:ring-sky-900"
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc "The card look shared by every list row and panel."
  def card_class,
    do:
      "rounded-xl border border-zinc-200 bg-white shadow-sm transition dark:border-zinc-800 dark:bg-zinc-900"

  def link_class,
    do:
      "font-medium text-zinc-900 underline decoration-zinc-300 underline-offset-4 transition hover:decoration-rose-500 dark:text-zinc-100 dark:decoration-zinc-600"

  @doc "A route entry's pattern, `/post/:id`."
  @spec pattern(map()) :: String.t()
  def pattern(%{segments: []}), do: "/"

  def pattern(%{segments: segments}) do
    Enum.map_join(segments, fn
      {:lit, s} -> "/" <> s
      {:param, n} -> "/:" <> n
    end)
  end

  @doc "The entry's path when it has no params (a link target), else `nil`."
  @spec static_path(map()) :: String.t() | nil
  def static_path(%{segments: segments} = entry) do
    if Enum.all?(segments, &match?({:lit, _}, &1)) do
      case segments do
        [] -> "/"
        _ -> "/" <> Enum.map_join(segments, "/", fn {:lit, s} -> URI.encode(s) end)
      end
    else
      _ = entry
      nil
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
