# Landing page — design

## Goal

A short, plain static homepage for Kinoko: what it is, who it is for, and how to get from nothing to an app an agent built, in five steps.

## Decisions (Marce, 2026-10-17)

- **Look:** **Vellum light**, the console's own system.
  - Paper `#F2F1EC`, ink `#1B1A17` and violet `#5B4B96`; mint and amber as accents.
  - Newsreader for display text, Chivo for the UI and body, IBM Plex Mono for code.
  - The same tokens as `assets/css/app.css` (`--k-*`), with the same radii, line colours and shadows.

  The site and the product should feel like one thing. The marketing kit's dark look is not used. Its structure ideas (terminal window, closing panel) are reused in Vellum colours.
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

1. **Title.** "Kinoko" in Newsreader, the one-line description, and one paragraph.
2. **Getting started.** Five numbered steps: install (`curl -fsSL …/install.sh | sh`, with a copy button), start (`kinoko`), connect the agent (`claude mcp add …`, with a copy button; `kinoko mcp` for other clients), ask for an app (the forum prompt), open it (`forum.localhost:4000`, the console at `localhost:4000/_`).
   - Under step 4, a short terminal block lists the Kinoko tool calls of a real recorded run of that prompt, each with its one-line result, and the agent's first summary sentence. It is built from `site/samples/agent-run.jsonl` at build time. If it grows past about 15 lines, it is collapsed in a `<details>`.
   - Under step 5, a screenshot of the forum that run built (`site/src/forum.webp`).
3. **An example app.** `site/samples/counter.yabu`, shown as code.
4. **Status.** The version (major.minor from `mix.exs`), macOS and Linux, local and single-user, no hosting yet.
5. **Links.** Source and Releases.

The footer has the version and the fonts' licence (OFL).

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
