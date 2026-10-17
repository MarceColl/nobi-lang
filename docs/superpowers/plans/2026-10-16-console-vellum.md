# Console "Vellum" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the `/_` console with a LiveView port of the Claude Design prototype "Nobi Vellum". It covers the shell, Home, the System graph, Code, Data browsing, the Deployment page, the ⌘K palette and the intro dialog, all backed by real universes and deployments.

**Spec:**
- `docs/design/nobi-vellum/Kinoko Vellum.dc.html`, the **pixel spec**. Port its inline styles value by value. Do not interpret them.
- `docs/design/nobi-vellum/IMPLEMENTATION-MAP.md`, the concept mapping, v1 scope, degrade rules, tokens and routes. It is binding.

**Decisions (Marce, 2026-10-16):**
- Pages with no backing data are **hidden**: Proposals, Decisions, Traces, Workflows, Crons, Queues, Settings, Try it and the review panel.
- **Vendor** the fonts (Chivo, IBM Plex Mono, Newsreader woff2, OFL) and the Phosphor regular icons (MIT) as a Tailwind `ph-*` plugin.
- Build **`Universe.graph/1`** for the read/write edges.

## Global Constraints

- **The prototype is a pixel spec.**
  - Every px, hex, weight, gap and radius comes from the prototype file. Use Tailwind arbitrary values (`text-[12.5px]`, `bg-(--k-paper)`), with the tokens as CSS custom properties defined in `app.css`.
  - Remove the current console chrome entirely: the rose/zinc palette, `rounded-xl shadow-sm` cards and every `dark:` variant on console pages. The console is light only.
- **Fonts and icons:**
  - Icons always go through `<.icon name="ph-…">`, using the same mechanism as `hero-*` (a Tailwind plugin over vendored SVGs).
  - No external `<link>`/`<script>` in layouts. Fonts are served from `priv/static/fonts` through `@font-face` in `app.css`.
- **`Nobi.Universe` is the only interface to universes.** `Nobi.Lang` stays pure.
- **Page scope:** no page, nav entry, button or figure for a hidden feature. Degrade states follow the IMPLEMENTATION-MAP §3 exactly, and every degrade element is styled after a prototype element.
- **LiveView rules from AGENTS.md:**
  - `<Layouts.app flash={@flash} …>` wraps every page;
  - streams for collections;
  - `<.link navigate/patch>`;
  - no inline `<script>`;
  - hooks live in `assets/js` and are registered in `app.js`, and a hook that owns DOM gets `phx-update="ignore"`;
  - unique DOM ids on key elements, and tests assert by id.
- **Hands off:**
  - Don't touch Marce's dev server on :4000; use another port for screenshots, such as `PORT=4123`.
  - Never create or edit README files.
- **Process:**
  - VCS is jj: `jj commit -m "…"`. Never `git commit` or `git stash`.
  - `mix precommit` is green after every task.
  - DB-writing tests are not `async: true`.

## Review Focus

1. **Fidelity.** The rendered values match the prototype: top bar 46px, sidebar 230px in `#EDEBE4`, title bar 42px in `#F7F6F2`, inspector 326px, REPL input 38px, Chivo/Plex Mono/Newsreader actually loaded, the canvas dot grid at 26px. *Tasks 3–6, measured in Task 7.*
2. **No invented UI.** Each element traces to a prototype element or to a §3 degrade rule. *All UI tasks.*
3. **Graph edges are correct.** Writes come from insert/update/delete/tx, reads from list/get and `Store.*`, attributed through transitive calls. A helper called by two apps attributes to both. *Task 2.*
4. **Pan/zoom survives LiveView patches.** A commit arriving while the view is zoomed keeps the camera. *Task 4.*

---

### Task 1: Assets: fonts, Phosphor icons, tokens

**Files:**
- `assets/vendor/phosphor/` (regular SVGs, plus its LICENSE)
- `assets/vendor/phosphor.js`, a Tailwind plugin modelled on `assets/vendor/heroicons.js`, giving `ph-<name>` classes as masked SVGs
- `priv/static/fonts/*.woff2` (plus OFL license files)
- `assets/css/app.css`: `@font-face`, the `@plugin "../vendor/phosphor"` line and the `:root` tokens
- `lib/nobi_web/components/core_components.ex`: `icon/1` accepts `ph-` names

**Sources** (Marce approved downloading them):
- Phosphor: npm `@phosphor-icons/core` 2.1.1, `assets/regular/*.svg`. Vendor only the regular weight.
- Fonts: Google Fonts css2 API.
  - Chivo 400/500/600/700, IBM Plex Mono 400/500, Newsreader 400/500 with the `opsz` axis.
  - Latin subset is enough.
  - Fetch the CSS with a modern Chrome User-Agent to get woff2, then download each woff2 URL it lists.

**Tokens:** define every colour from IMPLEMENTATION-MAP §5 as `--k-<name>` on `:root`, and the families as `--k-sans` (Chivo, system-ui, sans-serif), `--k-mono` ('IBM Plex Mono', monospace) and `--k-display` (Newsreader, Georgia, serif).

- [ ] **Failing test first:** `<.icon name="ph-graph" class="…"/>` renders a span with class `ph-graph`.
- [ ] **Check:** `mix assets.build`; the built `app.css` contains `.ph-graph` and the three `@font-face` families, and `priv/static/fonts` holds the woff2 files.
- [ ] **Run** `mix precommit`, then `jj commit -m "feat(console): vendor Vellum fonts, Phosphor icons, tokens"`.

### Task 2: `Universe.graph/1`

**Files:** a pure analysis in `lib/nobi/lang/` (for example `lang/graph.ex`), an entry through `lib/nobi/lang/universe.ex` if needed, the CodeDb read request, and `lib/nobi/universe.ex`. Tests: `test/nobi/universe_graph_test.exs`.

**Interface:**

```elixir
Universe.graph(universe_or_at) ::
  %{apps: [%{symbol, routes: [pattern_string]}],
    stores: [%{symbol, fields: [String.t()]}],         # stored models (have id : Uuid), field names in order
    edges: [%{from: app_symbol, to: model_symbol, kind: :reads | :writes}]}  # deduped, sorted
  | error
```

**Rules:**
- `writes` comes from `Cmd.store.insert/update/delete/tx` and `Tx.insert/update/delete`; `reads` from `Cmd.store.list/get` and `Store.get/list`.
- The model is the one the typechecker resolved; codegen already records it for store effects, so reuse that.
- **Attribution:** an app reaches every symbol its `init`/`update`/`view` (and their transitive `def` callees) reference. An effect inside a helper is attributed to every app that reaches it.
- A `tx` body's `Store.get` counts as `reads`, its `Tx.*` ops as `writes`, and `tx` itself as `writes`.
- The result is cached per image hash. Follow how `routes/1` and `apps/1` do it; the computation runs in the caller, not the CodeDb.

- [ ] **Failing tests:**
  - an app inserting into M gives `writes`;
  - an app listing M gives `reads`;
  - a helper shared by two apps attributes to both;
  - a `tx` with `Store.get` plus `Tx.update` gives both edges;
  - `At` (a pinned commit) works;
  - an empty universe gives empty lists;
  - a degraded universe returns the `"degraded"` error.
- [ ] **Run** `mix precommit`, then `jj commit -m "feat: Universe.graph/1 — apps, stores, read/write edges"`.

### Task 3: Console shell, palette, intro, Home

**Files:**
- `lib/nobi_web/live/console/components.ex`: rewrite `shell` as the prototype frame. It contains:
  - the top bar (logo SVG copied verbatim from the prototype, crumbs, "Jump to…" box, `?` button);
  - the sidebar: Deployments, Environments ("recent" = all universes, capped at 5, then `All N environments`), the nav (System only in v1), and the account row (visual only: `mcoll` / "Workspace, keys, billing"; Settings is hidden, so it is not clickable);
  - the title bar (views segmented control, title and subtitle, the sandbox chip, the commit id);
  - the REPL bar (the two strips at the bottom).
- `lib/nobi_web/live/console/index_live.ex`: Home, ported from `homeStage()`.
  - Environment cards are universes. The icon is `ph-cube` for a universe with no parent (tint `#EDE8F8`) and `ph-git-fork` for a fork (tint `#FBF2DF`).
  - Deployment cards use `ph-rocket-launch`: mint for a deployment following head, faint for a pinned one. The meta line is `<universe> · following head` or `pinned @ #n`.
- ⌘K palette and intro dialog markup in the shell. The intro has pages 01 Environments and 02 Graph only, with their figures ported as markup.
- `assets/js/console.js`, imported from `app.js`, holds the hook `ConsoleKeys`: ⌘K/Ctrl-K toggles the palette, Esc closes it. Palette items are server-rendered:
  - apps (`ph-app-window`, hint `screen`);
  - stores (`ph-database`, hint `store`);
  - symbols (`ph-function`, hint `symbol`), first 50;
  - deployments (`ph-rocket-launch`);
  - environments (`ph-cube`).

  It filters as you type (a `phx-change` input replacing the placeholder span; same 14px style).
- **REPL bar:** a form submitting to `Universe.eval/3` on the current universe. The echo strip shows the expression and either `ok · <inspect result, truncated>` (mint) or the reason (red `#C0453F`). The strip is hidden before the first eval.

**Rules:**
- Every console LiveView uses the new shell.
- The current universe comes from the route; on Home and Deployment pages it is the session's last visited universe (default `"main"`).
- Remove `card_class/0` and `badge/1` once unused.

- [ ] **Failing tests** (LiveViewTest, ids):
  - `#console-topbar`, `#console-sidebar`, `#sidebar-deployments`, `#sidebar-envs`, `#console-titlebar`, `#repl-form`;
  - palette open/close via `#cmd-palette` and filtering;
  - intro open via `#intro-open`, next/back and close;
  - Home lists `#env-<name>` and `#dep-<name>` cards linking correctly;
  - the REPL evaluates `1 + 2` and shows `#repl-echo`;
  - no hidden-feature nav ids exist (`#nav-proposals`, `#nav-traces` and so on are absent).
- [ ] **Run** `mix precommit`, then `jj commit -m "feat(console): Vellum shell, palette, intro, home"`.

### Task 4: System graph + inspector

**Files:** `lib/nobi_web/live/console/universe_live.ex` (stage `graph`, the default view), `assets/js/console.js` (`GraphCamera` hook), and its tests.

- **Layout:** computed server-side from `Universe.graph/1`, with no JS layout library.
  - App cards: 264 wide, at left 38, stacked top 30 with a 58 gap. Header 29px, the mint dot, the app name and its first route.
  - Body: up to 3 store field placeholders, each a 24px box with the field name, as in the prototype's form preview. If the app writes no store, use the route list instead.
  - Store nodes sit in a row below the apps: top = the last app bottom + 58, widths from the prototype (214/196, scaled by name length, min 196), gap 68.
  - The rows label is `N rows` from `Data.stats` of the first deployment serving this universe, or `no data` (§3).
  - Edges are SVG paths with the prototype's markers. `writes` is violet, 1.6 wide; `reads` is `#9C978A`, 1.4. Use orthogonal routing like the prototype's `M x y V y2` and `C` curves.
- **Selection:** clicking a node patches `?sel=<symbol>` and opens the 326px inspector, ported from `panelFor()`.
  - **App:** rows are route(s), `model` (`<App>.Model · N fields`, if it exists), `data` ("inserts into X · reads Y" from edges), and `serving` (deployments). Extras: none, because the live model and traces are hidden.
  - **Store:** rows are `fields`, `written by`, `read by` and `layer` (the deployment name, or "no data"). The extra is "Rows" with "Open in Data", listing the first 4 rows.
  - The panel's ×, and a click on empty canvas, clear the selection.
  - The hint "Click a node to inspect it. Drag the canvas to pan, ⌘-scroll to zoom." shows when nothing is selected.
- **Camera:** the `GraphCamera` hook ports `fit`, `zoomBy`, drag-pan (4px threshold) and wheel/⌘-wheel from the prototype.
  - The world div's transform is owned by the hook, which reapplies it on `updated()` so patches keep the camera.
  - The zoom strip (−, %, +, fit) and the legend (writes/reads) are ported verbatim.
  - The fit gutter is 28 with no selection and 354 with one.
- **Empty universe:** the §3 empty state.
- **Live refresh:** a `{:committed, …}` message reloads the graph.

- [ ] **Failing tests:**
  - nodes `#node-<sanitized symbol>` for apps and stores;
  - edges `[data-edge="App->Model:writes"]`;
  - selecting opens `#inspector`, and × closes it;
  - the empty universe state `#graph-empty`;
  - a commit adds a node.
- [ ] **Run** `mix precommit`, then `jj commit -m "feat(console): system graph with inspector and camera"`.

### Task 5: Code and Data stages

**Files:** `universe_live.ex` (`?view=code&sym=` and `?view=data&store=`) and tests.

- **Code** (port of `codeStage()`):
  - Symbols panel (212px): grouped by namespace prefix (the first segment), as the prototype's "Split" group label. Committed symbols get a mint dot; staged patches get amber `STAGED` with the patch id.
  - Header: `<symbol>`, then the `typechecks` chip, or for staged the amber chip `staged · <first reason message, truncated>`, then `sha256 <cid8>`.
  - Source: `Universe.read/2` with line numbers. Keyword highlight in violet covers only the leading `def`/`defmodel`/`deftype`/`defapp`/`defroutes`/`deftest` and the trailing `do`, as in the prototype; no other syntax colouring.
  - Footer: the prototype's text "Every symbol is content-addressed; a body edit with the same signature invalidates nothing." and a "Show on the graph" button patching to `?view=graph&sel=<symbol>` when the symbol is a node, else to the graph.
  - Staged reasons are listed below the source in the prototype's red callout style (the `#FBECEB` box from tracesStage).
- **Data** (port of `dataStage()`):
  - A store `<select>` (`Model  ·  N rows`).
  - The right note reads `deployment <name>`, not "own layer…".
  - The table: columns are the model fields, with `id` first in faint mono, Int right-aligned in mono, and zebra rows. Rows come from `Data.list` with the current image's signature, newest first, capped at 200 with a footer "N rows · showing 200".
  - The footer row reads `N rows · written by <apps from graph edges>`. There is no total column.
  - Omit "Insert a row" and the whole Query panel; the query language is the next piece.
  - With no deployment, the §3 empty state.
  - A deployment selector appears only when more than one deployment serves the universe; it is a second `<select>` with the same style.

- [ ] **Failing tests:**
  - the symbols list `#sym-<id>`;
  - selecting shows `#source` with line numbers;
  - staged shows `#staged-reasons`;
  - the data table `#data-table` rows match the inserted rows;
  - the store switch;
  - the no-deployment empty state `#data-empty`.
- [ ] **Run** `mix precommit`, then `jj commit -m "feat(console): code and data stages"`.

### Task 6: Deployment page

**Files:** `lib/nobi_web/live/console/deployment_live.ex` and tests. It ports `deploymentStage()` within the §3 limits.

- **Header:**
  - the name (Newsreader 25), with the chip `following head` (mint) or `pinned` (sand);
  - the URL in violet mono, being the first host `host_url`;
  - the line `serving <universe> · commit #n`;
  - buttons: Open (an external link to the URL) and `Promote <universe>`. Promote is shown only when pinned and calls `Deployment.follow/1`.
- **Callout:** the violet promote callout, only when pinned and head is ahead: "`<universe>` is N commits ahead of this deployment", with the sub-line listing up to 3 promoted patch ids. Omit the "See the diff" link (piece 6).
- **Deployed versions:** history rounds newest first, with columns version `#n`, patches, symbols changed (`+3 −1`), and the right-hand action.
  - The current row has the `#FAFAF7` background and mint "current".
  - Other rows get violet "roll back", which pins to that commit; on the head row while pinned it reads "follow head".
  - Errors column omitted.
- **Routes:** the prototype's `table()` style, with columns route (mono), app (mono, dim) and an open link for parameter-free paths.
- **Stored models:** the `table()` style, with columns model, rows (right, mono) and columns (faint mono list).

- [ ] **Failing tests:**
  - `#dep-header`, `#dep-versions`;
  - roll back pins: `Deployment.get` shows the commit and the row becomes current;
  - follow head;
  - `#dep-routes`, `#dep-models`;
  - the promote callout `#dep-promote` only when pinned behind head.
- [ ] **Run** `mix precommit`, then `jj commit -m "feat(console): deployment page"`.

### Task 7: Fidelity pass (render + measure)

**Files:**
- `test/nobi_web/console_fidelity_test.exs`: static contracts on rendered classes and ids. Examples: the shell has the 46px top bar class `h-[46px]`, the sidebar `w-[230px] bg-(--k-sand)`, no `rounded-xl`, no `dark:` and no `rose-`.
- A scratch harness under `.superpowers/` (not committed):
  - seed a "Ski trip"-shaped universe (app `Split` with route `/split`; stored `Split.Expense` (payer, what, cents) with 5 rows of the prototype's EXPENSES, and `Split.Share` with 3 rows) and a deployment `production`;
  - serve on PORT=4123;
  - screenshot Home, the Graph (with `Split` selected), Code (`Split.update`), Data and Deployment with headless Chrome at 1440×900, using `node` plus `puppeteer-core` against `/Applications/Google Chrome.app`, or `chrome --headless --screenshot`;
  - take the same shots of the prototype itself, `Kinoko Vellum.dc.html` opened from file with network access for its CDN scripts. If that cannot render offline, screenshot only the implementation.
  - assert computed styles through puppeteer: font-family resolution (`document.fonts.check`), the key heights and widths, and the colours in Review Focus 1.

**Output:** the screenshots and a mismatch list at `.superpowers/sdd/<plan>/fidelity/`. Fix the mismatches in this task, and pin the corrected values in the fidelity test.

- [ ] **Run** `mix precommit`, then `jj commit -m "test(console): Vellum fidelity contracts"`.
