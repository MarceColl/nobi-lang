// The console shell's keyboard and memory (NobiWeb.Console.Live holds the state).
//
// ConsoleKeys sits on the shell's root (#console):
// - ⌘K / Ctrl-K toggles the palette; Esc closes it, else the intro;
// - on a universe page it remembers the universe in sessionStorage, and
//   consoleParams() hands it to the next LiveView join as `console_universe`,
//   so Home and Deployment pages know which universe was visited last;
// - the REPL keeps its submitted expressions in sessionStorage: Ctrl-↑ / Ctrl-↓
//   (or the caret) walk them, and the input clears once the server answers.

const UNIVERSE_KEY = "nobi.console.universe"
const HISTORY_KEY = "nobi.console.repl"
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
      } else if (e.key === "Escape" && document.getElementById("intro")) {
        this.pushEvent("console:intro-close", {})
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

// GraphCamera sits on the System graph's canvas (#graph-canvas) and ports the
// prototype's camera (graphStage's fit / zoomBy / startPan / movePan / endPan /
// onWheel). It owns only the world wrapper's transform and the zoom % label
// (#graph-zoom, phx-update="ignore"); LiveView owns everything else inside, so
// updated() puts the transform back after every patch.
// - drag on empty canvas pans (4px threshold); a click without a drag pushes
//   `graph:deselect` when something is selected; a cancelled pointer ends the
//   pan as a release does;
// - #graph-world carries phx-mounted={JS.ignore_attributes(["style"])}, so a
//   patch never strips the transform; updated() reapplies it as a belt;
// - wheel pans, ⌘/Ctrl-wheel zooms about the canvas centre;
// - the zoom strip dispatches `graph:zoom` ({f}) and `graph:fit` here;
// - fit frames the content extent (data-cw / data-ch) and keeps clear of the
//   inspector (gutter 354 with a selection, 28 without); it reruns when the
//   selection opens or closes, as the prototype's componentDidUpdate does.
export const GraphCamera = {
  mounted() {
    this.cam = {x: 0, y: 0, z: 1}
    this.selected = this.el.dataset.selected
    this.pan = null

    this.onDown = (e) => {
      if (e.target !== this.el) return
      this.pan = {sx: e.clientX, sy: e.clientY, ox: this.cam.x, oy: this.cam.y, moved: false}
      this.el.setPointerCapture(e.pointerId)
    }
    this.onMove = (e) => {
      const p = this.pan
      if (!p) return
      const dx = e.clientX - p.sx, dy = e.clientY - p.sy
      if (!p.moved && Math.abs(dx) + Math.abs(dy) < 4) return
      p.moved = true
      this.set({...this.cam, x: p.ox + dx, y: p.oy + dy})
    }
    this.onUp = (e) => {
      const p = this.pan
      this.pan = null
      if (this.el.hasPointerCapture?.(e.pointerId)) this.el.releasePointerCapture(e.pointerId)
      const click = p && !p.moved && e.type === "pointerup"
      if (click && this.el.dataset.selected === "true") this.pushEvent("graph:deselect", {})
    }
    this.onWheel = (e) => {
      e.preventDefault()
      if (e.ctrlKey || e.metaKey) this.zoomBy(Math.exp(-e.deltaY * 0.01))
      else this.set({...this.cam, x: this.cam.x - e.deltaX, y: this.cam.y - e.deltaY})
    }
    this.onZoom = (e) => this.zoomBy(Number(e.detail && e.detail.f) || 1)
    this.onFit = () => this.fit()

    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerup", this.onUp)
    this.el.addEventListener("pointercancel", this.onUp)
    this.el.addEventListener("wheel", this.onWheel, {passive: false})
    this.el.addEventListener("graph:zoom", this.onZoom)
    this.el.addEventListener("graph:fit", this.onFit)

    this.apply()
    setTimeout(() => this.fit(), 0)
  },

  updated() {
    if (this.el.dataset.selected !== this.selected) {
      this.selected = this.el.dataset.selected
      setTimeout(() => this.fit(), 0)
    }
    this.apply()
  },

  fit() {
    const w = this.el.clientWidth, hh = this.el.clientHeight
    if (w === 0 || hh === 0) return
    const gutter = this.el.dataset.selected === "true" ? 354 : 28
    const cw = Number(this.el.dataset.cw) || 1, ch = Number(this.el.dataset.ch) || 1
    const z = Math.max(.5, Math.min(1, (w - gutter) / cw, (hh - 28) / ch))
    this.set({z, x: Math.max(8, (w - gutter - cw * z) / 2 + 8), y: 14})
  },

  zoomBy(f) {
    const cx = this.el.clientWidth / 2, cy = this.el.clientHeight / 2
    const z = Math.max(.3, Math.min(2, this.cam.z * f)), k = z / this.cam.z
    this.set({z, x: cx - (cx - this.cam.x) * k, y: cy - (cy - this.cam.y) * k})
  },

  set(cam) {
    this.cam = cam
    this.apply()
  },

  apply() {
    const world = this.el.querySelector("#graph-world")
    if (world) world.style.transform = `translate(${this.cam.x}px, ${this.cam.y}px) scale(${this.cam.z})`
    const label = document.getElementById("graph-zoom")
    if (label) label.textContent = Math.round(this.cam.z * 100) + "%"
  },
}
