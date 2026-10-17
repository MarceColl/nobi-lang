# Language homepage research (for the Nobi landing page)

Fetched 2026-10-17 with WebFetch. Fetched text is treated as data. Quotes are short; the rest is paraphrase.
Fetch notes:
- elm-lang.org FAILED. It is a client-rendered Elm app, and both WebFetch and curl returned only a compiled JS bundle. The Elm entry below comes from memory of the site and is marked (memory, unverified).
- Install pages were not fetched separately. Every hero either showed no install command or linked out. Each site's install treatment was read from the homepage.
- WebFetch summarises through a small model, so section orders are approximate.

## Per-site records

### Gleam (gleam.run)
1. Hero: headline "a friendly language for building type-safe systems that scale". The subhead lists types, functional style, the Erlang runtime and modern syntax. The primary CTA is "Try Gleam", which opens the in-browser tour. A hello-world snippet is above the fold. Install is only a nav link.
2. Sections:
   - Reliable and scalable: BEAM concurrency, with a process example.
   - Ready when you are: built-in tooling, shown as a `gleam add` / `gleam test` transcript.
   - Here to help: no nulls or exceptions, shown with a compiler error.
   - Multilingual: Erlang/Elixir interop and compiling to JS, with an FFI sample.
   - Friendly: community values and code of conduct.
   - Lovely people: sponsor and contributor avatar wall.
   - "You're still here?": tour CTA and newsletter.
3. Code: one short block per claim. Several are styled as terminal or compiler output. The tour is the real onboarding path.
4. Install: a nav link to /install. No command on the homepage.
5. Trust: named corporate sponsors, a big individual-sponsor wall, and the BEAM's pedigree (WhatsApp, Ericsson), which is borrowed credibility. It cites a large package ecosystem. No user logos.
6. Tone: warm, playful, mascot-led.

### Elm (elm-lang.org) (memory, unverified)
1. Hero: a short tagline about "a delightful language for reliable web applications". CTAs are Try and Install. A small embedded example sits near the top, followed by feature blurbs.
2. Sections: no runtime errors, great performance, enforced semantic versioning, small assets. Then "The Elm Architecture". The compiler error messages are shown as a showcase.
3. Code: embedded runnable examples, an online editor ("Try Elm"), and a guide.
4. Install: a link to the guide's install page with per-OS installers.
5. Trust: user logos and testimonials appear lower on the page. Community is Discourse and Slack.
6. Tone: calm, gentle, humane.

### Unison (unison-lang.org)
1. Hero: headline "A new approach to Distributed programming". The subhead is about never hand-writing encoders at network boundaries. The primary CTA is Download from GitHub. The install CTA is above the fold. Code comes later.
2. Sections:
   - Distributed programming.
   - Refactoring: the codebase stays live and typechecks.
   - Durable storage.
   - Storing code: code lives in a database, not text files.
   - Dependencies: identified by hash.
   - Desktop app download.
   - "How does Unison code look?": hello world, map-reduce, HTTP.
   - "What's it like to write Unison code?": animated UCM terminal.
   - Closing CTA.
3. Code: highlighted blocks, each with a type signature, clickable references and short inline concept notes. The terminal demo shows the workflow.
4. Install: a download button, a desktop-app alternative and a "$" prompt motif.
5. Trust: open-source repo, public benefit corporation, Share (the code registry), and Discord, Mastodon and YouTube links. No logos.
6. Tone: friendly, futuristic, minimal.

### Roc (roc-lang.org)
1. Hero: "A fast, friendly, functional language." There is no labelled button. A small `map` snippet is above the fold.
2. Sections:
   - Fast / Friendly / Functional cards.
   - Examples, with an in-browser runner.
   - Tutorial prompt.
   - Sponsors, with a fundraising goal.
   - Footer.
3. Code: the hero snippet plus a larger to-do example. The site says the examples are built with the same compiler.
4. Install: a nav link only.
5. Trust: corporate and individual sponsors, and a US 501(c)(3) foundation.
6. Tone: minimal, friendly, small and indie.

### Elixir (elixir-lang.org)
1. Hero: "Simple from zero to scale". Four bullets cover productivity, scale and fault tolerance. The CTAs are "Install now" and "Get started". A pipeline snippet with its output is above the fold. The install command itself is not shown.
2. Sections:
   - Why Elixir (four pillars).
   - Elixir in production (logo grid).
   - "Use Elixir for" tabs: web, embedded, ML, data, IoT and distributed.
   - "What will you build?"
   - Shaped by many: foundation and community.
   - Open source stewards.
   - Footer.
3. Code: tabs per use case. Each snippet is short and carries one comment. The hero pairs code with its output.
4. Install: a prominent button to a per-OS install page, repeated lower on the page.
5. Trust: a production logo grid (Discord, Apple, Spotify, BBC and others), a survey claim, a foundation and a recent release notice.
6. Tone: confident, clean, code-first.

### Zig (ziglang.org)
1. Hero: "a general-purpose programming language and toolchain", with robust, optimal and reusable emphasised. The CTA is GET STARTED, with a latest-release badge beside it. No code and no install command above the fold.
2. Sections:
   - A simple language: no hidden control flow, allocations or macros.
   - Comptime.
   - Maintain it with Zig: a C/C++ compiler and the build system.
   - One code sample with its shell test output.
   - Community, main development, the foundation, sponsors and language selector.
3. Code: one labelled file panel followed by a shell block with passing output. It has an inline hint and a "more samples" link.
4. Install: the Download page via nav. Nothing inline.
5. Trust: nonprofit status, sponsor logos, a visible release number and release notes, and passing test output.
6. Tone: terse, technical, minimal.

### Rust (rust-lang.org)
1. Hero: "Rust", with the subhead "A language empowering everyone to build reliable and efficient software." The CTA is Get Started, with a version badge. No code and no install command above the fold.
2. Sections:
   - Why Rust (performance, reliability, productivity).
   - Build it in Rust (CLI, WASM, networking, embedded).
   - In production.
   - Get involved.
   - Thanks and sponsors.
   - Get help.
3. Code: none on the homepage.
4. Install: a nav link only.
5. Trust: production use, the foundation, and the team.
6. Tone: welcoming, institutional, clean.

### Darklang (darklang.com)
1. Hero: "Just code". The subhead says CLIs and cloud apps in one box, with no nonsense. The CTA is an email signup for project updates. No code above the fold.
2. Sections: a pointer to Darklang Classic, then an in-development install and CLI preview. After that comes a long run of feature rows:
   - Simple types.
   - Option and Result types.
   - Garbage collection.
   - Unicode strings.
   - Instant package runs.
   - Permission prompts.
   - A fast loop with a single-binary install.
   - Gradual typing.
   - Package management.
   - An async runtime.
   - Optional deploy.
   - "Designed for GenAI".
3. Code: mock terminal transcripts with `$` prompts and permission prompts. Type snippets carry comments.
4. Install: a literal `curl … | bash` command with a simulated installer session, labelled as in development.
5. Trust: open source, Discord and YouTube links, and a Classic product with docs. No logos. The page pairs a waitlist CTA with an unreleased product, which weakens credibility.
6. Tone: blunt, irreverent, dark and terminal-like.

## Synthesis

### Common skeleton
1. Name and one-sentence promise.
2. A single primary CTA that sends you to a tour, guide or download. Install is usually a nav link rather than a hero command.
3. Three to five pillars, each a short claim.
4. A small code sample (Gleam, Elixir, Roc and Zig have one).
5. Use cases or production proof.
6. Community and sponsors.
7. A closing CTA and footer.

### What the best ones do that others don't
- Gleam shows the mechanism, not just the claim. It uses terminal transcripts and compiler errors as the pitch. Its CTA is a zero-install tour, and its tone is unmistakable.
- Unison puts the unusual idea (code in a database, hashes) first. It explains it in plain language, then follows with an animated terminal of the real workflow. It also puts the install CTA in the hero.
- Elixir gives each use case its own tab with a code sample, and it pairs code with its output.
- Zig closes the loop on a sample: source, then the shell command, then the passing output. It also puts a release number in the hero.
- Elm (memory) makes the compiler's error messages a selling point.
- Darklang is the only one showing a `curl | bash` block. It also shows a permission-prompt transcript, which makes the safety story concrete. Pairing that with a waitlist is the thing to avoid.
- Weak spots: Rust has no code at all, and Roc and Zig hide install. Most sites bury where to start.

### Recommended Nobi outline (8 sections)
| # | Section | Purpose | Nearest exemplar |
|---|---------|---------|------------------|
| 1 | Hero | One-line promise for Nobi on the BEAM, with the `curl … \| bash` install command visible above the fold. A secondary CTA goes to the tour, plus a version badge. | Unison (install in hero), Gleam (friendly line), Zig (version badge) |
| 2 | See it run | A real terminal transcript: install, start, run an Elm-style app, show the first result. | Gleam transcripts, Unison UCM demo |
| 3 | The Elm architecture, Elixir-flavoured | A short Nobi counter app, annotated for `init`, `update` and `view`, with the rendered output beside it. | Elm, Elixir (code with output) |
| 4 | Code is a database | Explain content-addressed declarations: no files, rename without breakage, and a staged patch that promotes or is rejected with reasons. | Unison (storing code, dependencies) |
| 5 | The compiler is your assistant | Show a staged-patch verdict with exact reasons, in the style of a friendly compiler error. | Elm, Gleam (Here to help) |
| 6 | Runs on the BEAM, data persists | Fault tolerance, concurrency, and SQLite persistence with zero setup. | Gleam (Reliable and scalable), Elixir |
| 7 | Agents drive it through MCP | Show an agent staging a patch, the verdict, then a fork and PR for human review. This is Nobi's own angle. | Darklang (GenAI row, permission prompts) |
| 8 | Get started | The install block again, a per-OS note, the tour or docs link, then community, source and releases. | Gleam closing, Elixir install |

An optional ninth section, "What people have built", with reference apps, can replace logos until there are real users.

### Marketing kit (/Users/marcecoll/proj/nobi/docs/design/nobi-marketing/ui_kits/marketing/)
Read: README.md, Hero.jsx, Features.jsx, Infrastructure.jsx, Closing.jsx, TerminalDemo.jsx. The kit recreates nobi.sh as a SaaS pitch ("products that grow themselves") with a waitlist.

Still fits:
- The terminal-window demo (`TerminalDemo`, a window-chrome panel with speaker lines and ok/running rows). It maps straight onto sections 2 and 7. Rewrite the content as a real install, patch and verdict transcript.
- The visual system: the violet and mint glow, the glowing-mushroom motif and the wordmark. Keep it, but make it quieter.
- The three-card "Trust through constraints" row (`Features`: strong types, simulation testing, reproducible execution). The ideas still apply. Reframe them as the compiler, `simulate` and replay.
- `SectionHead` and the single-scroll layout.
- The rounded closing panel, reused for the install block.
- The "Now in development" status pill, if it is honest.

Doesn't fit (SaaS or waitlist):
- The "Request access" CTA, `WaitlistDialog`, and the "Join the waitlist" closing panel. A downloadable language leads with an install command.
- The hero line "Products that grow themselves" and the autopilot-to-revenue promise. It is a product pitch, not a language pitch, and the rotating-verb headline is cute but hides what Nobi is.
- The `Infrastructure` tile grid ("Fully managed", zero-downtime deploys, one-click rollbacks, managed storage, "coming soon" tiles for queues, crons and durable workflows). It is a hosting pitch. Keep at most two tiles (persistent data, introspection) and drop the "coming soon" items.
- The `Collaboration` mock (comment sidebar) and the feedback-loops diagram. They are team-product features, not language features.
- Monetize and revenue language in general.
- The floating mushrooms, if they crowd the code. Code should be the visual centre.
