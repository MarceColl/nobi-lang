# Kinoko design system

Kinoko is a platform for autonomous software development: AI agents that write, verify
and deploy code, supervised by the system rather than by a person. The product's whole
argument is that constraints — a strong type system, deterministic execution, simulation
testing — are what make speed safe. The design reflects that: everything is dark, quiet
and instrumented, with light used to mark state rather than to decorate.

The brand image is a mushroom growing in the dark. *Kinoko* (キノコ) is Japanese for
mushroom, and the metaphor runs through the whole site: spores, clusters, caps, mycelial
networks, software that grows itself.

## Sources

| Source | Where | What was taken |
| --- | --- | --- |
| `landing/` (local folder, attached to this project) | the kinoko.sh marketing site — Vite + React, single `src/App.tsx` of 1,787 lines, all inline styles, no stylesheet | every color, font, radius, shadow, animation and every word of copy |
| `landing/public/favicon.svg`, `landing/kinoko-logo.png` | — | copied to `assets/` |
| A full-page screenshot of kinoko.sh | user-supplied | used only to confirm layout before the code was readable |

There is **no console, IDE or app source** in anything provided. See
`ui_kits/console/README.md` for what that means for the console kit.

## Content fundamentals

**Voice: declarative, technical, unhedged.** Sentences state what the system does and
stop. "Catch errors at definition time, not runtime." "Every request can be replayed
exactly." No "we believe", no "designed to help you", no future tense hedging.

**Second person, product as subject.** Copy addresses "you" but the sentence subject is
almost always the system: "Agents and humans share the same address space", "Ship
instantly. Old requests finish on old code, new requests go to new code."

**Named tension, then resolution.** Section leads set up a problem before the answer:
"The bottleneck isn't writing code—it's trusting code. System constraints raise quality
so speed can follow." The em dash without spaces is the house punctuation for this move.

**Headline grammar: subject + verb + reflexive.** "Products that grow themselves."
"Software that grows itself." "Ready to let your product grow?" The reflexive is the
brand's whole pitch compressed into a word — keep it.

**Sentence case everywhere.** Headings, buttons, tags, labels. Never title case, never
all caps except the 10–11px eyebrow labels in this system's own specimen cards. The
wordmark is always lowercase: `kinoko`, never `Kinoko` in a logo position (prose may
capitalize it).

**No emoji in interface chrome.** The source uses two, both inside mocked-up content:
🐛 on a bug row and ☝️ in a simulated user comment. The system replaces the bug glyph
with a typographic mark and keeps the one in user-written content. Do not introduce
emoji into buttons, labels, headings or navigation.

**Feature copy is two sentences, ~14 words each.** First states the capability, second
states the consequence. "Run thousands of scenarios in a sandbox that behaves exactly
like production. Find edge cases before users do."

**Unshipped things say so.** An amber "Coming soon" tag and a dimmed card. Never hide
roadmap items, never write around them.

## Visual foundations

### Ground and light

The page is `#0A080F` — a near-black with violet in it, never pure black. Over it sit
three fixed radial washes (violet from the top, mint from bottom-left, amber from the
right), 30 static white stars of 1–3px at 0.1–0.5 opacity, and 35 drifting colored motes
with 12px blooms. The stars are confined to the **top half** of the page while the motes
cover its full height — that asymmetry is what makes the ground read as sky above and
forest floor below. Motes draw randomly from four hues (mint, amber, lilac, mint-light)
with 2–6s durations and 0–5s delays. The result is a night sky you can barely see, which
is the point: it gives depth without ever competing with content.

Panels are `#13111C`, window headers `#1A1725`. Every panel edge is
`rgba(42,37,56,0.8)` — a violet hairline, not a grey one.

### Elevation is glow, not shade

There are no drop shadows anywhere on the site. Elevation is a large, soft, *colored*
bloom: `0 0 60px rgba(139,123,181,0.15)` under panels, `0 0 30px rgba(125,211,192,0.3)`
under primary actions, `0 0 80px rgba(125,211,192,0.15)` under the modal. The only
literal shadow in the codebase is the tooltip's `0 8px 32px rgba(0,0,0,0.5)`, and it
exists because a tooltip must detach from what's under it.

Small lit elements carry their own halo instead: status dots get
`box-shadow: 0 0 10px <hue>`, terminal check marks get `text-shadow: 0 0 10px <hue>`.

### Color as meaning

The palette is a violet ground with four functional hues, and each hue means one thing
consistently across the whole product:

- **Mint `#7DD3C0`** — verified, passing, the agent's voice, the development stage
- **Lilac `#B8A5D9`** — your voice, exploration, drafts, the planner
- **Mint light `#9FEDD7`** — validation, resolved traces
- **Amber `#F5C869`** — in progress, not yet shipped, production incidents
- **Red `#FF6B6B`** — bugs and failures, only ever as a small mark

Violet `#8B7BB5` is structural rather than semantic: it makes gradients, borders and
glows, and it is the mushroom cap.

Saturated fills are rare. Color arrives as a 6–15% tint over the dark ground with a
30% border of the same hue — that pairing is the system's single most repeated move,
used by tags, callouts, icon tiles and highlighted lines alike.

### Gradients

Three, all at 135°:

- `--grad-primary` violet → mint: every primary button
- `--grad-nav` violet → deep teal: the header button only
- `--grad-text` lilac → mint → amber: clipped to display text, for the one word per
  headline that carries the idea

Gradients never fill a card, a section or a background.

### Type

**Fraunces** for display, **Nunito** for body, the system mono stack for code — all
loaded from Google Fonts (both are Google families, so no substitution was needed).

Fraunces is a high-contrast soft serif; it appears only at 600 or 700 and only on
headings, card titles and the wordmark. It never sets body copy. Nunito is 400 for
copy and 500–600 for buttons and labels, and it never sets a heading. The pairing does
all the tonal work: the serif is warm and slightly odd, the sans is plain, and the
contrast between them is what keeps a very dark page from reading as generic devtools.

Headlines are fluid (`clamp(48px, 8vw, 72px)`) and centered — this is a centered layout
system, unusual for developer products and worth preserving. Body copy is
`#A99BC5`, a muted violet, never grey and never white. Pure `#F5F0FF` is reserved for
headings.

### Shape

Radii climb with importance: 4px inline marks, 6px tags, 8px tooltips, 12px tiles and
form controls, 16px panels and cards, 24px the modal and the closing CTA. Actions are
full pills (`9999px`) — except inside a form, where a submit button squares off to 12px
to match the input above it.

Cards come in four tones and nothing else: a flat violet-tinted tile, a top-lit card
with a vertical wash, a dimmed tile for unshipped features, and a solid `#13111C` panel
for anything that represents a real product surface.

### Motion

Nothing slides, nothing bounces, nothing has a spring. Four ambient loops, all
`ease-in-out infinite`, all long:

- `kn-float` / `kn-float-reverse` (5–8s) — decorative mushrooms drift and rotate a few degrees
- `kn-pulse-glow` (1.5–2s) — status dots and in-progress marks breathe between 0.6 and 1 opacity
- `kn-twinkle` (3–7s) — motes scale from 0.3 to 1 and fade
- `kn-blink` (1s) — a text cursor in a collaborative document

Discrete transitions are 0.2s for hover, 0.3s for state, 0.4s for the rotating headline
word — which is the one piece of choreography on the site: the old word exits downward
while the new enters from above.

### Interaction states

Hover brightens (`filter: brightness(1.12)`); press scales to 0.97. Inputs swap their
violet hairline for mint on focus. Keyboard focus is a 2px mint ring at 2px offset.
Disabled drops to 45% opacity. Selection is a mint tint. All of these are in
`tokens/base.css` — don't restyle them per page.

### Layout

One centered column at `max-width: 1152px`, `96px 32px` section padding, `650px` on
lead paragraphs and `500px` where the lead should be tighter. Feature grids use
`repeat(auto-fit, minmax(300px, 1fr))` at 24px gap; the infrastructure grid uses
`minmax(240px, 1fr)` at 16px. The closing CTA narrows to 900px.

### Transparency and blur

Blur appears twice, both times deliberately: `backdrop-filter: blur(8px)` on the modal
backdrop, and `filter: blur(40px)` on the radial glow blobs that sit behind panels and
inside the CTA. Never blur a content surface.

## Iconography

**Kinoko has no icon library.** No Lucide, no Phosphor, no icon font. The entire
vocabulary is five hand-drawn mushroom glyphs on a 32×32 grid — `sprout`, `glow`,
`spore`, `cluster`, `cap` — plus the larger decorative `GlowingMushroom` and the
favicon. They are copied verbatim from `App.tsx` into `components/brand/MushroomIcon.jsx`.

Each glyph is drawn in a single hue passed as a prop: 1.5–2px strokes, round caps, caps
filled at 30% alpha, spore dots at 40–80% opacity. Because fills are built by
concatenating hex alpha (`` `${color}30` ``), **the color prop must be a literal hex
string** — a `var()` will silently break the fills.

Glyph meanings, as used on the site: `sprout` growth and types · `spore` distribution
and simulation · `glow` introspection and observability · `cluster` storage and queues ·
`cap` the general-purpose mark.

Beyond these, the site uses typographic marks rather than icons: `✓` `⟳` `→` `▸` `▾`
`×` `•`. Follow that. The one emoji in the source (🐛) has been replaced with a
typographic `!` mark.

**There is no logo.** The wordmark is set type — "kinoko" in Fraunces bold, lowercase,
cream `#E5DFD5`. `assets/kinoko-logo.png` and `assets/favicon.svg` are copied from the
repo; nothing was drawn or reconstructed.

## Index

**Root**
- `styles.css` — the entry point; `@import`s only
- `readme.md` — this file
- `SKILL.md` — Agent Skills wrapper for use in Claude Code

**`tokens/`** — `fonts.css` (the Google Fonts import), `colors.css`, `typography.css`,
`spacing.css`, `effects.css` (glows + the four keyframe loops), `base.css` (resets,
element defaults, focus and selection).

**`assets/`** — `favicon.svg`, `kinoko-logo.png`.

**`guidelines/`** — 16 specimen cards across Colors, Type, Spacing and Brand.

**`components/`**
- `core/` — `Button`, `Input`, `Tag`, `StatusPill`
- `surfaces/` — `Card`, `FeatureCard`, `Callout`, `WindowChrome`, `Dialog`
- `brand/` — `MushroomIcon`, `GlowingMushroom`, `Firefly`, `Wordmark`
- `console/` — `TerminalLine`, `TraceChip`

**`ui_kits/loader.js`** — a module shim used by every card and kit here. Babel's
in-browser transformer only compiles the entry script, so imported `.jsx` files fail.
It exports three functions:

- `KNLoad(files, seed?)` — fetches the sources, strips their import/export lines,
  compiles each with the **classic** JSX runtime (the automatic runtime injects an
  import that cannot survive being evaluated as a function body) and evaluates them in
  order against one shared scope, which it returns.
- `KNBundleScript(url)` / `KNBundle(names)` — inject the compiled bundle and find its
  namespace on `window`, or `null`. The script is injected at runtime rather than
  written as a `<script src>` so a page carries no reference to a file the compiler may
  not have generated yet. Every property read in the scan is guarded: enumerating
  `window` touches cross-origin frames and throws `SecurityError`, which silently
  aborts the caller before it mounts.
- `KNCard(names, componentFiles, demoFile)` — what the component cards call. Components
  come from the bundle once the compiler has generated it and from the sources before
  then, so a card renders either way; the card's demo is always compiled from its own
  `.jsx` and evaluated with those components in scope.

Each component directory pairs `<group>.card.html` (loader + mount, no JSX) with
`<group>.card.jsx` (the demo). Keeping JSX out of the HTML is deliberate — inline
`type="text/babel"` blocks failed opaquely in this environment.

The UI kits call `KNLoad` directly rather than `KNCard`, because their screens are
composed of section components that are not part of the bundle.

**`ui_kits/`**
- `marketing/` — the full kinoko.sh landing page, rebuilt from components
- `console/` — the two authentic product surfaces, in a deliberately unfilled shell

### Intentional additions

The source is one file with no component boundaries, so every component here is an
extraction rather than a copy of an existing API. Three are groupings the source implies
but never names:

- **`Card`** — the source writes four distinct box styles inline in four places; they are
  collected into one component with four tones.
- **`SectionHead`** (marketing kit) — the centered heading + lead pattern, repeated three
  times verbatim in `App.tsx`.
- **`Wordmark`** — the "kinoko" span, styled identically in the nav and footer.

No component was invented that has no counterpart in the source. Notably absent, because
the source has none: Tabs, Toast, Tooltip (as a primitive), Avatar, Select, Checkbox,
Switch, Table.

## Known gaps

- **No console source.** The console UI kit is honest about this and leaves its shell blank.
- **The feedback-loop diagram** (`LoopsWithinLoops`, ~400 lines of hand-placed SVG) is
  not extracted. It is a bespoke illustration, not a component; its four stage hues and
  participant loops are in the tokens and in `ui_kits/marketing/Loops.jsx`, which
  renders the section's real heading around a labeled empty frame.
- **No dark/light modes.** Kinoko is dark only. There is no light theme to derive.
- **The waitlist POST** to Loops is not reproduced in the kit.
