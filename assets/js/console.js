// The console shell's keyboard and memory (KinokoWeb.Console.Live holds the state).
//
// ConsoleKeys sits on the shell's root (#console):
// - ⌘K / Ctrl-K toggles the palette, Esc closes it;
// - on a universe page it remembers the universe in sessionStorage, and
//   consoleParams() hands it to the next LiveView join as `console_universe`,
//   so Home and Deployment pages know which universe was visited last;
// - the REPL keeps its submitted expressions in sessionStorage: Ctrl-↑ / Ctrl-↓
//   (or the caret) walk them, and the input clears once the server answers.

const UNIVERSE_KEY = "kinoko.console.universe"
const HISTORY_KEY = "kinoko.console.repl"
const HISTORY_CAP = 50

const read = (key, fallback) => {
  try {
    const value = sessionStorage.getItem(key)
    return value === null ? fallback : JSON.parse(value)
  } catch (_e) {
    return fallback
  }
}

const write = (key, value) => {
  try { sessionStorage.setItem(key, JSON.stringify(value)) } catch (_e) { /* storage off: forget */ }
}

export const consoleParams = () => {
  const universe = read(UNIVERSE_KEY, null)
  return typeof universe === "string" ? {console_universe: universe} : {}
}

export const ConsoleKeys = {
  mounted() {
    this.remember()
    this.cursor = null

    this.onKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault()
        this.pushEvent("console:palette-toggle", {})
      } else if (e.key === "Escape" && document.getElementById("cmd-palette")) {
        this.pushEvent("console:palette-close", {})
      }
    }
    window.addEventListener("keydown", this.onKey)

    this.onReplKey = (e) => {
      if (e.target.id !== "repl-input" || !e.ctrlKey) return
      if (e.key === "ArrowUp") { e.preventDefault(); this.recall(-1) }
      if (e.key === "ArrowDown") { e.preventDefault(); this.recall(1) }
    }
    this.onClick = (e) => {
      if (e.target.closest("#repl-history")) this.recall(-1)
    }
    this.onSubmit = (e) => {
      if (e.target.id !== "repl-form") return
      const input = document.getElementById("repl-input")
      const expr = input && input.value.trim()
      if (!expr) return
      const history = read(HISTORY_KEY, []).filter(h => h !== expr)
      history.push(expr)
      write(HISTORY_KEY, history.slice(-HISTORY_CAP))
      this.cursor = null
    }
    this.el.addEventListener("keydown", this.onReplKey)
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("submit", this.onSubmit, true)

    this.handleEvent("console:repl-done", () => {
      const input = document.getElementById("repl-input")
      if (input) input.value = ""
    })
  },

  updated() { this.remember() },

  destroyed() {
    window.removeEventListener("keydown", this.onKey)
  },

  remember() {
    if (this.el.dataset.remember === "true") write(UNIVERSE_KEY, this.el.dataset.universe)
  },

  recall(step) {
    const input = document.getElementById("repl-input")
    const history = read(HISTORY_KEY, [])
    if (!input || history.length === 0) return
    const at = this.cursor === null ? history.length : this.cursor
    const next = Math.min(Math.max(at + step, 0), history.length)
    this.cursor = next
    input.value = next === history.length ? "" : history[next]
    input.focus()
  },
}
