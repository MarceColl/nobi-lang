const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

// Phosphor icons (regular weight, MIT) as "ph-<name>" classes, masked SVGs
// painted with currentColor. Sized 1em so font-size drives them; override with size-*.
module.exports = plugin(function({matchComponents}) {
  let iconsDir = path.join(__dirname, "phosphor")
  let values = {}
  fs.readdirSync(iconsDir).forEach(file => {
    if (!file.endsWith(".svg")) return
    let name = path.basename(file, ".svg")
    values[name] = {name, fullPath: path.join(iconsDir, file)}
  })
  matchComponents({
    "ph": ({name, fullPath}) => {
      let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
      content = encodeURIComponent(content)
      return {
        [`--ph-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
        "-webkit-mask": `var(--ph-${name})`,
        "mask": `var(--ph-${name})`,
        "mask-repeat": "no-repeat",
        "mask-size": "contain",
        "mask-position": "center",
        "background-color": "currentColor",
        "vertical-align": "middle",
        "display": "inline-block",
        "width": "1em",
        "height": "1em"
      }
    }
  }, {values})
})
