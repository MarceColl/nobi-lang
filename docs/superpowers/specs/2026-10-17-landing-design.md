# Landing page — design

## Goal

A static homepage for Kinoko in the style of a programming-language site, like Gleam, Unison and Elm. It says what Yabu and Kinoko are, shows real code, and makes the install line the main call to action.

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

## Structure

The structure comes from `docs/design/kinoko-marketing/LANGUAGE-SITES-RESEARCH.md`.

1. **Hero.**
   - A one-line promise in Newsreader, and a subhead.
   - The install block: `curl -fsSL …/install.sh | sh` (install.sh is POSIX sh; stock Alpine has no bash) in Plex Mono with a copy button, then `kinoko` on the next line.
   - The version and target badges: `macOS · Linux`, plus the version from `mix.exs`.
2. **See it run.** A terminal window (Vellum card, with the console's title-bar style) showing a real session: install, `kinoko`, the banner, `kinoko mcp`, and the agent's first patch promoted.
3. **The Elm architecture, Elixir syntax.** An annotated Yabu counter or todo `defapp`, with `init`, `update` and `view`, beside a rendered result styled like a Vellum app card.
4. **Code is a database.** Declarations are content-addressed, with a CID shown. A patch either promotes or stays staged with exact reasons. This uses the console's staged/Blocked callout and the `typechecks` chip.
5. **A compiler that explains itself.** A real checker verdict for a small mistake, shown as Kinoko prints it.
6. **The BEAM, with data that persists.** Covers:
   - `defmodel` with `id : Uuid`;
   - `Cmd.store`;
   - add-only evolution (`replies : Int = 0`);
   - one SQLite file per deployment, with no setup.
7. **Agents drive it.** The MCP loop: look → stage → read the verdict → prove (`eval`/`test`, the tools this server has; see `lib/kinoko_web/mcp/tools.ex`), with `claude mcp add …`.
8. **Get started.** The install block again, then links to the source, releases and the guide. Until guides exist, the guide link points to `docs/GLOSSARY.md`.

The footer has the source and releases. The licence line waits on a LICENSE file in the repository; until then the footer names only the fonts' licence (OFL).

## Constraints

- **Static output:** `site/index.html` plus one CSS file built by the Tailwind CLI that is already in the project (a new `site` profile), and the vendored fonts copied into `site/fonts/`. No JS framework. The only JS is a tiny copy-to-clipboard script. There are no CDN links.
- **Responsive:** down to 360px, with the code blocks scrolling horizontally inside their frames.
- **Accessible:**
  - semantic headings;
  - the copy button has a label;
  - contrast is at least 4.5:1 for body text.
- **Real code:** the code samples live as `.yabu` files under `site/samples/`. A test loads each one into a fresh universe and asserts the expected verdict: promotes, or a specific reason for the mistake sample. The page includes them at build time, so a sample that stops compiling fails CI.
- **Real transcript:** the terminal transcript comes from an actual run of the distribution binary. It is captured into `site/samples/session.txt` and lightly trimmed. Nothing is invented.
- **Build:** `mix site.build` writes `site/dist/`. `mix site.serve` previews it on port 4124.

## Out of scope

- Docs and tutorial pages, beyond links to what exists.
- A playground.
- Analytics.
- The waitlist.
