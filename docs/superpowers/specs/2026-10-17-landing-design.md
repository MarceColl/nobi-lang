# Landing page — design

## Goal

A short, plain static homepage for Kinoko: what it is, who it is for, and how to get from nothing to an app an agent built, in five steps.

## Decisions (Marce, 2026-10-17)

- **Look (revised 2026-10-17, restyle):** monochrome, after the principles of a public design guide (vercel.com/design.md), with none of its branding: Kinoko's own wordmark (the mushroom glyph and "kinoko") and its own tokens.
  - **Type:** Geist for everything, Geist Mono only for code, commands, paths and identifiers, vendored in `site/fonts/` (OFL, variable woff2, weights 400 to 600). Eight roles and no other sizes: display (the title, once), title (section headings), heading (step headings), lede, body, label, caption and mono. Tabular numerals where numbers align.
  - **Colour:** monochrome surfaces and text in light and dark themes of equal hierarchy, from `prefers-color-scheme`, with no switcher. Colour marks state only: the run's successful steps (green, beside "promoted", ": ok" or the served URL) and focus. No cards, gradients, shadows or side rails; one canvas, separated by spacing.
  - **Grid:** 12 columns on desktop, 6 on tablet, 4 on mobile. On desktop, section headings sit in columns 1 to 3 and content starts at column 4; prose keeps a 60 to 68 character measure; code, the run table and the screenshot span columns 4 to 12. The step numbers hang in the gutter.
  - **Spacing:** a 4px token scale (1 to 16); each section owns the gap above it.
  - **Header and footer:** the wordmark and two metadata items (version, "macOS · Linux") on one baseline; the footer is the glyph and the font licence line.
  - **Code and the run:** commands on a quiet secondary surface with a small radius and a copy button only where the command is meant to be copied; the recorded run is a semantic table (tool, argument, result) with a caption.
  - The site has its own tokens; it no longer carries the console's `--k-*` tokens. The console keeps Vellum.
  - Below 640px each run-table row stacks (tool and argument, then the result), so nothing scrolls sideways; explicit ARIA table roles keep its semantics.

  The first look was Vellum light, the console's own system (Newsreader, Chivo, IBM Plex Mono, paper and violet); the restyle replaced it on the site only.
- **Copy:** Claude drafts it from what is actually built, and Marce edits it.
  - Every claim must be true of the current build.
  - Every code sample must compile in today's Yabu.
  - Every terminal transcript must come from a real run.
- **Hosting:** GitHub Pages from `site/` in the same repo, deployed by a workflow. The workflow is written but not run until Marce publishes.

## Audience and tone (Marce, 2026-10-17, second version)

The first landing (eight sections: hero, "See it run", the Elm architecture, code as a database, the compiler's verdicts, the BEAM, agents, get started) was rejected. It mixed marketing copy with technical detail and never said who it was for.

- **Audience:** developers who already build with coding agents (Claude Code, Cursor).
- **Tone:** a plain project page, not a product page. No slogans and no persuasion.
- **No internals on the landing.** Staged patches, CIDs, verdicts, the BEAM and how changes work belong in the docs.
- **Copy:** approved by Marce and used verbatim; `site/COPY.md` lists each sentence with the feature behind it.

## Structure

1. **Title.** "Kinoko" in the display role, the one-line description, and one paragraph.
2. **Getting started.** Five numbered steps: install (`curl -fsSL …/install.sh | sh`, with a copy button), start (`kinoko`), connect the agent (`claude mcp add …`, with a copy button; `kinoko mcp` for other clients), ask for an app (the forum prompt), open it (`forum.localhost:4000`, the console at `localhost:4000/_`).
   - Under step 4, a captioned table lists the Kinoko tool calls of a real recorded run of that prompt, each with its one-line result, and the agent's first summary sentence. It is built from `site/samples/agent-run.jsonl` at build time. If it grows past about 15 lines, it is collapsed in a `<details>`.
   - Under step 5, a screenshot of the forum that run built (`site/src/forum.webp`).
3. **An example app.** `site/samples/counter.yabu`, shown as code.
4. **Status.** The version (major.minor from `mix.exs`), macOS and Linux, local and single-user, no hosting yet.
5. **Links.** Source and Releases.

The header has the version and "macOS · Linux"; the footer has the glyph and the fonts' licence (OFL).

## Constraints

- **Static output:** `site/dist/index.html` plus one CSS file built by the Tailwind CLI that is already in the project (a new `site` profile), and the vendored fonts copied into `site/dist/fonts/`. No JS framework. The only JS is a tiny copy-to-clipboard script. There are no CDN links.
- **Responsive:** down to 360px with no horizontal page scroll; code blocks scroll horizontally inside their frames.
- **Short:** one narrow column with lots of whitespace.
- **Accessible:**
  - semantic headings;
  - the copy button has a label;
  - contrast is at least 4.5:1 for body text.
- **Real code:** the counter sample lives at `site/samples/counter.yabu`. A test stages it into a fresh universe and asserts it promotes. The page includes it at build time, so a sample that stops compiling fails CI.
- **Real run:** the agent-run block comes from a real headless Claude Code run against the distribution binary (on port 4123, with fresh data). Its events are kept in `site/samples/agent-run.jsonl`, and a test checks that the block lists every Kinoko call in it, in order. Nothing is invented; `site/COPY.md` records how the run was made.
- **Build:** `mix site.build` writes `site/dist/`. `mix site.serve` previews it on port 4124.

## Out of scope

- Docs and tutorial pages, beyond links to what exists.
- A playground.
- Analytics.
- The waitlist.
