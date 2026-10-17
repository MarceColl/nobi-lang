# Nobi Vellum → LiveView: implementation map

The prototype, `Kinoko Vellum.dc.html`, is a **pixel spec**: every size, colour, weight and gap in it is a decision already made. Port it value by value. It replaces the current console chrome under `/_`: the rose/zinc shell, the cards and the dark variants all go. `support.js` is only the dc-runtime the prototype needs to render. It is not part of the design.

Open the prototype at 1440×900 (its `$preview`).

## 1. Concept mapping

| Prototype | Nobi-on-BEAM today |
|---|---|
| Project ("Ski trip") | No such concept; there is one workspace. The breadcrumb root reads **`nobi`**, and the home page title is **"Workspace"**. |
| Environment (`main`, `fix-rounding`, …) | **Universe.** A fork is a universe with a `parent`. The tag reads `base` when it has no parent and `fork of <parent>` otherwise. |
| Deployment (`production`, `preview`) | **`Nobi.Deployment`**: name, universe, route table, and pinned commit or following head. |
| Module hash in the title bar (`98ac5a18`) | The head commit: the history length, plus the first 8 hex of the image hash if exposed, otherwise `#<n>`. |
| `blake3 6f2a91c4` (Code) | The symbol's **CID**, first 8 hex, written as `sha256 6f2a91c4`. |
| Screen node (Split) | An **app** (`signature: "app"`), plus its routes from `Universe.routes/1`. |
| Store node (Split.Expense) | A **stored model** (a defmodel with `id : Uuid`). The row count comes from `Data.stats/1` of the selected deployment, if one serves the universe. |
| Staged symbol | **Staged patch** (`Universe.staged/1`), with its reasons. |
| Versions ("v7 · 98ac5a18") | **History rounds.** "roll back" is `Deployment.pin(name, commit)`, and "current" is the pinned or head commit. |
| "Promote main" | `Deployment.follow/1` when the deployment is pinned. Hidden while it already follows head. |
| REPL bar ("Evaluate an expression…") | `Universe.eval/3` on the current universe. The output line shows the result or the reason. |

## 2. Screens: what renders now, what waits

| Screen | v1 | Real data | Waits on |
|---|---|---|---|
| Shell: top bar, sidebar, title bar, REPL bar | ✅ | universes, deployments, nav counts | |
| Home | ✅ | universe cards (symbols · apps · stores), deployment cards | request counts (the meta line becomes `universe · following head` or `pinned @ #n`) |
| System graph | ✅ | apps, stored models, edges | **read/write edges need a new `Universe.graph/1`** (see §4) |
| Code | ✅ | symbols, canonical text (`Universe.read/2`), staged plus reasons, CID | "typechecks · 4ms" timing, so show `typechecks` alone |
| Data | ✅ (browse) | `Data.stats` plus rows (`Data.list` through the image signature) | Query editor: next piece (query language). "Insert a row": later. |
| Deployment | ✅ | header, URL, serving universe and commit, promote/follow, versions table with roll back (pin) | metrics, per-app usage, capabilities, fork from deployment (piece 6) |
| ⌘K palette | ✅ | apps, models, symbols, deployments, universes | traces, proposals |
| Intro dialog (?) | ✅ | static copy, **Environments** and **Graph** pages only | Traces and Proposals pages |
| First-run tour | ❌ | | prototype state only; it has no markup in the template |
| Proposals, Decisions | ❌ hidden | | piece 6 (fork/merge) |
| Traces | ❌ hidden | | trace capture |
| Workflows, Crons, Queues | ❌ hidden | | these don't exist in Nobi |
| Keys & settings | ❌ | | users/auth (deferred). The account row stays visual only. |
| Try it, review panel | ❌ | | piece 6 |
| Inspector panel (graph selection) | ✅ | app: routes, model fields, serving deployments; store: fields, rows (first 4), read/written by | live model, traces |

## 3. Degrade rules (every one derived from prototype elements)

- **A nav entry whose feature doesn't exist yet** is not rendered. The prototype has no disabled-nav style, so none is invented. The "Changes" group label goes with its entries.
- **Sidebar "All 12 environments"** → `All N environments` links to Home. **"Fork main"** stays hidden until piece 6.
- **A store with no serving deployment** (no data file): the node meta shows `no data` in place of `5 rows` (same style, `#6E6A61` 10.5px). Data stage: `listStage` empty state, Newsreader 18/500 title "No data yet" plus 13px dim body "Rows live in a deployment. Serve this universe to start storing."
- **An empty universe:** graph stage empty state, `listStage` style: "Nothing committed" / "Stage a patch through the MCP or the REPL below."
- **Badges with no number** (System): blank, as in the prototype.
- **The "sandboxed · no egress" chip** stays: it is true on BEAM (no network effect exists).
- **Deployment metrics row, per-app usage, capabilities card:** not rendered. The page is header, promote callout (only when pinned and head is ahead: "head is N commits ahead of this deployment"), then Deployed versions, then the hosts and routes table in the `table()` style.
- **REPL echo line** (the strip above the input): hidden until the first eval in the session.

## 4. New backend (small, read-only)

- `Universe.graph(u) :: %{apps: [...], stores: [...], edges: [%{from, to, kind: :reads | :writes}]}`.
  - `writes` comes from `Cmd.store.insert/update/delete/tx` and `Tx.*`; `reads` from `Cmd.store.list/get` and `Store.get/list`. Both are attributed to the app whose `init/update/view` transitively reaches the call.
  - Computed from typed ASTs inside `Nobi.Lang`, which stays pure, and cached per image hash.
- Graph layout is computed server-side, with no JS layout library:
  - apps in a left column (prototype app card width 264);
  - stores in a row below (widths 214/196 in the prototype; computed per name);
  - `writes` edges in violet with markers, as in the prototype; `reads` edges in `#9C978A`.
- Pan/zoom is a `GraphCamera` JS hook on the canvas, with `phx-update="ignore"` on the world wrapper only for the transform. It ports `fit` (with the same gutter rule), `zoomBy`, drag-pan and ⌘-scroll. The zoom strip at the bottom talks to the hook.

## 5. Tokens (prototype `P` → CSS custom properties in `app.css`, `@theme`)

| token | hex | | token | hex |
|---|---|---|---|---|
| ink | #1B1A17 | | violet | #5B4B96 (hover #48397C) |
| body | #3A362E | | mint | #0F7A66 |
| dim | #6E6A61 | | amber | #A9740B |
| faint | #8A8579 | | red | #C0453F |
| line | #DDDAD1 | | placeholder | #B6B1A5 |
| paper | #F2F1EC | | row line | #EAE7DE / #EFECE4 |
| card | #FFFFFF | | sel row | #E2DFD5 |
| tint | #F7F6F2 | | segmented bg | #E7E4DB |
| sand | #EDEBE4 | | grid dots | #D7D3C8 |

Accent fills:
- violet chip: `#F3F0FB` / border `#C9C0E4` (button) or `#D9D2EE` (chip);
- mint chip: `#E3F1EC` / `#BFDDD3`;
- amber: `#FBF2DF` / `#E8D3A4`, text `#7A5406`;
- red: `#FBECEB` / `#EFCFCD`, text `#8E332E`.

Radii are 3/4/5/6/7/8/9/10/11/12px, used exactly as in the prototype.

Typography:
- **Chivo** 400/500/600/700 is the UI face;
- **IBM Plex Mono** 400/500 is for names, code and numbers;
- **Newsreader** 500 (opsz 6..72) is the display face (page titles 21/25px, empty states 18px).

Sizes are fractional px exactly as written (12.5, 11.5, 10.5); use Tailwind arbitrary values `text-[12.5px]`. The section label is 10.5px, `tracking-[.11em]`, uppercase, faint.

Light only. The prototype has no dark mode, so the console drops its `dark:` variants.

## 6. Fonts and icons (asset decisions)

- **Fonts:** vendor the woff2 files (OFL) into `priv/static/fonts/` with `@font-face` in `app.css`. Layouts may not link Google Fonts (AGENTS.md).
- **Icons:** the prototype uses Phosphor (regular). AGENTS.md requires `<.icon>`. Vendor the Phosphor regular SVGs (MIT) as a Tailwind plugin that yields `ph-*` classes, the same mechanism as `hero-*`, so `<.icon name="ph-graph" />` works and matches the design exactly.

## 7. Routes

- `/_` is Home.
- `/_/u/:universe` is the System graph; `?view=code|data` switches the stage, and `&sel=` picks the inspector selection; patch-based.
- `/_/u/:universe/code/:symbol`
- `/_/d/:name` is the Deployment page.

The sidebar's current environment is the universe in the URL. On non-universe pages it is the last one visited, kept in session assigns, defaulting to `main`.

The existing tests' DOM ids (`#universe-name`, `#health`, `#apps`, `#symbols`, …) are kept where the element survives, and the tests are updated where it doesn't.

## 8. Fidelity checks (step 4 of the process)

- A scratch harness seeds a "Ski trip"-shaped universe (apps `Split`, models `Split.Expense`/`Split.Share` with the prototype's 5/3 rows) and a deployment.
- Headless Chrome screenshots are taken at 1440×900 for Home, Graph (with a selection), Code, Data and Deployment.
- Computed styles are asserted against this table: font families, sizes, colours, the 46px top bar, the 230px sidebar, the 42px title bar, the 326px inspector, the 38px REPL bar, and no leftover `rounded-xl shadow-sm` cards.
- Corrected values are pinned as static test contracts.
