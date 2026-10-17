# Marketing site UI kit

A recreation of kinoko.sh, rebuilt out of the design system's components rather than
the one-file `App.tsx` the real site ships. Source of truth: `landing/src/App.tsx`
(1,787 lines, all inline styles, no stylesheet). Every string, color and dimension in
this kit was taken from the source rather than from a screenshot.

## Screens

`index.html` is the whole page — the site is a single scroll with one modal.

| Part | File | Source lines |
| --- | --- | --- |
| Page ground | `Ambient.jsx` | 493–512 (constants), 628–668 (render) |
| Header | `Nav.jsx` | 660–693 |
| Hero | `Hero.jsx` | 695–806 |
| Agent transcript | `TerminalDemo.jsx` | 807–879 |
| Section heading | `SectionHead.jsx` | repeated pattern |
| Trust | `Features.jsx` | 881–962 |
| Collaboration | `Collaboration.jsx` | 964–1355 |
| Feedback loops | `Loops.jsx` | 1357–1385 (heading only) |
| Infrastructure | `Infrastructure.jsx` | 1387–1509 |
| Close + footer | `Closing.jsx` | 1511–1637 |
| Waitlist | `WaitlistDialog.jsx` | 1639–1785 |

## Deliberate differences from the source

1. **The feedback-loop diagram is not reproduced.** `LoopsWithinLoops` is ~400 lines
   of hand-placed SVG — a bespoke illustration, not a reusable component. `Loops.jsx`
   carries the section's real heading and lead and lists the four stages with their
   real hues and participant loops, inside a labeled empty frame. It does not attempt
   the dashed cycle-within-cycles drawing.
2. **The waitlist form does not POST to Loops.so.** It flips to the success state
   locally. The success copy is verbatim.
3. **The bug row's 🐛 emoji is replaced with a typographic `!` mark.** This is the one
   place the kit knowingly departs from the source's glyph, to keep the system
   emoji-free. The ☝️ in Sarah's comment *is* preserved, because it is user-written
   content inside the mock rather than interface chrome.
4. **The reply field in the comment sidebar is a static div in the source**, not an
   input, and is reproduced that way — it is a visual affordance, not a control.

Everything else — copy, hex values, radii, font sizes, grid definitions, timestamps,
stack-trace lines, the trace tooltip's timings — is verbatim.
